#!/usr/bin/env bash
#
# End-to-end test suite for the gcloud-storage-docker image.
#
# Runs the image under test against fake-gcs-server, a local Google Cloud
# Storage stand-in, so backup behaviour is verified for real - files actually
# transferred, bucket contents asserted - without a GCP project and without real
# credentials. See tests/README.md.
#
# Usage:
#   tests/run-tests.sh                 # run everything
#   tests/run-tests.sh transfer        # run only cases whose name matches an argument
#   KEEP_WORK=1 tests/run-tests.sh     # keep the work directory for inspection
#   SKIP_SLOW=1 tests/run-tests.sh     # skip the two cases that wait for cron (~4 min)
#
# One run at a time, unless both TEST_PROJECT and TEST_WORK_DIR are overridden:
#   TEST_PROJECT=mine TEST_WORK_DIR=/tmp/mine tests/run-tests.sh
#
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
FIXTURES="$SCRIPT_DIR/fixtures/data"

# Compose project the stack lives in. Overriding it (together with
# TEST_WORK_DIR) is what makes two runs on one machine independent: containers,
# network and built images are all named after the project. COMPOSE_PROJECT_NAME
# takes precedence over the `name:` in the compose file.
TEST_PROJECT=${TEST_PROJECT:-gcsbackup-tests}
export COMPOSE_PROJECT_NAME="$TEST_PROJECT"

# The image compose builds for the service under test: project plus service name.
# Only used to inspect image metadata (the HEALTHCHECK).
IMAGE_UNDER_TEST="$TEST_PROJECT-backup"

# Mutable trees the stack binds into its containers. Kept outside the repo.
TMP_BASE=${TMPDIR:-/tmp}
TEST_WORK_DIR=${TEST_WORK_DIR:-${TMP_BASE%/}/gcsbackup-tests}
TEST_WORK_DIR=${TEST_WORK_DIR%/}
export TEST_WORK_DIR
DATA_DIR="$TEST_WORK_DIR/data"
BUCKETS_DIR="$TEST_WORK_DIR/buckets"
SECRETS_DIR="$TEST_WORK_DIR/secrets"

# The object names produced by backing up tests/fixtures/data as-is.
FIXTURE_OBJECTS="hello.txt logs/app.log notes/deep/nested.txt notes/readme.md skipme/ignored.txt"

# The environment busybox crond hands the jobs it starts. Used to exercise the
# scheduled path without waiting a minute for cron.
CROND_ENV="env -i HOME=/root SHELL=/bin/sh PATH=/usr/bin:/bin USER=root LOGNAME=root"

# Containers individual cases start detached, torn down by cleanup(). Prefixed
# with the project so two runs cannot take each other's names.
CN_PREFIX="$TEST_PROJECT-case-"
NAMED_CONTAINERS=""
for c in legacy-keys macro default-schedule crontab envfile handrun cronenv startup cron tz; do
    NAMED_CONTAINERS="$NAMED_CONTAINERS $CN_PREFIX$c"
done

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
FAILED_NAMES=""

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

note() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------------------
# Stack lifecycle
# ---------------------------------------------------------------------------

cleanup() {
    status=$?
    printf '\n--- tearing down ---\n'
    for c in $NAMED_CONTAINERS; do
        docker rm -f "$c" >/dev/null 2>&1
    done
    dc down --remove-orphans >/dev/null 2>&1
    if [ "${KEEP_WORK:-0}" = "1" ]; then
        printf 'work directory kept: %s\n' "$TEST_WORK_DIR"
    else
        rm -rf "$TEST_WORK_DIR"
    fi
    exit $status
}

# Generate a syntactically valid, completely fake service account key. run.sh
# accepts it and gcloud signs a JWT with it; only the token exchange with Google
# would fail, which no case relies on succeeding.
generate_fake_key() {
    local pem escaped
    pem=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)
    if [ -z "$pem" ]; then
        printf 'ERROR: could not generate an RSA key with openssl\n' >&2
        exit 1
    fi
    escaped=$(printf '%s\n' "$pem" | awk '{ printf "%s\\n", $0 }')
    cat > "$SECRETS_DIR/sa.json" <<EOF
{
  "type": "service_account",
  "project_id": "fake-test-project",
  "private_key_id": "0000000000000000000000000000000000000000",
  "private_key": "$escaped",
  "client_email": "backup-sa@fake-test-project.iam.gserviceaccount.com",
  "client_id": "000000000000000000000",
  "token_uri": "https://oauth2.googleapis.com/token"
}
EOF
    # Valid JSON, but not a service account key: used by the validation cases.
    printf '{"foo": "bar"}\n' > "$SECRETS_DIR/notakey.json"
}

setup_stack() {
    printf -- '--- preparing stack ---\n'
    # Leftovers from an interrupted previous run.
    for c in $NAMED_CONTAINERS; do
        docker rm -f "$c" >/dev/null 2>&1
    done
    dc down --remove-orphans >/dev/null 2>&1

    rm -rf "$TEST_WORK_DIR"
    mkdir -p "$DATA_DIR" "$BUCKETS_DIR/testbucket" "$SECRETS_DIR"
    generate_fake_key
    reset_data

    printf 'building the image under test (the first build takes 1-2 minutes)\n'
    dc build || exit 1
    dc up -d fakegcs client || exit 1
    wait_for_fakegcs || { printf 'ERROR: fake-gcs-server did not become ready\n' >&2; exit 1; }
    printf 'stack ready (work dir: %s)\n\n' "$TEST_WORK_DIR"
}

