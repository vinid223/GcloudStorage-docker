#!/bin/sh
#
# Entrypoint for the gcloud-storage-docker image.
#
# Commands (the first argument, "setup" by default):
#   setup       - validate the configuration, install the cron schedule and hand
#                 over to crond. This is what the container runs.
#   backup      - run one sync now. What cron invokes, and what to run by hand:
#                 `docker exec <container> sh /opt/run.sh backup`
#   healthcheck - report whether the last completed backup succeeded. Used by the
#                 image HEALTHCHECK; exits 1 once a backup has failed.
#   help        - print the settings reference and exit.
#
# Plain POSIX shell on purpose: the image has no bash, only busybox ash.

# Parameters
OPTION="${1:-setup}"

# Internal paths
LOG="/var/log/cron.log"
LOCKFILE="/tmp/gcloudlock.lock"
STATUSFILE="/tmp/gcsbackup.status"
ENVFILE="/tmp/gcsbackup.env"
CRONFILE="/etc/crontabs/root"
GCLOUD="/google-cloud-sdk/bin/gcloud"

# crond hands the jobs it spawns a minimal environment, so setup writes every
# setting it resolved to $ENVFILE and the scheduled run reads it back. That keeps
# a cron backup and a hand-run backup identical without stuffing the whole
# environment into the crontab line, where quoting is a hazard.
#
# The file assigns with ${VAR:=...}, so anything already in the environment wins:
# `docker exec` inherits the container's own variables (which therefore keep
# priority), and `docker exec -e GCSOPTIONS=-n ... run.sh backup` still overrides
# a single setting for a one-off run.
if [ "$OPTION" != "setup" ] && [ -f "$ENVFILE" ]; then
    # shellcheck source=/dev/null
    . "$ENVFILE"
fi

SERVICE_ACCOUNT_FILE=${SERVICE_ACCOUNT_FILE:-}
PROJECT_ID=${PROJECT_ID:-}
GCSPATH=${GCSPATH:-}
GCSOPTIONS=${GCSOPTIONS:-}
CRON_SCHEDULE=${CRON_SCHEDULE:-0 * * * *}
TZ=${TZ:-UTC}
# Run one backup immediately when the container starts instead of waiting for the
# first scheduled run. Off by default, so startup behaviour is unchanged.
RUN_ON_STARTUP=${RUN_ON_STARTUP:-false}
# Trim $LOG once it grows past this many bytes, keeping the most recent half.
# Set to 0 to never trim.
LOG_MAX_BYTES=${LOG_MAX_BYTES:-10485760}

# Removed in 2.0, kept here only to give their users a clear error instead of a
# silently broken backup.
ACCESS_KEY=${ACCESS_KEY:-}
SECRET_KEY=${SECRET_KEY:-}
BOTO_FILE=${BOTO_FILE:-}

# Create logfile if does not exists
if [ ! -e "$LOG" ]; then
    touch "$LOG"
fi

# Functions definition
log_info()
{
    echo "$1" >> "$LOG"
}

