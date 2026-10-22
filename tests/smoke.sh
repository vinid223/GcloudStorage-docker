#!/usr/bin/env sh
#
# Smoke tests for the gcloud-storage-docker image.
#
# These check the parts that are cheap to get wrong and expensive to discover in
# production: the GCSOPTIONS translation table, configuration validation, exit
# statuses, the lock, the log and the healthcheck. Nothing here talks to Google
# Cloud Storage - `gcloud` is replaced by a stub that prints its own argv, so the
# exact command run.sh builds can be asserted.
#
# Unlike tests/run-tests.sh, no case bind-mounts a host directory: every fixture
# is created inside the container. That is what makes this suite runnable on a CI
# runner that drives the host Docker daemon through a mounted socket, where a
# path inside the job container means nothing to the daemon.
#
# Usage:
#   tests/smoke.sh                # build the image and run everything
#   IMAGE=my-image tests/smoke.sh # test an image that is already built
#   tests/smoke.sh translation    # only cases whose name matches an argument

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
IMAGE=${IMAGE:-}
FILTER="$*"

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
FAILED_NAMES=""

note() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

# Run a script inside the image with the entrypoint bypassed. Any argument
# before the script is passed to `docker run` (used for -e).
in_image() {
    _script=$1
    shift
    docker run --rm "$@" --entrypoint sh "$IMAGE" -c "$_script" 2>&1
}

# The stub gcloud. Prints its argv into the log the way the real CLI's output
# would land there, then exits with $STUB_EXIT (0 unless a case overrides it).
# Written to /usr/local/bin and put first on PATH, so the absolute path run.sh
# uses is replaced too.
STUB_GCLOUD='
mkdir -p /stub
cat > /stub/gcloud <<STUB
#!/bin/sh
echo "ARGV: \$*"
exit ${STUB_EXIT:-0}
STUB
chmod +x /stub/gcloud
cp /stub/gcloud /google-cloud-sdk/bin/gcloud
'

expect_contains() {
    _hay=$1 _needle=$2 _label=${3:-output}
    case "$_hay" in
        *"$_needle"*) return 0 ;;
    esac
    note "$_label does not contain: $_needle"
    note "--- $_label ---"; note "$_hay"; note "--- end ---"
    return 1
}

expect_not_contains() {
    _hay=$1 _needle=$2 _label=${3:-output}
    case "$_hay" in
        *"$_needle"*)
            note "$_label unexpectedly contains: $_needle"
            note "--- $_label ---"; note "$_hay"; note "--- end ---"
            return 1 ;;
    esac
    return 0
}

expect_status() {
    if [ "$1" != "$2" ]; then
        note "expected exit status $2, got $1"
        return 1
    fi
}

# Run `run.sh backup` against the stub and return the log. GCSOPTIONS is the
# first argument; anything after it is passed to `docker run`. The value goes
# through `docker run -e` rather than being interpolated into the script, so
# quotes inside it reach run.sh exactly as a user would have set them.
backup_argv() {
    _opts=$1
    shift
    in_image "$STUB_GCLOUD"'
sh /opt/run.sh backup >/dev/null 2>&1
echo "__STATUS__:$?"
cat /var/log/cron.log' -e GCSPATH=gs://bucket/ -e "GCSOPTIONS=$_opts" "$@"
}

# ---------------------------------------------------------------------------
# Cases: GCSOPTIONS translation
# ---------------------------------------------------------------------------

case_translation_default() {
    out=$(backup_argv "")
    expect_contains "$out" "ARGV: storage rsync --recursive --no-ignore-symlinks /data gs://bucket/" "log" || return 1
    expect_contains "$out" "__STATUS__:0" "log" || return 1
}

case_translation_gsutil_flags() {
    out=$(backup_argv "-d -n -C -m -r -R")
    # -m, -r and -R have no gcloud equivalent and are dropped.
    expect_contains "$out" \
        "ARGV: storage rsync --recursive --no-ignore-symlinks --delete-unmatched-destination-objects --dry-run --continue-on-error /data gs://bucket/" \
        "log" || return 1
}

# The bug this guards: -e used to be appended to a hardcoded
# --no-ignore-symlinks, handing gcloud both halves of the same boolean flag.
case_translation_ignore_symlinks_not_contradicted() {
    out=$(backup_argv "-e")
    expect_contains "$out" "ARGV: storage rsync --recursive --ignore-symlinks /data gs://bucket/" "log" || return 1
    expect_not_contains "$out" "--no-ignore-symlinks --ignore-symlinks" "log" || return 1
}

# Passing the long form explicitly must not produce a duplicate either.
case_translation_explicit_no_ignore_symlinks() {
    out=$(backup_argv "--no-ignore-symlinks")
    expect_contains "$out" "ARGV: storage rsync --recursive --no-ignore-symlinks /data gs://bucket/" "log" || return 1
    expect_not_contains "$out" "--no-ignore-symlinks --no-ignore-symlinks" "log" || return 1
}

case_translation_exclude_pattern() {
    out=$(backup_argv "-x skipme")
    expect_contains "$out" "ARGV: storage rsync --recursive --no-ignore-symlinks --exclude skipme /data gs://bucket/" "log" || return 1
}

# The bug this guards: a pattern containing a space used to be split into two
# arguments, so it arrived as a stray positional and gcloud rejected the command.
case_translation_exclude_pattern_with_space() {
    out=$(backup_argv "-x 'my notes'")
    expect_contains "$out" "ARGV: storage rsync --recursive --no-ignore-symlinks --exclude my notes /data gs://bucket/" "log" || return 1
    expect_contains "$out" "__STATUS__:0" "log" || return 1
}