wait_for_fakegcs() {
    for _ in $(seq 1 30); do
        if dc exec -T client gcloud storage ls gs://testbucket/ >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Reset /data to the pristine fixture tree.
reset_data() {
    rm -rf "$DATA_DIR"
    mkdir -p "$DATA_DIR"
    cp -R "$FIXTURES/." "$DATA_DIR/"
}

# Reset gs://testbucket to exactly the object names given as arguments.
# fake-gcs-server only reads its data directory at startup and keeps live state
# in memory, so the container is re-created to pick the new seed up.
reset_bucket() {
    local obj
    rm -rf "$BUCKETS_DIR"
    mkdir -p "$BUCKETS_DIR/testbucket"
    for obj in "$@"; do
        mkdir -p "$BUCKETS_DIR/testbucket/$(dirname "$obj")"
        printf 'seeded object %s\n' "$obj" > "$BUCKETS_DIR/testbucket/$obj"
    done
    dc up -d --force-recreate fakegcs >/dev/null 2>&1
    wait_for_fakegcs || note "WARNING: fake-gcs-server was not ready after reset"
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

# Object names currently in the bucket, relative to the bucket root, sorted.
# `ls` exits 1 on an empty bucket ("matched no objects"), which is not an error
# here, so the status is ignored and only gs:// lines are kept.
bucket_objects() {
    dc exec -T client gcloud storage ls -r 'gs://testbucket/**' 2>/dev/null \
        | grep '^gs://testbucket/' \
        | sed 's|^gs://testbucket/||' \
        | grep -v '/$' \
        | LC_ALL=C sort
}

expect_objects() {
    local expected actual
    if [ $# -eq 0 ]; then
        expected=""
    else
        expected=$(printf '%s\n' "$@" | LC_ALL=C sort)
    fi
    actual=$(bucket_objects)
    if [ "$expected" != "$actual" ]; then
        note "bucket contents mismatch"
        note "expected:"; note "${expected:-  (empty)}"
        note "actual:";   note "${actual:-  (empty)}"
        return 1
    fi
}

expect_contains() {
    local haystack=$1 needle=$2 label=${3:-output}
    case "$haystack" in
        *"$needle"*) return 0 ;;
    esac
    note "$label does not contain: $needle"
    note "--- $label ---"; note "$haystack"; note "--- end ---"
    return 1
}

expect_not_contains() {
    local haystack=$1 needle=$2 label=${3:-output}
    case "$haystack" in
        *"$needle"*)
            note "$label unexpectedly contains: $needle"
            note "--- $label ---"; note "$haystack"; note "--- end ---"
            return 1 ;;
    esac
    return 0
}

expect_status() {
    local actual=$1 expected=$2
    if [ "$actual" != "$expected" ]; then
        note "expected exit status $expected, got $actual"
        return 1
    fi
}

# Pull a "__MARKER__:value" line back out of captured container output.
marker() {
    printf '%s\n' "$2" | sed -n "s/^__$1__:\\(.*\\)\$/\\1/p" | tail -1
}

# ---------------------------------------------------------------------------
# Container helpers
# ---------------------------------------------------------------------------

# One-shot `sh /opt/run.sh backup` in a fresh container. Extra `docker compose
# run` options (-e ...) may be passed. Sets:
#   BACKUP_STATUS - exit status of run.sh
#   BACKUP_LOG    - contents of /var/log/cron.log after the run
backup_once() {
    local out
    out=$(dc run --rm --no-deps "$@" --entrypoint sh backup \
        -c 'sh /opt/run.sh backup; echo "__STATUS__:$?"; echo "__LOG__"; cat /var/log/cron.log' 2>&1)
    BACKUP_STATUS=$(marker STATUS "$out")
    BACKUP_LOG=$(printf '%s\n' "$out" | sed -n '/^__LOG__$/,$p' | tail -n +2)
    if [ -z "$BACKUP_STATUS" ]; then
        note "could not determine run.sh exit status; raw output:"
        note "$out"
        BACKUP_STATUS="?"
    fi
}

# One-shot `sh /opt/run.sh setup`. Only for the cases where setup exits by
# itself; otherwise it would block on crond. Sets SETUP_STATUS and SETUP_OUT.
setup_once() {
    SETUP_OUT=$(dc run --rm --no-deps "$@" backup setup 2>&1)
    SETUP_STATUS=$?
}

# Start the real entrypoint detached, under a fixed container name.
start_setup() {
    local name=$1; shift
    docker rm -f "$name" >/dev/null 2>&1
    dc run -d --no-deps --name "$name" "$@" backup setup >/dev/null 2>&1
}

# Wait until setup has written its crontab and handed over to crond. The marker
# is the startup log line, not the existence of /etc/crontabs/root: Alpine ships
# a default root crontab, which setup replaces.
wait_for_crontab() {
    local logs
    for _ in $(seq 1 40); do
        logs=$(docker logs "$1" 2>&1)
        case "$logs" in
            *"Starting CRON scheduler"*) return 0 ;;
            *"Exiting"*) note "container $1 exited during setup:"; note "$logs"; return 1 ;;
        esac
        sleep 1
    done
    note "container $1 never reached 'Starting CRON scheduler'"
    note "$(docker logs "$1" 2>&1 | tail -20)"
    return 1
}

# ---------------------------------------------------------------------------
# Cases: image contents
# ---------------------------------------------------------------------------