# Quote a value so a shell reads it back verbatim: wrap it in single quotes and
# close/escape/reopen around any single quote it contains.
shquote()
{
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# For the help menu: show a value, or say so when there is none.
or_unset()
{
    if [ -n "$1" ]; then
      printf '%s' "$1"
    else
      printf '(not set)'
    fi
}

# Every setting, its accepted values, and what this container resolved it to.
# Printed at each start before anything can fail, so the log of a container that
# refused to start still says what it was looking for. Not printed by `backup`,
# which would repeat it into the log on every scheduled run.
print_help()
{
    cat <<HELP
======================================================================
 gcloud-storage-docker - backs up /data to Google Cloud Storage
======================================================================
 Mount the directories to back up under /data. Authentication is a
 service account JSON key file, mounted anywhere and pointed at by
 SERVICE_ACCOUNT_FILE.

 SETTINGS                            "now:" is the value in use here

 SERVICE_ACCOUNT_FILE  REQUIRED
   Path inside the container to a mounted service account JSON key.
   now: $(or_unset "$SERVICE_ACCOUNT_FILE")

 GCSPATH               REQUIRED
   Destination bucket, with an optional path inside it.
   ex: gs://my-backup-bucket/  or  gs://my-backup-bucket/hostname/
   now: $(or_unset "$GCSPATH")

 CRON_SCHEDULE         default: 0 * * * *   (hourly, at minute 0)
   Five cron fields, or an @macro: @hourly @daily @weekly @monthly
   @yearly. Evaluated in TZ.  ex: 0 3 * * *  is 03:00 every day.
   now: $CRON_SCHEDULE

 TZ                    default: UTC
   Any zoneinfo name, and it applies to both the schedule and the log
   timestamps.  ex: America/Montreal.  Unknown names fall back to UTC.
   now: $TZ

 GCSOPTIONS            default: (none)
   Extra flags for the transfer. Values are listed below.
   now: $(or_unset "$GCSOPTIONS")

 PROJECT_ID            default: (none)
   GCP project, needed only if your bucket requires one to be set.
   now: $(or_unset "$PROJECT_ID")

 RUN_ON_STARTUP        default: false
   true, 1, yes or on - run one backup as soon as the container starts
   instead of waiting for the first scheduled run.
   now: $RUN_ON_STARTUP

 LOG_MAX_BYTES         default: 10485760   (10 MB)
   Trim the log to its most recent half once it grows past this many
   bytes.  0 keeps it forever.
   now: $LOG_MAX_BYTES

 GCSOPTIONS VALUES              the 1.x gsutil short forms still work

   -d    --delete-unmatched-destination-objects
                          also delete bucket objects that no longer
                          exist under /data
   -n    --dry-run        report what would happen, transfer nothing
   -C    --continue-on-error
                          carry on after an individual file fails
   -x P  --exclude P      skip paths matching the regular expression P
   -e    --ignore-symlinks
                          do not follow symlinks (default: follow)
   -r -R -m               accepted and ignored: the transfer is
                          already recursive and parallel

   Anything else is handed to 'gcloud storage rsync' unchanged, so any
   of its flags can be used directly. Quote a value containing a
   space:   GCSOPTIONS="-x 'my notes'"

 COMMANDS

   setup         validate, install the schedule, run cron  (default)
   backup        run one backup now, outside the schedule:
                   docker exec <container> sh /opt/run.sh backup
                 exits non-zero if the backup failed
   healthcheck   report the last backup's outcome
   help          print this and exit

 ALSO WORTH KNOWING

   /var/log/cron.log   the backup log, also streamed to the container's
                       stdout, so 'docker logs -f' follows it
   docker ps           reports 'unhealthy' once a backup has failed
   gcloud auth list    says "no credentialed accounts" even when auth
                       works: the key file is used directly

 REMOVED IN 2.0

   ACCESS_KEY, SECRET_KEY and BOTO_FILE. Google is retiring gsutil,
   the tool 1.x transferred files with, and removes it from the Cloud
   CLI after March 2027; backups now use its replacement, 'gcloud
   storage'. That tool talks to the JSON API, which HMAC keys cannot
   sign, so authentication moved to SERVICE_ACCOUNT_FILE. Setting any
   of the three prints full migration instructions. See "Migrating
   from 1.x" in the README.
======================================================================
HELP
}

# Apply $TZ. musl resolves the TZ variable on its own, but crond only re-reads
# it at startup and passes a minimal environment to the jobs it spawns, so
# /etc/localtime is written too: that makes the schedule, this script and the
# CLI all agree on the same zone. An unknown zone would silently fall back to
# UTC, so it is reported loudly instead.
setup_timezone()
{
    if [ ! -f "/usr/share/zoneinfo/$TZ" ]; then
      echo "Unknown timezone '$TZ', falling back to UTC. Use a zoneinfo name such as America/Montreal."
      TZ="UTC"
    fi

    cp "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone
    export TZ
}

# Keep $LOG from growing without bound: an hourly backup appends to it forever.
# The most recent half is kept, so the log a user goes looking at after a failure
# still has the failure in it.
trim_log()
{
    case "$LOG_MAX_BYTES" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$LOG_MAX_BYTES" -gt 0 ] || return 0
    [ -f "$LOG" ] || return 0

    SIZE=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "$SIZE" -gt "$LOG_MAX_BYTES" ] || return 0

    KEEP=$((LOG_MAX_BYTES / 2))
    if tail -c "$KEEP" "$LOG" > "$LOG.trimmed" 2>/dev/null; then
      mv -f "$LOG.trimmed" "$LOG"
      log_info "Log passed $LOG_MAX_BYTES bytes and was trimmed to its most recent $KEEP."
    else
      rm -f "$LOG.trimmed"
    fi
}