# An --exclude value is a regex, so it must reach gcloud verbatim: neither
# glob-expanded against the working directory, nor stripped of its backslashes.
case_translation_pattern_is_not_globbed() {
    out=$(backup_argv '-x .*\.log')
    expect_contains "$out" 'ARGV: storage rsync --recursive --no-ignore-symlinks --exclude .*\.log /data gs://bucket/' "log" || return 1
}

# A quoted pattern may contain both a space and a backslash.
case_translation_quoted_pattern_keeps_backslash() {
    out=$(backup_argv "-x 'my .*\.log notes'")
    expect_contains "$out" 'ARGV: storage rsync --recursive --no-ignore-symlinks --exclude my .*\.log notes /data gs://bucket/' "log" || return 1
}

case_translation_bare_star_is_not_globbed() {
    out=$(backup_argv '-x *')
    expect_contains "$out" "ARGV: storage rsync --recursive --no-ignore-symlinks --exclude * /data gs://bucket/" "log" || return 1
}

case_translation_dangling_exclude_is_reported() {
    out=$(backup_argv "-d -x")
    expect_contains "$out" "-x needs a pattern after it" "log" || return 1
    expect_contains "$out" "ARGV: storage rsync --recursive --no-ignore-symlinks --delete-unmatched-destination-objects /data gs://bucket/" "log" || return 1
}

case_translation_passthrough() {
    out=$(backup_argv "--exclude=logs --verbosity=warning")
    expect_contains "$out" "ARGV: storage rsync --recursive --no-ignore-symlinks --exclude=logs --verbosity=warning /data gs://bucket/" "log" || return 1
}

case_translation_unbalanced_quote_is_rejected() {
    out=$(backup_argv "-x 'unclosed")
    expect_contains "$out" "GCSOPTIONS could not be parsed" "log" || return 1
    expect_contains "$out" "__STATUS__:2" "log" || return 1
    expect_not_contains "$out" "ARGV:" "log" || return 1
}

# Every long flag the translator can emit must exist in the CLI that is actually
# installed, so a GCLOUD_VERSION bump cannot silently break backups.
case_translation_flags_exist_in_cli() {
    out=$(in_image '
        help=$(gcloud storage rsync --help 2>&1)
        for f in --recursive --no-ignore-symlinks --ignore-symlinks \
                 --delete-unmatched-destination-objects --dry-run \
                 --continue-on-error --exclude; do
            case "$help" in
                *"$f"*) ;;
                *) echo "MISSING: $f" ;;
            esac
        done
        echo CHECKED')
    expect_contains "$out" "CHECKED" "help probe" || return 1
    expect_not_contains "$out" "MISSING:" "help probe" || return 1
}

# ---------------------------------------------------------------------------
# Cases: exit status
# ---------------------------------------------------------------------------

# The bug this guards: a failing sync was logged but run.sh still exited 0, so
# nothing outside the log could tell that the backup had failed.
case_status_failure_is_propagated() {
    out=$(backup_argv "" -e STUB_EXIT=7)
    expect_contains "$out" "__STATUS__:7" "log" || return 1
    expect_contains "$out" "Sync FAILED with exit status 7" "log" || return 1
}

case_status_success_is_zero() {
    out=$(backup_argv "")
    expect_contains "$out" "__STATUS__:0" "log" || return 1
    expect_not_contains "$out" "Sync FAILED" "log" || return 1
}

# ---------------------------------------------------------------------------
# Cases: the lock
# ---------------------------------------------------------------------------