case_image_gsutil_absent() {
    local out
    out=$(dc run --rm --no-deps --entrypoint sh client -c '
        command -v gsutil && echo "FOUND_ON_PATH"
        [ -e /google-cloud-sdk/bin/gsutil ] && echo "FOUND_IN_BIN"
        [ -d /google-cloud-sdk/platform/gsutil ] && echo "FOUND_COMPONENT"
        echo CHECKED' 2>&1)
    expect_contains "$out" "CHECKED" "probe output" || return 1
    expect_not_contains "$out" "FOUND_ON_PATH" "probe output" || return 1
    expect_not_contains "$out" "FOUND_IN_BIN" "probe output" || return 1
    expect_not_contains "$out" "FOUND_COMPONENT" "probe output" || return 1
}

case_image_gcloud_on_path() {
    local out
    out=$(dc run --rm --no-deps --entrypoint sh client -c 'command -v gcloud; gcloud version 2>&1 | head -1' 2>&1)
    expect_contains "$out" "/google-cloud-sdk/bin/gcloud" "probe output" || return 1
    expect_contains "$out" "Google Cloud SDK" "probe output" || return 1
}

case_image_python3_present() {
    local out
    # The CLI runs on Alpine's interpreter (CLOUDSDK_PYTHON), and the bundled one
    # is deliberately left out of the image.
    out=$(dc run --rm --no-deps --entrypoint sh client -c '
        command -v python3
        python3 -c "print(\"python-ok\")"
        [ -d /google-cloud-sdk/platform/bundledpythonunix ] && echo "BUNDLED_PYTHON_PRESENT"
        echo CHECKED' 2>&1)
    expect_contains "$out" "/usr/bin/python3" "probe output" || return 1
    expect_contains "$out" "python-ok" "probe output" || return 1
    expect_not_contains "$out" "BUNDLED_PYTHON_PRESENT" "probe output" || return 1
}

case_image_declares_healthcheck() {
    local out
    out=$(docker image inspect "$IMAGE_UNDER_TEST" --format '{{json .Config.Healthcheck}}' 2>&1)
    expect_contains "$out" "/opt/run.sh" "image healthcheck" || return 1
    expect_contains "$out" "healthcheck" "image healthcheck" || return 1
}

# ---------------------------------------------------------------------------
# Cases: configuration validation
# ---------------------------------------------------------------------------

case_config_missing_service_account_file() {
    setup_once -e SERVICE_ACCOUNT_FILE=
    expect_status "$SETUP_STATUS" 1 || { note "$SETUP_OUT"; return 1; }
    expect_contains "$SETUP_OUT" "SERVICE_ACCOUNT_FILE must be set" "setup output" || return 1
}

case_config_key_file_not_found() {
    setup_once -e SERVICE_ACCOUNT_FILE=/secrets/does-not-exist.json
    expect_status "$SETUP_STATUS" 1 || { note "$SETUP_OUT"; return 1; }
    expect_contains "$SETUP_OUT" "not found. Mount the service account key file" "setup output" || return 1
}

case_config_key_file_not_a_key() {
    setup_once -e SERVICE_ACCOUNT_FILE=/secrets/notakey.json
    expect_status "$SETUP_STATUS" 1 || { note "$SETUP_OUT"; return 1; }
    expect_contains "$SETUP_OUT" "is not a service account JSON key file" "setup output" || return 1
}

case_config_missing_gcspath() {
    setup_once -e GCSPATH=
    if [ "$SETUP_STATUS" = "0" ]; then
        note "expected a non-zero exit status, got 0"
        note "$SETUP_OUT"
        return 1
    fi
    expect_contains "$SETUP_OUT" "GCSPATH required" "setup output" || return 1
}

case_config_legacy_keys_without_service_account() {
    setup_once -e SERVICE_ACCOUNT_FILE= -e ACCESS_KEY=legacy-access -e SECRET_KEY=legacy-secret
    expect_status "$SETUP_STATUS" 1 || { note "$SETUP_OUT"; return 1; }
    expect_contains "$SETUP_OUT" "no longer supported as of version 2.0" "setup output" || return 1
    expect_contains "$SETUP_OUT" "SERVICE_ACCOUNT_FILE=/path/to/key.json" "setup output" || return 1
}

case_config_legacy_keys_with_service_account_warns() {
    local logs
    start_setup "${CN_PREFIX}legacy-keys" -e CRON_SCHEDULE=@daily -e ACCESS_KEY=legacy-access -e BOTO_FILE=/tmp/boto
    wait_for_crontab "${CN_PREFIX}legacy-keys" || return 1
    logs=$(docker logs "${CN_PREFIX}legacy-keys" 2>&1)
    expect_contains "$logs" "WARNING: ACCESS_KEY, SECRET_KEY and BOTO_FILE are ignored" "startup log" || return 1
    if [ "$(docker inspect -f '{{.State.Running}}' "${CN_PREFIX}legacy-keys" 2>/dev/null)" != "true" ]; then
        note "container exited instead of starting the scheduler"
        note "$logs"
        return 1
    fi
    docker rm -f "${CN_PREFIX}legacy-keys" >/dev/null 2>&1
}

case_config_cron_schedule_field_count() {
    setup_once -e CRON_SCHEDULE='0 *'
    expect_status "$SETUP_STATUS" 1 || { note "$SETUP_OUT"; return 1; }
    expect_contains "$SETUP_OUT" "CRON_SCHEDULE must have 5 fields" "setup output" || return 1
    # The reported count must be the number of fields in CRON_SCHEDULE, not the
    # number of files the shell expanded the '*' into.
    expect_contains "$SETUP_OUT" "Got 2 field(s): '0 *'" "setup output" || return 1
}

case_config_cron_schedule_macro_accepted() {
    local logs
    start_setup "${CN_PREFIX}macro" -e CRON_SCHEDULE=@daily
    wait_for_crontab "${CN_PREFIX}macro" || return 1
    logs=$(docker logs "${CN_PREFIX}macro" 2>&1)
    expect_contains "$logs" "Adding CRON schedule: @daily" "startup log" || return 1
    expect_contains "$(docker exec "${CN_PREFIX}macro" cat /etc/crontabs/root 2>&1)" \
        "@daily sh /opt/run.sh backup" "crontab" || return 1
    docker rm -f "${CN_PREFIX}macro" >/dev/null 2>&1
}

case_config_default_schedule_starts_scheduler() {
    # No CRON_SCHEDULE at all: the documented default, i.e. what a plain
    # `docker run` of the image uses.
    local logs
    start_setup "${CN_PREFIX}default-schedule"
    wait_for_crontab "${CN_PREFIX}default-schedule" || return 1
    logs=$(docker logs "${CN_PREFIX}default-schedule" 2>&1)
    expect_contains "$logs" "Adding CRON schedule: 0 * * * * (UTC)" "startup log" || return 1
    expect_contains "$(docker exec "${CN_PREFIX}default-schedule" cat /etc/crontabs/root 2>&1)" \
        "0 * * * * sh /opt/run.sh backup" "crontab" || return 1
    docker rm -f "${CN_PREFIX}default-schedule" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Cases: transfer behaviour
# ---------------------------------------------------------------------------

case_transfer_initial_upload() {
    reset_data
    reset_bucket
    backup_once
    expect_status "$BACKUP_STATUS" 0 || { note "$BACKUP_LOG"; return 1; }
    expect_contains "$BACKUP_LOG" "Copying file:///data/notes/deep/nested.txt" "cron.log" || return 1
    expect_not_contains "$BACKUP_LOG" "Sync FAILED" "cron.log" || return 1
    expect_objects $FIXTURE_OBJECTS || return 1
}

case_transfer_rerun_is_noop() {
    reset_data
    reset_bucket
    backup_once
    expect_status "$BACKUP_STATUS" 0 || { note "first run: $BACKUP_LOG"; return 1; }
    backup_once
    expect_status "$BACKUP_STATUS" 0 || { note "second run: $BACKUP_LOG"; return 1; }
    # Nothing may be re-copied and nothing deleted on an unchanged tree.
    expect_not_contains "$BACKUP_LOG" "Copying file://" "second run cron.log" || return 1
    expect_not_contains "$BACKUP_LOG" "Removing gs://" "second run cron.log" || return 1
    expect_objects $FIXTURE_OBJECTS || return 1
}

case_transfer_picks_up_new_file() {
    reset_data
    reset_bucket
    backup_once
    expect_status "$BACKUP_STATUS" 0 || { note "$BACKUP_LOG"; return 1; }
    printf 'added between two runs\n' > "$DATA_DIR/notes/new-file.txt"
    backup_once
    expect_status "$BACKUP_STATUS" 0 || { note "$BACKUP_LOG"; return 1; }
    expect_contains "$BACKUP_LOG" "Copying file:///data/notes/new-file.txt" "cron.log" || return 1
    expect_objects $FIXTURE_OBJECTS notes/new-file.txt || return 1
}

case_transfer_delete_flag() {
    reset_data
    reset_bucket stale/orphan.txt
    backup_once -e GCSOPTIONS=-d
    expect_contains "$BACKUP_LOG" "--delete-unmatched-destination-objects" "cron.log" || return 1
    expect_contains "$BACKUP_LOG" "Removing gs://testbucket/stale/orphan.txt" "cron.log" || return 1
    # KNOWN QUIRK: fake-gcs-server's delete response makes gcloud raise
    # "'NoneType' object has no attribute 'items'", so rsync exits 1 and run.sh
    # reports a failure even though the object is really gone (real GCS answers
    # 204 and rsync exits 0). What matters here is the resulting bucket contents,
    # so the failure is tolerated - but only if it is that known error.
    case "$BACKUP_LOG" in
        *"Sync FAILED with exit status"*)
            expect_contains "$BACKUP_LOG" "'NoneType' object has no attribute 'items'" \
                "cron.log (expected the known fake-gcs-server delete quirk)" || return 1 ;;
    esac
    expect_objects $FIXTURE_OBJECTS || return 1
}

case_transfer_dry_run() {
    reset_data
    reset_bucket keep-me.txt
    backup_once -e GCSOPTIONS=-n
    expect_status "$BACKUP_STATUS" 0 || { note "$BACKUP_LOG"; return 1; }
    expect_contains "$BACKUP_LOG" "--recursive --no-ignore-symlinks --dry-run /data" "cron.log" || return 1
    expect_objects keep-me.txt || return 1
}

case_transfer_exclude() {
    reset_data
    reset_bucket
    backup_once -e GCSOPTIONS='-x skipme'
    expect_status "$BACKUP_STATUS" 0 || { note "$BACKUP_LOG"; return 1; }
    expect_contains "$BACKUP_LOG" "--exclude skipme" "cron.log" || return 1
    expect_objects hello.txt logs/app.log notes/deep/nested.txt notes/readme.md || return 1
}

case_transfer_exclude_quoted_pattern() {
    reset_data
    reset_bucket
    # GCSOPTIONS is split the way a shell would, so a pattern containing a space
    # can be quoted inside it.
    mkdir -p "$DATA_DIR/my notes"
    printf 'excluded by a quoted pattern\n' > "$DATA_DIR/my notes/secret.txt"
    backup_once -e GCSOPTIONS="-x 'my notes'"
    expect_status "$BACKUP_STATUS" 0 || { note "$BACKUP_LOG"; return 1; }
    expect_objects $FIXTURE_OBJECTS || return 1
}

case_transfer_legacy_combo_behaves_like_delete() {
    reset_data
    reset_bucket stale/orphan.txt
    backup_once -e GCSOPTIONS='-d -m -r'
    # -m and -r have no gcloud equivalent and are dropped, so the command must be
    # exactly the one -d alone produces.
    expect_contains "$BACKUP_LOG" \
        "Executing gcloud storage rsync --recursive --no-ignore-symlinks --delete-unmatched-destination-objects /data gs://testbucket/" \
        "cron.log" || return 1
    expect_contains "$BACKUP_LOG" "Removing gs://testbucket/stale/orphan.txt" "cron.log" || return 1
    expect_objects $FIXTURE_OBJECTS || return 1
}

case_transfer_raw_gcloud_flag_passthrough() {
    reset_data
    reset_bucket
    backup_once -e GCSOPTIONS='--exclude=logs'
    expect_status "$BACKUP_STATUS" 0 || { note "$BACKUP_LOG"; return 1; }
    expect_contains "$BACKUP_LOG" "--no-ignore-symlinks --exclude=logs /data" "cron.log" || return 1
    expect_objects hello.txt notes/deep/nested.txt notes/readme.md skipme/ignored.txt || return 1
}

case_options_translation_table() {
    reset_data
    reset_bucket
    # Every translated flag at once, plus a raw gcloud flag. --dry-run keeps the
    # bucket untouched, so this case only inspects the generated command line.
    # -e settles the symlink question, so --no-ignore-symlinks is not added too.
    backup_once -e GCSOPTIONS='-d -n -C -e -m -r -R -x skipme --verbosity=warning'
    expect_status "$BACKUP_STATUS" 0 || { note "$BACKUP_LOG"; return 1; }
    expect_contains "$BACKUP_LOG" \
        "Executing gcloud storage rsync --recursive --delete-unmatched-destination-objects --dry-run --continue-on-error --ignore-symlinks --exclude skipme --verbosity=warning /data gs://testbucket/" \
        "cron.log" || return 1
    expect_objects || return 1
}

case_options_unbalanced_quote_rejected() {
    reset_data
    reset_bucket keep-me.txt
    backup_once -e GCSOPTIONS="-x 'unclosed"
    # The run must refuse to go ahead with an argument list it could not parse -
    # exit 2, no rsync, nothing touched in the bucket - and say why. A syntax
    # error inside `eval` kills busybox ash outright, so the message only appears
    # if the parse is rehearsed somewhere it cannot take the script down with it.
    expect_status "$BACKUP_STATUS" 2 || { note "$BACKUP_LOG"; return 1; }
    expect_contains "$BACKUP_LOG" "GCSOPTIONS could not be parsed" "cron.log" || return 1
    expect_not_contains "$BACKUP_LOG" "Executing gcloud storage rsync" "cron.log" || return 1
    expect_objects keep-me.txt || return 1
}

# ---------------------------------------------------------------------------
# Cases: runtime behaviour
# ---------------------------------------------------------------------------

case_runtime_sync_failure_is_logged_and_propagated() {
    reset_data
    backup_once -e GCSPATH=gs://no-such-bucket-here/
    expect_contains "$BACKUP_LOG" "Sync FAILED with exit status" "cron.log" || return 1
    expect_contains "$BACKUP_LOG" "not found: 404" "cron.log" || return 1
    # The status is propagated, so cron, `docker exec` and the healthcheck can all
    # tell a failed backup from a good one.
    expect_status "$BACKUP_STATUS" 1 || { note "$BACKUP_LOG"; return 1; }
}

case_runtime_lock_file_blocks_concurrent_run() {
    local out status log
    reset_data
    reset_bucket keep-me.txt
    # A lock file whose pid is alive means a backup really is running.
    out=$(dc run --rm --no-deps --entrypoint sh backup -c '
        sleep 300 &
        echo $! > /tmp/gcloudlock.lock
        sh /opt/run.sh backup; echo "__STATUS__:$?"; echo "__LOG__"; cat /var/log/cron.log' 2>&1)
    status=$(marker STATUS "$out")
    log=$(printf '%s\n' "$out" | sed -n '/^__LOG__$/,$p' | tail -n +2)
    expect_status "$status" 1 || { note "$out"; return 1; }
    expect_contains "$log" "detected, exiting! Already running?" "cron.log" || return 1
    expect_not_contains "$log" "Executing gcloud storage rsync" "cron.log" || return 1
    expect_objects keep-me.txt || return 1
}

case_runtime_stale_lock_is_taken_over() {
    local out status log
    reset_data
    reset_bucket
    # A lock left behind by a killed run holds a pid that no longer exists; it
    # must not block every backup from then on.
    out=$(dc run --rm --no-deps --entrypoint sh backup -c '
        echo 999999 > /tmp/gcloudlock.lock
        sh /opt/run.sh backup; echo "__STATUS__:$?"; echo "__LOG__"; cat /var/log/cron.log' 2>&1)
    status=$(marker STATUS "$out")
    log=$(printf '%s\n' "$out" | sed -n '/^__LOG__$/,$p' | tail -n +2)
    expect_status "$status" 0 || { note "$out"; return 1; }
    expect_contains "$log" "is stale (pid 999999 is gone), taking it over" "cron.log" || return 1
    expect_objects $FIXTURE_OBJECTS || return 1
}

case_runtime_credential_file_override_is_used() {
    # Auth left enabled, so gcloud really loads the mounted key file: it signs a
    # JWT for the account in that file and the token request is refused, which
    # proves CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE reached the CLI. (Needs
    # outbound access to oauth2.googleapis.com; offline, the error differs but
    # still names the account.)
    reset_data
    backup_once -e CLOUDSDK_AUTH_DISABLE_CREDENTIALS=
    expect_contains "$BACKUP_LOG" "backup-sa@fake-test-project.iam.gserviceaccount.com" "cron.log" || return 1
    expect_contains "$BACKUP_LOG" "Sync FAILED with exit status" "cron.log" || return 1
}

case_runtime_log_is_trimmed() {
    local out status size log
    reset_data
    reset_bucket
    out=$(dc run --rm --no-deps -e LOG_MAX_BYTES=4096 --entrypoint sh backup -c '
        yes "padding padding padding padding" | head -c 40000 > /var/log/cron.log
        sh /opt/run.sh backup; echo "__STATUS__:$?"
        echo "__SIZE__:$(wc -c < /var/log/cron.log)"
        echo "__LOG__"; cat /var/log/cron.log' 2>&1)
    status=$(marker STATUS "$out")
    size=$(marker SIZE "$out" | tr -d ' ')
    log=$(printf '%s\n' "$out" | sed -n '/^__LOG__$/,$p' | tail -n +2)
    expect_status "$status" 0 || { note "$out"; return 1; }
    expect_contains "$log" "was trimmed to its most recent" "cron.log" || return 1
    if [ -z "$size" ] || [ "$size" -ge 40000 ]; then
        note "log was not trimmed: it is ${size:-unknown} bytes"
        return 1
    fi
    expect_objects $FIXTURE_OBJECTS || return 1
}

case_runtime_healthcheck_reports_success() {
    local out
    reset_data
    reset_bucket
    out=$(dc run --rm --no-deps --entrypoint sh backup -c '
        sh /opt/run.sh healthcheck; echo "__FRESH__:$?"
        sh /opt/run.sh backup >/dev/null 2>&1; echo "__BACKUP__:$?"
        sh /opt/run.sh healthcheck; echo "__AFTER__:$?"
        echo "__LOG__"; cat /var/log/cron.log' 2>&1)
    expect_contains "$out" "no backup has completed yet" "healthcheck output" || return 1
    expect_status "$(marker FRESH "$out")" 0 || { note "$out"; return 1; }
    expect_status "$(marker BACKUP "$out")" 0 || { note "$out"; return 1; }
    expect_contains "$out" "last backup succeeded" "healthcheck output" || return 1
    expect_status "$(marker AFTER "$out")" 0 || { note "$out"; return 1; }
    expect_objects $FIXTURE_OBJECTS || return 1
}

case_runtime_healthcheck_reports_failure() {
    local out
    reset_data
    out=$(dc run --rm --no-deps -e GCSPATH=gs://no-such-bucket-here/ --entrypoint sh backup -c '
        sh /opt/run.sh backup >/dev/null 2>&1; echo "__BACKUP__:$?"
        sh /opt/run.sh healthcheck; echo "__AFTER__:$?"' 2>&1)
    expect_status "$(marker BACKUP "$out")" 1 || { note "$out"; return 1; }
    expect_contains "$out" "last backup FAILED with exit status 1" "healthcheck output" || return 1
    expect_status "$(marker AFTER "$out")" 1 || { note "$out"; return 1; }
}

case_setup_crontab_line() {
    local cronline
    reset_data
    start_setup "${CN_PREFIX}crontab" -e CRON_SCHEDULE='*/17 * * * *'
    wait_for_crontab "${CN_PREFIX}crontab" || return 1
    cronline=$(docker exec "${CN_PREFIX}crontab" cat /etc/crontabs/root 2>&1)
    expect_contains "$cronline" '*/17 * * * * sh /opt/run.sh backup' "crontab" || return 1
    docker rm -f "${CN_PREFIX}crontab" >/dev/null 2>&1
}

case_setup_env_file_carries_settings() {
    local envfile
    reset_data
    start_setup "${CN_PREFIX}envfile" -e CRON_SCHEDULE=@daily -e GCSOPTIONS=-d -e PROJECT_ID=my-project -e TZ=America/Montreal
    wait_for_crontab "${CN_PREFIX}envfile" || return 1
    # crond passes its jobs a minimal environment, so everything the scheduled
    # backup needs has to be in the env file setup wrote.
    envfile=$(docker exec "${CN_PREFIX}envfile" cat /tmp/gcsbackup.env 2>&1)
    expect_contains "$envfile" "GCSPATH" "env file" || return 1
    expect_contains "$envfile" "gs://testbucket/" "env file" || return 1
    expect_contains "$envfile" "GCSOPTIONS" "env file" || return 1
    expect_contains "$envfile" "TZ" "env file" || return 1
    expect_contains "$envfile" "America/Montreal" "env file" || return 1
    expect_contains "$envfile" "SERVICE_ACCOUNT_FILE" "env file" || return 1
    expect_contains "$envfile" "/secrets/sa.json" "env file" || return 1
    expect_contains "$envfile" "PROJECT_ID" "env file" || return 1
    expect_contains "$envfile" "my-project" "env file" || return 1
    # Every CLI setting given to the container is carried over too, including the
    # ones run.sh exports itself.
    expect_contains "$envfile" "CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE" "env file" || return 1
    expect_contains "$envfile" "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE" "env file" || return 1
    expect_contains "$envfile" "CLOUDSDK_CORE_PROJECT" "env file" || return 1
    expect_contains "$envfile" "CLOUDSDK_PYTHON" "env file" || return 1
    expect_contains "$envfile" "CLOUDSDK_CONFIG" "env file" || return 1
    docker rm -f "${CN_PREFIX}envfile" >/dev/null 2>&1
}

case_setup_hand_run_backup() {
    local status log
    reset_data
    reset_bucket
    start_setup "${CN_PREFIX}handrun" -e CRON_SCHEDULE=@daily
    wait_for_crontab "${CN_PREFIX}handrun" || return 1
    # The documented way to check a configuration without waiting for the
    # schedule: `docker exec <container> sh /opt/run.sh backup`.
    docker exec "${CN_PREFIX}handrun" sh /opt/run.sh backup >/dev/null 2>&1
    status=$?
    log=$(docker exec "${CN_PREFIX}handrun" cat /var/log/cron.log 2>&1)
    expect_status "$status" 0 || { note "$log"; return 1; }
    expect_contains "$log" "Executing gcloud storage rsync" "cron.log" || return 1
    expect_not_contains "$log" "Sync FAILED" "cron.log" || return 1
    expect_objects $FIXTURE_OBJECTS || return 1
    docker rm -f "${CN_PREFIX}handrun" >/dev/null 2>&1
}

case_setup_backup_in_crond_environment() {
    local status log
    reset_data
    reset_bucket
    start_setup "${CN_PREFIX}cronenv" -e CRON_SCHEDULE=@daily
    wait_for_crontab "${CN_PREFIX}cronenv" || return 1
    # Exactly what crond gives the job it spawns: none of the container's own
    # variables, so the run has to rebuild its configuration from the env file.
    # This is the scheduled code path, without waiting a minute for it.
    docker exec "${CN_PREFIX}cronenv" $CROND_ENV sh /opt/run.sh backup >/dev/null 2>&1
    status=$?
    log=$(docker exec "${CN_PREFIX}cronenv" cat /var/log/cron.log 2>&1)
    expect_status "$status" 0 || { note "$log"; return 1; }
    expect_contains "$log" \
        "Executing gcloud storage rsync --recursive --no-ignore-symlinks /data gs://testbucket/" "cron.log" || return 1
    expect_not_contains "$log" "Sync FAILED" "cron.log" || return 1
    expect_not_contains "$log" "Unknown timezone" "cron.log" || return 1
    expect_objects $FIXTURE_OBJECTS || return 1
    docker rm -f "${CN_PREFIX}cronenv" >/dev/null 2>&1
}

case_setup_run_on_startup() {
    local logs
    reset_data
    reset_bucket
    start_setup "${CN_PREFIX}startup" -e CRON_SCHEDULE=@daily -e RUN_ON_STARTUP=true
    wait_for_crontab "${CN_PREFIX}startup" || return 1
    sleep 8
    logs=$(docker logs "${CN_PREFIX}startup" 2>&1)
    expect_contains "$logs" "RUN_ON_STARTUP is set" "startup log" || return 1
    expect_contains "$logs" "Initial backup finished with exit status 0" "startup log" || return 1
    expect_objects $FIXTURE_OBJECTS || return 1
    docker rm -f "${CN_PREFIX}startup" >/dev/null 2>&1
}

case_schedule_fires_within_90s() {
    local log
    reset_data
    reset_bucket
    start_setup "${CN_PREFIX}cron" -e CRON_SCHEDULE='* * * * *'
    wait_for_crontab "${CN_PREFIX}cron" || return 1
    for _ in $(seq 1 100); do
        if docker exec "${CN_PREFIX}cron" grep -q "Finished sync" /var/log/cron.log 2>/dev/null; then
            break
        fi
        sleep 1
    done
    log=$(docker exec "${CN_PREFIX}cron" cat /var/log/cron.log 2>&1)
    expect_contains "$log" "Starting sync" "cron.log" || return 1
    expect_contains "$log" "Executing gcloud storage rsync" "cron.log" || return 1
    expect_not_contains "$log" "Sync FAILED" "cron.log" || return 1
    # The scheduled run really transferred the data, not just logged.
    expect_objects $FIXTURE_OBJECTS || return 1
    # setup tails the log as PID 1, so it also shows up in `docker logs`.
    expect_contains "$(docker logs "${CN_PREFIX}cron" 2>&1)" "Starting sync" "docker logs" || return 1
    docker rm -f "${CN_PREFIX}cron" >/dev/null 2>&1
}

case_schedule_honours_timezone() {
    local sched minute hour log utc_hour
    reset_data
    reset_bucket
    # Schedule a daily job two minutes from now in Tokyo time. Tokyo is UTC+9, so
    # the hour field never equals the current UTC hour: a cron evaluating the
    # schedule in UTC could not fire it within the wait below.
    sched=$(dc run --rm --no-deps --entrypoint python3 client -c \
        "import datetime,zoneinfo; t=datetime.datetime.now(zoneinfo.ZoneInfo('Asia/Tokyo'))+datetime.timedelta(minutes=2); print(t.minute, t.hour)" 2>/dev/null | tr -d '\r')
    minute=${sched% *}
    hour=${sched#* }
    if [ -z "$minute" ] || [ -z "$hour" ]; then
        note "could not compute the Tokyo schedule (got '$sched')"
        return 1
    fi
    utc_hour=$(date -u +%H)
    note "scheduling '$minute $hour * * *' in Asia/Tokyo (current UTC hour: $utc_hour)"
    start_setup "${CN_PREFIX}tz" -e TZ=Asia/Tokyo -e CRON_SCHEDULE="$minute $hour * * *"
    wait_for_crontab "${CN_PREFIX}tz" || return 1
    expect_contains "$(docker logs "${CN_PREFIX}tz" 2>&1)" "Adding CRON schedule: $minute $hour * * * (Asia/Tokyo)" "startup log" || return 1
    # Timestamps come from the container clock, which setup_timezone moved to JST.
    expect_contains "$(docker logs "${CN_PREFIX}tz" 2>&1)" "JST" "startup log" || return 1
    for _ in $(seq 1 170); do
        if docker exec "${CN_PREFIX}tz" grep -q "Finished sync" /var/log/cron.log 2>/dev/null; then
            break
        fi
        sleep 1
    done
    log=$(docker exec "${CN_PREFIX}tz" cat /var/log/cron.log 2>&1)
    expect_contains "$log" "Starting sync" "cron.log" || return 1
    expect_contains "$log" "JST" "cron.log" || return 1
    expect_not_contains "$log" "Sync FAILED" "cron.log" || return 1
    expect_objects $FIXTURE_OBJECTS || return 1
    docker rm -f "${CN_PREFIX}tz" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

# run_case <name> <function>
run_case() {
    local name=$1 fn=$2 out rc arg matched

    if [ "$FILTER_COUNT" -gt 0 ]; then
        matched=0
        for arg in "${FILTERS[@]}"; do
            case "$name" in *"$arg"*) matched=1 ;; esac
        done
        if [ "$matched" = "0" ]; then
            SKIPPED=$((SKIPPED + 1))
            return 0
        fi
    fi

    TOTAL=$((TOTAL + 1))
    out=$("$fn" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        PASSED=$((PASSED + 1))
        printf 'PASS  %s\n' "$name"
    else
        FAILED=$((FAILED + 1))
        FAILED_NAMES="${FAILED_NAMES}${name}
"
        printf 'FAIL  %s\n' "$name"
        printf '%s\n' "$out" | sed 's/^/        /'
    fi
}

# Case-name substrings given on the command line; none means "run everything".
FILTER_COUNT=$#
FILTERS=("$@")

trap cleanup EXIT INT TERM

setup_stack

printf -- '--- image ---\n'
run_case "image: gsutil is absent"                            case_image_gsutil_absent
run_case "image: gcloud is on PATH"                           case_image_gcloud_on_path
run_case "image: python3 present, bundled one dropped"        case_image_python3_present
run_case "image: declares a HEALTHCHECK"                      case_image_declares_healthcheck

printf -- '\n--- configuration validation ---\n'
run_case "config: missing SERVICE_ACCOUNT_FILE exits 1"       case_config_missing_service_account_file
run_case "config: key file path not found exits 1"            case_config_key_file_not_found
run_case "config: file is not a service account key exits 1"  case_config_key_file_not_a_key
run_case "config: missing GCSPATH exits non-zero"             case_config_missing_gcspath
run_case "config: ACCESS_KEY without key file exits 1"        case_config_legacy_keys_without_service_account
run_case "config: ACCESS_KEY with key file warns and starts"  case_config_legacy_keys_with_service_account_warns
run_case "config: CRON_SCHEDULE field count is validated"     case_config_cron_schedule_field_count
run_case "config: CRON_SCHEDULE @macro is accepted"           case_config_cron_schedule_macro_accepted
run_case "config: default CRON_SCHEDULE starts scheduler"     case_config_default_schedule_starts_scheduler

printf -- '\n--- transfer behaviour ---\n'
run_case "transfer: initial upload of nested directories"     case_transfer_initial_upload
run_case "transfer: re-run copies nothing"                    case_transfer_rerun_is_noop
run_case "transfer: new local file is picked up"              case_transfer_picks_up_new_file
run_case "transfer: GCSOPTIONS=-d deletes orphan object"      case_transfer_delete_flag
run_case "transfer: GCSOPTIONS=-n changes nothing"            case_transfer_dry_run
run_case "transfer: GCSOPTIONS=-x excludes matching paths"    case_transfer_exclude
run_case "transfer: -x accepts a quoted pattern"              case_transfer_exclude_quoted_pattern
run_case "transfer: legacy '-d -m -r' behaves like -d"        case_transfer_legacy_combo_behaves_like_delete
run_case "transfer: raw gcloud flag is passed through"        case_transfer_raw_gcloud_flag_passthrough
run_case "options: full translation table"                    case_options_translation_table
run_case "options: unbalanced quote is rejected"              case_options_unbalanced_quote_rejected

printf -- '\n--- runtime ---\n'
run_case "runtime: failing sync logged and propagated"        case_runtime_sync_failure_is_logged_and_propagated
run_case "runtime: live lock prevents concurrent run"         case_runtime_lock_file_blocks_concurrent_run
run_case "runtime: stale lock is taken over"                  case_runtime_stale_lock_is_taken_over
run_case "runtime: key file is used to mint a token"          case_runtime_credential_file_override_is_used
run_case "runtime: log is trimmed past LOG_MAX_BYTES"         case_runtime_log_is_trimmed
run_case "runtime: healthcheck reports a good backup"         case_runtime_healthcheck_reports_success
run_case "runtime: healthcheck reports a failed backup"       case_runtime_healthcheck_reports_failure
run_case "setup: crontab holds schedule and command"          case_setup_crontab_line
run_case "setup: env file carries the settings"               case_setup_env_file_carries_settings
run_case "setup: hand-run 'run.sh backup' works"             case_setup_hand_run_backup
run_case "setup: backup works in crond's environment"         case_setup_backup_in_crond_environment
run_case "setup: RUN_ON_STARTUP backs up immediately"         case_setup_run_on_startup

if [ "${SKIP_SLOW:-0}" = "1" ]; then
    printf -- '\n--- scheduling (skipped: SKIP_SLOW=1) ---\n'
else
    printf -- '\n--- scheduling (slow, waits for cron) ---\n'
    run_case "schedule: '* * * * *' fires a backup"            case_schedule_fires_within_90s
    run_case "schedule: TZ applies to cron and timestamps"     case_schedule_honours_timezone
fi

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