# Record the outcome of a backup so `healthcheck` - and anyone reading the file -
# can tell a successful run from a failed one without parsing the log.
write_status()
{
    printf 'STATUS=%s\nWHEN=%s\n' "$1" "$(date '+%Y-%m-%d %H:%M:%S %Z')" > "$STATUSFILE" 2>/dev/null
}

# HMAC keys sign XML API requests, which is all gsutil used. `gcloud storage`
# talks to the JSON API and cannot authenticate with them at all, so there is no
# way to keep supporting them now that gsutil is gone: say so plainly rather
# than ignoring the variables and failing later on every scheduled run.
check_removed_credentials()
{
    if [ -z "$ACCESS_KEY" ] && [ -z "$SECRET_KEY" ] && [ -z "$BOTO_FILE" ]; then
      return
    fi

    # Leftovers in an otherwise migrated configuration: harmless, just noise.
    if [ -n "$SERVICE_ACCOUNT_FILE" ]; then
      echo ""
      echo "WARNING: ACCESS_KEY, SECRET_KEY and BOTO_FILE are ignored as of version 2.0."
      echo "They configured gsutil, which Google is retiring - see below - so backups now"
      echo "run 'gcloud storage' and authenticate with SERVICE_ACCOUNT_FILE instead, which"
      echo "is already set. You can remove the three old variables from your configuration."
      echo ""
      return
    fi

    cat <<'MIGRATE'

======================================================================
 Version 1.x configuration detected - this needs one change
======================================================================
 This container cannot start as configured: ACCESS_KEY, SECRET_KEY and
 BOTO_FILE are no longer supported as of version 2.0.

 WHY THIS CHANGED

 Google is retiring gsutil, the tool version 1.x used to transfer your
 files. It is deprecated, and Google removes it from the Google Cloud
 CLI after March 2027. Backups therefore run 'gcloud storage' now,
 which is Google's supported replacement for it.

 That is also what forces your credentials to change. gsutil signed
 requests to the Cloud Storage XML API, and HMAC keys - ACCESS_KEY and
 SECRET_KEY, or the pair inside a BOTO_FILE - are the credentials for
 that API. 'gcloud storage' uses the JSON API, which HMAC keys cannot
 sign at all. There is no setting that keeps them working; the switch
 to a service account key is unavoidable, not a preference.

 HOW TO MIGRATE  (about five minutes)

 1. Create a service account, or reuse one: the HMAC keys you use
    today already belong to a service account, and the console shows
    which one under "Service account HMAC" in your bucket's
    interoperability settings.
 2. Give it access to the bucket. "Storage Object Admin" covers
    everything, including the deletions GCSOPTIONS=-d performs;
    without -d, "Storage Object User" is enough.
 3. Create a JSON key for it (service account -> Keys -> Add key ->
    Create new key -> JSON) and mount the downloaded file into this
    container, read-only.
 4. Replace ACCESS_KEY and SECRET_KEY (or BOTO_FILE) with:
      SERVICE_ACCOUNT_FILE=/path/to/key.json

 Nothing else changes: /data, GCSPATH, GCSOPTIONS, CRON_SCHEDULE and
 TZ all keep working exactly as they did. Full instructions are under
 "Migrating from 1.x" in the README.

 IF YOU NEED MORE TIME

 vinid223/gcloud-storage-backup:V1.3 still uses gsutil and still
 accepts HMAC keys. It will keep working until Google actually removes
 gsutil, so pinning that tag buys time - but it is not a fix, and the
 deadline above applies to it too.
======================================================================
MIGRATE

    # Terminal on purpose: there is no configuration in which these variables
    # work. Exiting here also keeps the generic "SERVICE_ACCOUNT_FILE must be
    # set" message from trailing the explanation that just answered it.
    echo "Exiting"
    exit 1
}

# Point gcloud at the mounted key file. credential_file_override lets gcloud use
# a service account key directly, with no `gcloud auth activate-service-account`
# round-trip to Google and no credential state to keep in the container.
configure_gcloud_env()
{
    if [ -n "$SERVICE_ACCOUNT_FILE" ]; then
      export CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$SERVICE_ACCOUNT_FILE"
    fi

    if [ -n "$PROJECT_ID" ]; then
      export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
    fi
}