case_lock_live_pid_blocks() {
    # A lock held by a process that really is alive must stop a second run.
    out=$(in_image "$STUB_GCLOUD"'
        sleep 300 &
        echo $! > /tmp/gcloudlock.lock
        sh /opt/run.sh backup >/dev/null 2>&1
        echo "__STATUS__:$?"
        cat /var/log/cron.log' -e GCSPATH=gs://bucket/)
    expect_contains "$out" "__STATUS__:1" "log" || return 1
    expect_contains "$out" "detected, exiting! Already running?" "log" || return 1
    expect_not_contains "$out" "ARGV:" "log" || return 1
}

# The bug this guards: a lock left behind by a killed run used to block every
# later backup until the container was recreated.
case_lock_dead_pid_is_taken_over() {
    out=$(in_image "$STUB_GCLOUD"'
        # A pid that has certainly exited.
        sh -c "echo \$\$ > /tmp/gcloudlock.lock"
        sh /opt/run.sh backup >/dev/null 2>&1
        echo "__STATUS__:$?"
        cat /var/log/cron.log' -e GCSPATH=gs://bucket/)
    expect_contains "$out" "is stale" "log" || return 1
    expect_contains "$out" "__STATUS__:0" "log" || return 1
    expect_contains "$out" "ARGV:" "log" || return 1
}

case_lock_empty_file_is_taken_over() {
    out=$(in_image "$STUB_GCLOUD"'
        touch /tmp/gcloudlock.lock
        sh /opt/run.sh backup >/dev/null 2>&1
        echo "__STATUS__:$?"
        cat /var/log/cron.log' -e GCSPATH=gs://bucket/)
    expect_contains "$out" "holds no pid" "log" || return 1
    expect_contains "$out" "__STATUS__:0" "log" || return 1
}

case_lock_is_released_after_a_run() {
    out=$(in_image "$STUB_GCLOUD"'
        sh /opt/run.sh backup >/dev/null 2>&1
        [ -e /tmp/gcloudlock.lock ] && echo "LOCK_LEAKED" || echo "LOCK_RELEASED"' -e GCSPATH=gs://bucket/)
    expect_contains "$out" "LOCK_RELEASED" "probe" || return 1
}

# A run killed mid-sync must not leave the lock behind for the next one.
case_lock_is_released_when_interrupted() {
    out=$(in_image '
        mkdir -p /stub
        printf "#!/bin/sh\nsleep 300\n" > /google-cloud-sdk/bin/gcloud
        chmod +x /google-cloud-sdk/bin/gcloud
        sh /opt/run.sh backup >/dev/null 2>&1 &
        child=$!
        # Wait for the lock to appear, then terminate the run.
        i=0
        while [ ! -e /tmp/gcloudlock.lock ] && [ $i -lt 50 ]; do i=$((i+1)); sleep 0.1; done
        kill -TERM $child 2>/dev/null
        wait $child 2>/dev/null
        [ -e /tmp/gcloudlock.lock ] && echo "LOCK_LEAKED" || echo "LOCK_RELEASED"' -e GCSPATH=gs://bucket/)
    expect_contains "$out" "LOCK_RELEASED" "probe" || return 1
}

# ---------------------------------------------------------------------------
# Cases: configuration validation
# ---------------------------------------------------------------------------

case_config_missing_gcspath() {
    out=$(in_image 'sh /opt/run.sh setup; echo "__STATUS__:$?"' -e GCSPATH=)
    expect_contains "$out" "GCSPATH required" "setup output" || return 1
    expect_contains "$out" "__STATUS__:1" "setup output" || return 1
}

case_config_missing_key_file() {
    out=$(in_image 'sh /opt/run.sh setup; echo "__STATUS__:$?"' -e GCSPATH=gs://bucket/)
    expect_contains "$out" "Service account key not found at /secrets/sa.json" "setup output" || return 1
    expect_contains "$out" "-v /path/on/host/secrets:/secrets:ro" "setup output" || return 1
    expect_contains "$out" "__STATUS__:1" "setup output" || return 1
}

# /secrets is mounted, but the key in it is not named sa.json.
case_config_key_file_not_found() {
    out=$(in_image 'mkdir -p /secrets; echo "{}" > /secrets/key.json
        sh /opt/run.sh setup; echo "__STATUS__:$?"' \
        -e GCSPATH=gs://bucket/)
    expect_contains "$out" "Service account key not found at /secrets/sa.json" "setup output" || return 1
    expect_contains "$out" "__STATUS__:1" "setup output" || return 1
}

case_config_key_file_not_a_key() {
    out=$(in_image 'mkdir -p /secrets; echo "{\"foo\":\"bar\"}" > /secrets/sa.json
        sh /opt/run.sh setup; echo "__STATUS__:$?"' \
        -e GCSPATH=gs://bucket/)
    expect_contains "$out" "is not a service account JSON key file" "setup output" || return 1
    expect_contains "$out" "__STATUS__:1" "setup output" || return 1
}

case_config_legacy_keys_are_rejected() {
    out=$(in_image 'sh /opt/run.sh setup; echo "__STATUS__:$?"' \
        -e GCSPATH=gs://bucket/ -e ACCESS_KEY=k -e SECRET_KEY=s)
    expect_contains "$out" "no longer supported as of version 2.0" "setup output" || return 1
    expect_contains "$out" "__STATUS__:1" "setup output" || return 1
    # The explanation answers the generic complaint, so it must not be followed
    # by it as well.
    expect_not_contains "$out" "Service account key not found" "setup output" || return 1
}

# Someone upgrading needs to know the switch was forced by Google retiring
# gsutil, not chosen - otherwise the credential change looks arbitrary.
case_config_legacy_keys_explain_the_deprecation() {
    out=$(in_image 'sh /opt/run.sh setup' \
        -e GCSPATH=gs://bucket/ -e ACCESS_KEY=k -e SECRET_KEY=s)
    expect_contains "$out" "WHY THIS CHANGED" "setup output" || return 1
    expect_contains "$out" "retiring gsutil" "setup output" || return 1
    expect_contains "$out" "March 2027" "setup output" || return 1
    expect_contains "$out" "gcloud storage" "setup output" || return 1
    # And what to actually do about it.
    expect_contains "$out" "HOW TO MIGRATE" "setup output" || return 1
    expect_contains "$out" "-v /path/on/host/secrets:/secrets:ro" "setup output" || return 1
    expect_contains "$out" "Storage Object Admin" "setup output" || return 1
}

# BOTO_FILE on its own has to trigger the same explanation.
case_config_boto_file_explains_the_deprecation() {
    out=$(in_image 'sh /opt/run.sh setup; echo "__STATUS__:$?"' \
        -e GCSPATH=gs://bucket/ -e BOTO_FILE=/tmp/boto)
    expect_contains "$out" "retiring gsutil" "setup output" || return 1
    expect_contains "$out" "March 2027" "setup output" || return 1
    expect_contains "$out" "__STATUS__:1" "setup output" || return 1
}

# Already migrated, but the old variables are still lying around: that is a
# warning, not a failure, and it should still say why they stopped mattering.
case_config_legacy_leftovers_only_warn() {
    out=$(setup_dry 'true' -e ACCESS_KEY=k)
    expect_contains "$out" "WARNING: ACCESS_KEY, SECRET_KEY and BOTO_FILE are ignored" "setup output" || return 1
    expect_contains "$out" "retiring" "setup output" || return 1
    # It got past the credentials check and finished setup.
    expect_contains "$out" "SETUP_DONE" "setup output" || return 1
    expect_not_contains "$out" "WHY THIS CHANGED" "setup output" || return 1
}

# The menu itself has to carry the reason too, for someone reading `help`
# before they hit the error.
case_help_explains_the_deprecation() {
    out=$(in_image 'sh /opt/run.sh help')
    expect_contains "$out" "REMOVED IN 2.0" "help output" || return 1
    expect_contains "$out" "retiring gsutil" "help output" || return 1
    expect_contains "$out" "March 2027" "help output" || return 1
}

# A malformed schedule is accepted by crond and then never fires, so it is
# rejected at startup instead.
case_config_bad_cron_schedule() {
    out=$(in_image 'sh /opt/run.sh setup; echo "__STATUS__:$?"' \
        -e GCSPATH=gs://bucket/ -e CRON_SCHEDULE="0 3 * *")
    expect_contains "$out" "CRON_SCHEDULE must have 5 fields" "setup output" || return 1
    expect_contains "$out" "__STATUS__:1" "setup output" || return 1
}

# A schedule is mostly '*' characters: validation must count fields without
# letting the shell expand them into file names.
case_config_normal_cron_schedule_is_accepted() {
    out=$(in_image 'sh /opt/run.sh setup; echo "__STATUS__:$?"' \
        -e GCSPATH=gs://bucket/ -e CRON_SCHEDULE="*/17 * * * *")
    expect_not_contains "$out" "CRON_SCHEDULE must have 5 fields" "setup output" || return 1
    expect_contains "$out" "Service account key not found at /secrets/sa.json" "setup output" || return 1
}

case_config_cron_macro_is_accepted() {
    # @daily is valid for busybox crond, so validation must let it through: it
    # gets as far as the key file check, which is the next thing setup does.
    out=$(in_image 'sh /opt/run.sh setup; echo "__STATUS__:$?"' \
        -e GCSPATH=gs://bucket/ -e CRON_SCHEDULE="@daily")
    expect_not_contains "$out" "CRON_SCHEDULE must have 5 fields" "setup output" || return 1
    expect_contains "$out" "Service account key not found at /secrets/sa.json" "setup output" || return 1
}

# ---------------------------------------------------------------------------
# Cases: healthcheck
# ---------------------------------------------------------------------------

case_health_no_run_yet_is_healthy() {
    out=$(in_image 'sh /opt/run.sh healthcheck; echo "__STATUS__:$?"')
    expect_contains "$out" "no backup has completed yet" "healthcheck output" || return 1
    expect_contains "$out" "__STATUS__:0" "healthcheck output" || return 1
}

case_health_after_success_is_healthy() {
    out=$(in_image "$STUB_GCLOUD"'
        sh /opt/run.sh backup >/dev/null 2>&1
        sh /opt/run.sh healthcheck; echo "__STATUS__:$?"' -e GCSPATH=gs://bucket/)
    expect_contains "$out" "last backup succeeded" "healthcheck output" || return 1
    expect_contains "$out" "__STATUS__:0" "healthcheck output" || return 1
}

case_health_after_failure_is_unhealthy() {
    out=$(in_image "$STUB_GCLOUD"'
        sh /opt/run.sh backup >/dev/null 2>&1
        sh /opt/run.sh healthcheck; echo "__STATUS__:$?"' \
        -e GCSPATH=gs://bucket/ -e STUB_EXIT=7)
    expect_contains "$out" "last backup FAILED with exit status 7" "healthcheck output" || return 1
    expect_contains "$out" "__STATUS__:1" "healthcheck output" || return 1
}

case_health_is_declared_in_the_image() {
    out=$(docker inspect -f '{{json .Config.Healthcheck.Test}}' "$IMAGE" 2>&1)
    expect_contains "$out" "healthcheck" "image healthcheck" || return 1
}

# ---------------------------------------------------------------------------
# Cases: the log
# ---------------------------------------------------------------------------

case_log_is_trimmed_when_too_big() {
    out=$(in_image "$STUB_GCLOUD"'
        # 200 KB of filler, with a marker at the very start.
        echo "OLDEST_LINE_MARKER" > /var/log/cron.log
        i=0
        while [ $i -lt 2000 ]; do
            printf "%0100d\n" $i >> /var/log/cron.log
            i=$((i+1))
        done
        before=$(wc -c < /var/log/cron.log)
        sh /opt/run.sh backup >/dev/null 2>&1
        after=$(wc -c < /var/log/cron.log)
        echo "BEFORE:$before AFTER:$after"
        grep -q OLDEST_LINE_MARKER /var/log/cron.log && echo "MARKER_KEPT" || echo "MARKER_TRIMMED"
        grep -q "ARGV:" /var/log/cron.log && echo "RUN_LOGGED"' \
        -e GCSPATH=gs://bucket/ -e LOG_MAX_BYTES=102400)
    expect_contains "$out" "MARKER_TRIMMED" "probe" || return 1
    expect_contains "$out" "RUN_LOGGED" "probe" || return 1
    # The trimmed log must be smaller than the cap, and the run's own lines kept.
    _sizes=$(printf '%s\n' "$out" | sed -n 's/^BEFORE:\([0-9]*\) AFTER:\([0-9]*\)$/\1 \2/p')
    _before=${_sizes% *}
    _after=${_sizes#* }
    if [ -z "$_before" ] || [ "$_after" -ge "$_before" ]; then
        note "log was not trimmed (before=$_before after=$_after)"
        return 1
    fi
}

case_log_trim_disabled_by_zero() {
    out=$(in_image "$STUB_GCLOUD"'
        echo "OLDEST_LINE_MARKER" > /var/log/cron.log
        i=0
        while [ $i -lt 500 ]; do printf "%0100d\n" $i >> /var/log/cron.log; i=$((i+1)); done
        sh /opt/run.sh backup >/dev/null 2>&1
        grep -q OLDEST_LINE_MARKER /var/log/cron.log && echo "MARKER_KEPT" || echo "MARKER_TRIMMED"' \
        -e GCSPATH=gs://bucket/ -e LOG_MAX_BYTES=0)
    expect_contains "$out" "MARKER_KEPT" "probe" || return 1
}

# ---------------------------------------------------------------------------
# Cases: setup, the env file and the crontab
# ---------------------------------------------------------------------------

# setup ends in `exec tail -F`, so it never returns. These cases stop it right
# before that and inspect what it produced.
setup_dry() {
    _extra=$1
    shift
    in_image '
        mkdir -p /secrets
        python3 - <<PY
import json
json.dump({"type":"service_account","project_id":"p","private_key":"-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n","client_email":"sa@p.iam.gserviceaccount.com"}, open("/secrets/sa.json","w"))
PY
        # Stop before crond/tail, which would block forever.
        sed "s|^  crond -L .*|  echo CROND_WOULD_START|; s|^  exec tail.*|  echo SETUP_DONE|" /opt/run.sh > /tmp/setup.sh
        '"$_extra"'
        sh /tmp/setup.sh setup' \
        -e GCSPATH=gs://bucket/ "$@"
}

case_setup_crontab_is_a_bare_job_line() {
    out=$(setup_dry 'true' -e CRON_SCHEDULE="*/17 * * * *" -e GCSOPTIONS=-d)
    expect_contains "$out" "SETUP_DONE" "setup output" || return 1
    expect_contains "$out" "*/17 * * * * sh /opt/run.sh backup" "crontab" || return 1
    # The environment lives in the env file now, not in the crontab line, where
    # every value had to survive being embedded in a shell command.
    expect_not_contains "$out" 'GCSPATH="gs://bucket/" ' "crontab" || return 1
}

# Everything the scheduled run needs must come back out of the env file, with
# quoting intact, when the environment cron provides is empty.
case_setup_env_file_round_trips() {
    out=$(in_image "$STUB_GCLOUD"'
        mkdir -p /secrets
        python3 - <<PY
import json
json.dump({"type":"service_account","project_id":"p","private_key":"-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n","client_email":"sa@p.iam.gserviceaccount.com"}, open("/secrets/sa.json","w"))
PY
        sed "s|^  crond -L .*|  echo CROND_WOULD_START|; s|^  exec tail.*|  echo SETUP_DONE|" /opt/run.sh > /tmp/setup.sh
        sh /tmp/setup.sh setup >/dev/null 2>&1
        echo "--- env file ---"
        cat /tmp/gcsbackup.env
        echo "--- backup with an empty environment, the way cron runs it ---"
        rm -f /var/log/cron.log
        env -i sh /opt/run.sh backup >/dev/null 2>&1
        echo "__STATUS__:$?"
        cat /var/log/cron.log' \
        -e GCSPATH=gs://bucket/ \
        -e "GCSOPTIONS=-x 'my notes'" -e PROJECT_ID=my-project \
        -e CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE=http://example/storage/v1/)
    expect_contains "$out" "GCSPATH='gs://bucket/'" "env file" || return 1
    expect_contains "$out" "CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE='http://example/storage/v1/'" "env file" || return 1
    expect_contains "$out" "CLOUDSDK_CORE_PROJECT='my-project'" "env file" || return 1
    expect_contains "$out" "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE='/secrets/sa.json'" "env file" || return 1
    # The quoted pattern survived setup, the file and the cron-like run.
    expect_contains "$out" "ARGV: storage rsync --recursive --no-ignore-symlinks --exclude my notes /data gs://bucket/" "cron.log" || return 1
    expect_contains "$out" "__STATUS__:0" "cron.log" || return 1
}

# An explicit variable must still beat the env file, so a one-off
# `docker exec -e GCSOPTIONS=-n ... run.sh backup` works.
case_setup_env_file_yields_to_real_environment() {
    out=$(in_image "$STUB_GCLOUD"'
        printf ": \${GCSOPTIONS:=-d}\nexport GCSOPTIONS\n" > /tmp/gcsbackup.env
        printf ": \${GCSPATH:=gs://from-file/}\nexport GCSPATH\n" >> /tmp/gcsbackup.env
        GCSOPTIONS=-n sh /opt/run.sh backup >/dev/null 2>&1
        cat /var/log/cron.log' )
    expect_contains "$out" "--dry-run" "cron.log" || return 1
    expect_not_contains "$out" "--delete-unmatched-destination-objects" "cron.log" || return 1
    # GCSPATH was not in the environment, so the file supplied it.
    expect_contains "$out" "gs://from-file/" "cron.log" || return 1
}

case_setup_runs_backup_on_startup_when_asked() {
    out=$(in_image "$STUB_GCLOUD"'
        mkdir -p /secrets
        python3 - <<PY
import json
json.dump({"type":"service_account","project_id":"p","private_key":"-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n","client_email":"sa@p.iam.gserviceaccount.com"}, open("/secrets/sa.json","w"))
PY
        sed "s|^  crond -L .*|  echo CROND_WOULD_START|; s|^  exec tail.*|  echo SETUP_DONE|" /opt/run.sh > /tmp/setup.sh
        sh /tmp/setup.sh setup
        echo "--- log ---"
        cat /var/log/cron.log' \
        -e GCSPATH=gs://bucket/ -e RUN_ON_STARTUP=true)
    expect_contains "$out" "RUN_ON_STARTUP is set" "setup output" || return 1
    expect_contains "$out" "Initial backup finished with exit status 0" "setup output" || return 1
    expect_contains "$out" "ARGV: storage rsync" "log" || return 1
}

case_setup_does_not_run_backup_by_default() {
    out=$(setup_dry 'true')
    expect_not_contains "$out" "RUN_ON_STARTUP is set" "setup output" || return 1
    expect_contains "$out" "SETUP_DONE" "setup output" || return 1
}

case_setup_reports_the_service_account() {
    out=$(setup_dry 'true')
    expect_contains "$out" "Using service account sa@p.iam.gserviceaccount.com" "setup output" || return 1
    # The gcloud auth list caveat is surfaced where people will hit it.
    expect_contains "$out" "gcloud auth list" "setup output" || return 1
}

# ---------------------------------------------------------------------------
# Cases: the help menu
# ---------------------------------------------------------------------------

case_help_command_prints_the_menu() {
    out=$(in_image 'sh /opt/run.sh help; echo "__STATUS__:$?"')
    expect_contains "$out" "__STATUS__:0" "help output" || return 1
    expect_contains "$out" "SETTINGS" "help output" || return 1
    expect_contains "$out" "GCSOPTIONS VALUES" "help output" || return 1
    expect_contains "$out" "COMMANDS" "help output" || return 1
    # Every setting has to be listed.
    for v in /secrets/sa.json /data GCSPATH CRON_SCHEDULE TZ GCSOPTIONS \
             PROJECT_ID RUN_ON_STARTUP LOG_MAX_BYTES; do
        expect_contains "$out" "$v" "help output" || return 1
    done
}

case_help_accepts_flag_spellings() {
    for arg in --help -h; do
        out=$(in_image "sh /opt/run.sh $arg; echo \"__STATUS__:\$?\"")
        expect_contains "$out" "__STATUS__:0" "help output for $arg" || return 1
        expect_contains "$out" "SETTINGS" "help output for $arg" || return 1
    done
}

# The point of printing it at startup: a container that refuses to start still
# says what it was looking for.
case_help_shown_when_configuration_is_missing() {
    out=$(in_image 'sh /opt/run.sh setup; echo "__STATUS__:$?"' -e GCSPATH=)
    expect_contains "$out" "SETTINGS" "setup output" || return 1
    expect_contains "$out" "GCSPATH required" "setup output" || return 1
    expect_contains "$out" "__STATUS__:1" "setup output" || return 1
}

case_help_shown_when_credentials_are_legacy() {
    out=$(in_image 'sh /opt/run.sh setup; echo "__STATUS__:$?"' \
        -e GCSPATH=gs://bucket/ -e ACCESS_KEY=k -e SECRET_KEY=s)
    expect_contains "$out" "SETTINGS" "setup output" || return 1
    expect_contains "$out" "no longer supported as of version 2.0" "setup output" || return 1
    expect_contains "$out" "__STATUS__:1" "setup output" || return 1
}

case_help_shown_on_a_bad_schedule() {
    out=$(in_image 'sh /opt/run.sh setup; echo "__STATUS__:$?"' \
        -e GCSPATH=gs://bucket/ -e CRON_SCHEDULE="0 3 * *")
    expect_contains "$out" "SETTINGS" "setup output" || return 1
    expect_contains "$out" "CRON_SCHEDULE must have 5 fields" "setup output" || return 1
}

case_help_shown_on_a_successful_start() {
    out=$(setup_dry 'true' -e CRON_SCHEDULE="*/17 * * * *")
    expect_contains "$out" "SETTINGS" "setup output" || return 1
    expect_contains "$out" "SETUP_DONE" "setup output" || return 1
}

case_help_reports_the_effective_values() {
    out=$(in_image 'sh /opt/run.sh setup' \
        -e GCSPATH=gs://real-bucket/sub/ -e TZ=America/Montreal \
        -e GCSOPTIONS=-d -e PROJECT_ID=my-proj -e RUN_ON_STARTUP=true \
        -e LOG_MAX_BYTES=0 -e CRON_SCHEDULE=@daily)
    expect_contains "$out" "now: gs://real-bucket/sub/" "help output" || return 1
    expect_contains "$out" "now: America/Montreal" "help output" || return 1
    expect_contains "$out" "now: -d" "help output" || return 1
    expect_contains "$out" "now: my-proj" "help output" || return 1
    expect_contains "$out" "now: true" "help output" || return 1
    expect_contains "$out" "now: 0" "help output" || return 1
    expect_contains "$out" "now: @daily" "help output" || return 1
}

# An unset optional setting says so rather than showing an empty line.
case_help_marks_unset_settings() {
    out=$(in_image 'sh /opt/run.sh setup' -e GCSPATH=gs://bucket/)
    expect_contains "$out" "now: (not set)" "help output" || return 1
}

# A rejected timezone falls back to UTC, so the menu must show UTC and not the
# value that was asked for.
case_help_shows_the_timezone_actually_applied() {
    out=$(in_image 'sh /opt/run.sh setup' -e GCSPATH=gs://bucket/ -e TZ=Mars/Olympus_Mons)
    expect_contains "$out" "Unknown timezone" "setup output" || return 1
    expect_contains "$out" "now: UTC" "help output" || return 1
}

case_help_shown_for_an_unsupported_option() {
    out=$(in_image 'sh /opt/run.sh frobnicate; echo "__STATUS__:$?"')
    expect_contains "$out" "Unsupported option: frobnicate" "output" || return 1
    expect_contains "$out" "SETTINGS" "output" || return 1
    expect_contains "$out" "__STATUS__:1" "output" || return 1
}

# It must NOT be printed by a backup: cron runs one every hour, and the whole
# menu in the log each time would bury the transfer output.
case_help_not_printed_by_a_backup() {
    out=$(backup_argv "")
    expect_not_contains "$out" "SETTINGS" "cron.log" || return 1
    expect_not_contains "$out" "GCSOPTIONS VALUES" "cron.log" || return 1
    expect_contains "$out" "ARGV: storage rsync" "cron.log" || return 1
}

# The healthcheck's output is what `docker inspect` shows, so it stays a line.
case_help_not_printed_by_the_healthcheck() {
    out=$(in_image 'sh /opt/run.sh healthcheck')
    expect_not_contains "$out" "SETTINGS" "healthcheck output" || return 1
    expect_contains "$out" "no backup has completed yet" "healthcheck output" || return 1
}

# ---------------------------------------------------------------------------
# Cases: image contents
# ---------------------------------------------------------------------------

case_image_gsutil_absent() {
    out=$(in_image '
        command -v gsutil && echo FOUND_ON_PATH
        [ -e /google-cloud-sdk/bin/gsutil ] && echo FOUND_IN_BIN
        [ -d /google-cloud-sdk/platform/gsutil ] && echo FOUND_COMPONENT
        echo CHECKED')
    expect_contains "$out" "CHECKED" "probe" || return 1
    expect_not_contains "$out" "FOUND_ON_PATH" "probe" || return 1
    expect_not_contains "$out" "FOUND_IN_BIN" "probe" || return 1
    expect_not_contains "$out" "FOUND_COMPONENT" "probe" || return 1
}

case_image_bundled_python_absent() {
    out=$(in_image '
        [ -d /google-cloud-sdk/platform/bundledpythonunix ] && echo FOUND_BUNDLED
        command -v python3
        gcloud version >/dev/null 2>&1 && echo GCLOUD_RUNS
        echo CHECKED')
    expect_contains "$out" "CHECKED" "probe" || return 1
    expect_not_contains "$out" "FOUND_BUNDLED" "probe" || return 1
    # Removing it is only safe because the CLI runs on Alpine's interpreter.
    expect_contains "$out" "GCLOUD_RUNS" "probe" || return 1
}

# install.sh byte-compiles the CLI, and those caches must ship in the image:
# without them every scheduled run recompiles into the container's writable layer.
case_image_keeps_bytecode_caches() {
    out=$(in_image 'find /google-cloud-sdk -name "*.pyc" | head -1000 | wc -l')
    _count=$(printf '%s\n' "$out" | tr -d ' ')
    case "$_count" in
        ''|*[!0-9]*) note "unexpected probe output: $out"; return 1 ;;
    esac
    if [ "$_count" -lt 100 ]; then
        note "expected the image to ship .pyc caches, found $_count"
        return 1
    fi
}

case_image_runs_on_busybox_sh() {
    # run.sh must not need bash: the image does not have it.
    out=$(in_image 'command -v bash && echo FOUND_BASH; head -1 /opt/run.sh; echo CHECKED')
    expect_contains "$out" "#!/bin/sh" "probe" || return 1
    expect_not_contains "$out" "FOUND_BASH" "probe" || return 1
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

run_case() {
    _name=$1 _fn=$2

    if [ -n "$FILTER" ]; then
        _matched=0
        for _arg in $FILTER; do
            case "$_name" in *"$_arg"*) _matched=1 ;; esac
        done
        if [ "$_matched" = "0" ]; then
            SKIPPED=$((SKIPPED + 1))
            return 0
        fi
    fi

    TOTAL=$((TOTAL + 1))
    if _out=$("$_fn" 2>&1); then
        PASSED=$((PASSED + 1))
        printf 'PASS  %s\n' "$_name"
    else
        FAILED=$((FAILED + 1))
        FAILED_NAMES="${FAILED_NAMES}${_name}
"
        printf 'FAIL  %s\n' "$_name"
        printf '%s\n' "$_out" | sed 's/^/        /'
    fi
}

if [ -z "$IMAGE" ]; then
    IMAGE=gcloud-storage-docker:smoke
    printf -- '--- building %s ---\n' "$IMAGE"
    docker build -t "$IMAGE" "$REPO_DIR" >/dev/null || {
        printf 'ERROR: build failed\n' >&2
        exit 1
    }
fi
printf -- '--- testing %s ---\n\n' "$IMAGE"

printf -- '--- GCSOPTIONS translation ---\n'
run_case "translation: no options"                            case_translation_default
run_case "translation: gsutil flags map, -m/-r/-R dropped"    case_translation_gsutil_flags
run_case "translation: -e does not contradict the default"    case_translation_ignore_symlinks_not_contradicted
run_case "translation: explicit --no-ignore-symlinks once"    case_translation_explicit_no_ignore_symlinks
run_case "translation: -x pattern"                            case_translation_exclude_pattern
run_case "translation: -x pattern containing a space"         case_translation_exclude_pattern_with_space
run_case "translation: -x regex is not glob-expanded"         case_translation_pattern_is_not_globbed
run_case "translation: quoted -x keeps its backslash"         case_translation_quoted_pattern_keeps_backslash
run_case "translation: -x '*' is not glob-expanded"           case_translation_bare_star_is_not_globbed
run_case "translation: -x with no pattern is reported"        case_translation_dangling_exclude_is_reported
run_case "translation: gcloud flags pass through"             case_translation_passthrough
run_case "translation: unbalanced quote is rejected"          case_translation_unbalanced_quote_is_rejected
run_case "translation: every emitted flag exists in the CLI"  case_translation_flags_exist_in_cli

printf -- '\n--- exit status ---\n'
run_case "status: a failed sync exits non-zero"               case_status_failure_is_propagated
run_case "status: a successful sync exits 0"                  case_status_success_is_zero

printf -- '\n--- lock ---\n'
run_case "lock: a live pid blocks a second run"               case_lock_live_pid_blocks
run_case "lock: a dead pid is taken over"                     case_lock_dead_pid_is_taken_over
run_case "lock: an empty lock file is taken over"             case_lock_empty_file_is_taken_over
run_case "lock: released after a normal run"                  case_lock_is_released_after_a_run
run_case "lock: released when the run is interrupted"         case_lock_is_released_when_interrupted

printf -- '\n--- configuration validation ---\n'
run_case "config: missing GCSPATH exits 1"                    case_config_missing_gcspath
run_case "config: no key in /secrets exits 1"                 case_config_missing_key_file
run_case "config: key not named sa.json exits 1"              case_config_key_file_not_found
run_case "config: file is not a key exits 1"                  case_config_key_file_not_a_key
run_case "config: legacy HMAC keys exit 1"                    case_config_legacy_keys_are_rejected
run_case "config: legacy keys explain the deprecation"        case_config_legacy_keys_explain_the_deprecation
run_case "config: BOTO_FILE explains the deprecation"         case_config_boto_file_explains_the_deprecation
run_case "config: migrated leftovers only warn"               case_config_legacy_leftovers_only_warn
run_case "config: a malformed CRON_SCHEDULE exits 1"          case_config_bad_cron_schedule
run_case "config: a normal '*/17 * * * *' is accepted"        case_config_normal_cron_schedule_is_accepted
run_case "config: an @macro schedule is accepted"             case_config_cron_macro_is_accepted

printf -- '\n--- healthcheck ---\n'
run_case "health: healthy before the first backup"            case_health_no_run_yet_is_healthy
run_case "health: healthy after a successful backup"          case_health_after_success_is_healthy
run_case "health: unhealthy after a failed backup"            case_health_after_failure_is_unhealthy
run_case "health: declared in the image"                      case_health_is_declared_in_the_image

printf -- '\n--- log ---\n'
run_case "log: trimmed once past LOG_MAX_BYTES"               case_log_is_trimmed_when_too_big
run_case "log: LOG_MAX_BYTES=0 disables trimming"             case_log_trim_disabled_by_zero

printf -- '\n--- setup ---\n'
run_case "setup: the crontab line carries no environment"     case_setup_crontab_is_a_bare_job_line
run_case "setup: env file round-trips to a cron-like run"     case_setup_env_file_round_trips
run_case "setup: a real variable beats the env file"          case_setup_env_file_yields_to_real_environment
run_case "setup: RUN_ON_STARTUP runs a backup"                case_setup_runs_backup_on_startup_when_asked
run_case "setup: no startup backup by default"                case_setup_does_not_run_backup_by_default
run_case "setup: reports the service account and the caveat"  case_setup_reports_the_service_account

printf -- '\n--- help menu ---\n'
run_case "help: the help command prints the menu"             case_help_command_prints_the_menu
run_case "help: --help and -h work too"                       case_help_accepts_flag_spellings
run_case "help: shown when configuration is missing"          case_help_shown_when_configuration_is_missing
run_case "help: shown when credentials are legacy"            case_help_shown_when_credentials_are_legacy
run_case "help: shown on a malformed schedule"                case_help_shown_on_a_bad_schedule
run_case "help: shown on a successful start"                  case_help_shown_on_a_successful_start
run_case "help: reports the effective values"                 case_help_reports_the_effective_values
run_case "help: marks unset settings"                       case_help_marks_unset_settings
run_case "help: shows the timezone actually applied"          case_help_shows_the_timezone_actually_applied
run_case "help: shown for an unsupported option"              case_help_shown_for_an_unsupported_option
run_case "help: not printed by a backup"                      case_help_not_printed_by_a_backup
run_case "help: not printed by the healthcheck"               case_help_not_printed_by_the_healthcheck
run_case "help: the menu explains the deprecation"            case_help_explains_the_deprecation

printf -- '\n--- image ---\n'
run_case "image: gsutil is absent"                            case_image_gsutil_absent
run_case "image: the bundled Python is absent"                case_image_bundled_python_absent
run_case "image: bytecode caches are shipped"                 case_image_keeps_bytecode_caches
run_case "image: runs on busybox sh, no bash"                 case_image_runs_on_busybox_sh

printf -- '\n=== summary: %d run, %d passed, %d failed' "$TOTAL" "$PASSED" "$FAILED"
if [ "$SKIPPED" -gt 0 ]; then
    printf ', %d not selected' "$SKIPPED"
fi
printf ' ===\n'
if [ "$FAILED" -gt 0 ]; then
    printf 'failed cases:\n'
    printf '%s' "$FAILED_NAMES" | grep -v '^$' | sed 's/^/  - /'
    exit 1
fi
exit 0