# Everything else is pointless without a destination, so it is checked for the
# commands that actually transfer data.
require_gcspath()
{
    if [ -z "$GCSPATH" ]; then
      echo "GCSPATH required: set it to the bucket and path to back up to (ex: gs://my-bucket/)."
      echo "Exiting"
      exit 1
    fi
}

# busybox crond wants exactly five fields, or one of its @macros. Anything else
# is accepted silently and then never fires, which on a backup schedule is worth
# catching at startup rather than discovering from an empty bucket.
validate_cron_schedule()
{
    case "$CRON_SCHEDULE" in
        @*) return 0 ;;
    esac

    # Deliberate word splitting to count the fields, with globbing off: a cron
    # schedule is mostly '*', which would otherwise expand to the file names in
    # the current directory.
    set -f
    # shellcheck disable=SC2086
    set -- $CRON_SCHEDULE
    set +f
    if [ $# -ne 5 ]; then
      echo "CRON_SCHEDULE must have 5 fields (minute hour day-of-month month day-of-week), or be an @macro such as @daily."
      echo "Got $# field(s): '$CRON_SCHEDULE'"
      echo "Exiting"
      exit 1
    fi
}

# Remember everything the scheduled run needs. Values are shell-quoted, so paths
# and patterns containing spaces or quotes survive the round trip.
write_env_file()
{
    CARRIED="GCSPATH GCSOPTIONS TZ SERVICE_ACCOUNT_FILE PROJECT_ID LOG_MAX_BYTES"
    # Any CLI setting passed to the container (endpoint overrides, proxy
    # settings, verbosity) is carried over too, so a scheduled run behaves like a
    # hand-run one. Only names are read from env, so multi-line values are safe.
    CARRIED="$CARRIED $(env | sed -n 's/^\(CLOUDSDK_[A-Za-z0-9_]*\)=.*/\1/p' | sort -u)"

    OLD_UMASK=$(umask)
    umask 077
    : > "$ENVFILE"
    for VAR in $CARRIED; do
      eval "VALUE=\${$VAR-}"
      # Written as an explicit test rather than ${VAR:=value}, because inside the
      # double quotes that construct needs, the quotes around the value would
      # stay part of it.
      {
        printf '[ -n "${%s:-}" ] || %s=%s\n' "$VAR" "$VAR" "$(shquote "$VALUE")"
        printf 'export %s\n' "$VAR"
      } >> "$ENVFILE"
    done
    umask "$OLD_UMASK"
}

# Take the lock, or explain why not. The pid is stored so a lock left behind by
# an interrupted run (SIGKILL, or the container stopped mid-sync) is recognised
# as stale and taken over, instead of blocking every backup from then on.
# Creation goes through `set -C`, which fails if the file already exists, so two
# runs starting at the same moment cannot both win.
acquire_lock()
{
    if ( set -C; echo $$ > "$LOCKFILE" ) 2>/dev/null; then
      trap 'rm -f "$LOCKFILE"' EXIT INT TERM
      return 0
    fi

    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)
    case "$LOCK_PID" in
        ''|*[!0-9]*)
            log_info "$LOCKFILE holds no pid, assuming it is stale and taking it over."
            ;;
        *)
            if kill -0 "$LOCK_PID" 2>/dev/null; then
              log_info "$LOCKFILE detected, exiting! Already running? (pid $LOCK_PID)"
              return 1
            fi
            log_info "$LOCKFILE is stale (pid $LOCK_PID is gone), taking it over."
            ;;
    esac

    rm -f "$LOCKFILE"
    if ( set -C; echo $$ > "$LOCKFILE" ) 2>/dev/null; then
      trap 'rm -f "$LOCKFILE"' EXIT INT TERM
      return 0
    fi

    log_info "$LOCKFILE detected, exiting! Already running? (another run took the lock first)"
    return 1
}


# healthcheck answers from the status file alone: no network, no gcloud start-up,
# nothing written. It runs before the banner so `docker inspect` shows only the
# one line explaining the state.
if [ "$OPTION" = "healthcheck" ]; then
  if [ ! -f "$STATUSFILE" ]; then
    echo "no backup has completed yet"
    exit 0
  fi

  LAST_STATUS=$(sed -n 's/^STATUS=//p' "$STATUSFILE" 2>/dev/null)
  LAST_WHEN=$(sed -n 's/^WHEN=//p' "$STATUSFILE" 2>/dev/null)
  if [ "${LAST_STATUS:-0}" = "0" ]; then
    echo "last backup succeeded (${LAST_WHEN:-unknown})"
    exit 0
  fi

  echo "last backup FAILED with exit status $LAST_STATUS (${LAST_WHEN:-unknown})"
  exit 1
fi

# Asked for explicitly. Nothing is validated first, so it answers "what can I
# set?" even with no configuration at all: `docker run --rm <image> help`.
case "$OPTION" in
    help|--help|-h)
        print_help
        exit 0
        ;;
esac

# Welcome
echo "Welcome to Google Cloud Storage Docker"
echo "A backup utility to GCP Bucket"

setup_timezone

# At container start, before any validation, so a container that goes on to
# refuse to start still leaves the settings reference - and the values it
# actually resolved - in its log. TZ is applied first so the value shown is the
# one in effect. Left out of `backup`, which would otherwise repeat the whole
# menu into the log on every scheduled run.
if [ "$OPTION" = "setup" ]; then
  print_help
fi

check_removed_credentials
configure_gcloud_env

if [ "$OPTION" = "setup" ]; then

  require_gcspath
  validate_cron_schedule

  if [ -z "$SERVICE_ACCOUNT_FILE" ]; then
    echo "SERVICE_ACCOUNT_FILE must be set to the path of a mounted service account JSON key file."
    echo "Exiting"
    exit 1
  fi

  if [ ! -f "$SERVICE_ACCOUNT_FILE" ]; then
    echo "SERVICE_ACCOUNT_FILE '$SERVICE_ACCOUNT_FILE' not found. Mount the service account key file in the container."
    echo "Exiting"
    exit 1
  fi

  # Checked locally on purpose: nothing here contacts Google, so a restart
  # during a network outage still brings the container up and the next
  # scheduled run retries. Tokens are minted at sync time instead.
  SERVICE_ACCOUNT_EMAIL=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['client_email'] if d.get('type') == 'service_account' and d.get('private_key') else '')" "$SERVICE_ACCOUNT_FILE" 2>/dev/null)

  if [ -z "$SERVICE_ACCOUNT_EMAIL" ]; then
    echo "SERVICE_ACCOUNT_FILE '$SERVICE_ACCOUNT_FILE' is not a service account JSON key file (expected type, private_key and client_email fields)."
    echo "Exiting"
    exit 1
  fi

  echo "Using service account $SERVICE_ACCOUNT_EMAIL"
  echo "(Note: 'gcloud auth list' reports no credentialed accounts even while this key is in use,"
  echo " because the CLI is pointed straight at the key file rather than at a stored login.)"

  echo "Found the following files and directories mounted under /data:"
  echo ""
  ls -F /data
  echo ""

  echo "Adding CRON schedule: $CRON_SCHEDULE ($TZ)"

  rm -f "$CRONFILE"
  rm -f "$LOCKFILE"

  write_env_file

  # The job line carries no environment assignments: everything it needs is in
  # $ENVFILE, which run.sh sources itself.
  echo "$CRON_SCHEDULE sh /opt/run.sh backup" >> "$CRONFILE"
  echo "Starting CRON scheduler: $(date)"
  cat "$CRONFILE"

  # -L sends crond's own messages to the log, so "did the job fire at all?" is
  # answerable; without it they go to syslog, which nothing here runs.
  crond -L "$LOG"

  case "$RUN_ON_STARTUP" in
      [Tt][Rr][Uu][Ee]|1|[Yy]|[Yy][Ee][Ss]|[Oo][Nn])
          echo "RUN_ON_STARTUP is set: running a backup now rather than waiting for the schedule."
          sh /opt/run.sh backup
          echo "Initial backup finished with exit status $?. Its output is in $LOG, streamed below."
          ;;
  esac

  # -F (rather than -f) follows the path, so the stream survives the log being
  # trimmed. This tail is PID 1, and its stdout is the container's stdout.
  exec tail -F "$LOG"

elif [ "$OPTION" = "backup" ]; then
  require_gcspath
  trim_log
  log_info "Starting sync: $(date)"

  if ! acquire_lock; then
    exit 1
  fi

  # Split GCSOPTIONS the way a shell would, so quoting inside it is honoured and
  # a pattern containing spaces can be given as GCSOPTIONS="-x 'my notes'".
  # Globbing stays off throughout: an --exclude value is a regex, and letting
  # something like '.*\.log' or '*' expand against the working directory would
  # silently rewrite it into a list of file names.
  set -f
  case "$GCSOPTIONS" in
      *\'*|*\"*)
          # Quoted, so the shell does the splitting and a value can contain
          # spaces: GCSOPTIONS="-x 'my notes'". The parse is rehearsed in a
          # subshell first because a syntax error inside eval (an unbalanced
          # quote) terminates the shell outright rather than returning non-zero,
          # which would end the run with nothing explaining why.
          if ! ( eval "set -- $GCSOPTIONS" ) 2>/dev/null; then
            log_info "GCSOPTIONS could not be parsed, check for an unbalanced quote: $GCSOPTIONS"
            write_status 2
            exit 2
          fi
          eval "set -- $GCSOPTIONS"
          ;;
      *)
          # No quotes anywhere: split on whitespace and nothing else. eval would
          # also strip backslashes, and an --exclude regex is full of them
          # (-x '.*\.log'), so unquoted values deliberately avoid it.
          # shellcheck disable=SC2086
          set -- $GCSOPTIONS
          ;;
  esac

  # Translate the gsutil rsync flags that GCSOPTIONS used to hold into their
  # gcloud storage rsync equivalents, so upgrading does not also mean rewriting
  # GCSOPTIONS. Anything unrecognised is passed through untouched: gcloud storage
  # flags can be given directly.
  #
  # Each pass takes one argument off the front and appends its translation to the
  # end, so after $# passes only translated arguments are left. That is the POSIX
  # way to rebuild an argument list without flattening it back into one string,
  # which is what lets an --exclude pattern contain spaces.
  SYMLINKS_SET=""
  REMAINING=$#
  while [ "$REMAINING" -gt 0 ]; do
    OPT=$1
    shift
    REMAINING=$((REMAINING - 1))
    case "$OPT" in
        -d) set -- "$@" --delete-unmatched-destination-objects ;;
        -n) set -- "$@" --dry-run ;;
        -C) set -- "$@" --continue-on-error ;;
        -e|--ignore-symlinks) SYMLINKS_SET=yes; set -- "$@" --ignore-symlinks ;;
        --no-ignore-symlinks) SYMLINKS_SET=yes; set -- "$@" --no-ignore-symlinks ;;
        -x)
            if [ "$REMAINING" -gt 0 ]; then
              PATTERN=$1
              shift
              REMAINING=$((REMAINING - 1))
              set -- "$@" --exclude "$PATTERN"
            else
              log_info "GCSOPTIONS: -x needs a pattern after it, ignoring it."
            fi
            ;;
        # rsync is always called recursively, and gcloud storage is parallel by
        # default, so -r/-R and -m have nothing left to map to.
        -r|-R|-m) ;;
        *) set -- "$@" "$OPT" ;;
    esac
  done

  # gcloud storage ignores symlinks by default where gsutil followed them, so the
  # 1.x behaviour is restored - unless GCSOPTIONS already settled the matter, in
  # which case adding it as well would hand gcloud a contradictory pair of flags.
  if [ -n "$SYMLINKS_SET" ]; then
    set -- --recursive "$@"
  else
    set -- --recursive --no-ignore-symlinks "$@"
  fi
  set +f

  log_info "Executing gcloud storage rsync $* /data $GCSPATH..."
  "$GCLOUD" storage rsync "$@" /data "$GCSPATH" >> "$LOG" 2>&1
  STATUS=$?

  rm -f "$LOCKFILE"
  trap - EXIT INT TERM
  write_status "$STATUS"

  if [ "$STATUS" -ne 0 ]; then
    log_info "Sync FAILED with exit status $STATUS"
  fi

  log_info "Finished sync: $(date)"
  # Propagated, so cron, `docker exec` and the healthcheck can all tell a failed
  # backup from a successful one without parsing the log.
  exit "$STATUS"
else
  log_info "Unsupported option: $OPTION"
  echo "Unsupported option: $OPTION"
  echo ""
  print_help
  exit 1
fi
