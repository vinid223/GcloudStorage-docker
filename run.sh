#!/bin/bash

# Parameters
OPTION="$1"
SERVICE_ACCOUNT_FILE=${SERVICE_ACCOUNT_FILE:-"NULL"}
PROJECT_ID=${PROJECT_ID:-"NULL"}
GCSPATH=${GCSPATH:?"GCSPATH required"}
GCSOPTIONS=${GCSOPTIONS}
CRON_SCHEDULE=${CRON_SCHEDULE:-0 * * * *}
TZ=${TZ:-UTC}

# Removed in 2.0, kept here only to give their users a clear error instead of a
# silently broken backup.
ACCESS_KEY=${ACCESS_KEY:-"NULL"}
SECRET_KEY=${SECRET_KEY:-"NULL"}
BOTO_FILE=${BOTO_FILE:-"NULL"}

# Internal variables
LOCKFILE="/tmp/gcloudlock.lock"
STATEFILE="/tmp/gcsbackup.env"
LOG="/var/log/cron.log"
GCLOUD="/google-cloud-sdk/bin/gcloud"

# crond hands its jobs a minimal environment, so the CLI settings are exported
# here rather than relying on the image ENV: CLOUDSDK_PYTHON pins the interpreter
# and CLOUDSDK_CONFIG gives the CLI a writable config directory even when HOME is
# not set.
export CLOUDSDK_PYTHON="python3"
export CLOUDSDK_CONFIG="/root/.config/gcloud"

# Create logfile if does not exists
if [ ! -e $LOG ]; then
    touch $LOG
fi

# Functions definition
log_info()
{
    INPUT=$1
    echo "$INPUT" >> $LOG
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

# HMAC keys sign XML API requests, which is all gsutil used. `gcloud storage`
# talks to the JSON API and cannot authenticate with them at all, so there is no
# way to keep supporting them now that gsutil is gone: say so plainly rather
# than ignoring the variables and failing later on every scheduled run.
check_removed_credentials()
{
    if [[ $ACCESS_KEY = "NULL" ]] && [[ $SECRET_KEY = "NULL" ]] && [[ $BOTO_FILE = "NULL" ]]; then
      return
    fi

    # Leftovers in an otherwise migrated configuration: harmless, just noise.
    if [[ $SERVICE_ACCOUNT_FILE != "NULL" ]]; then
      echo "WARNING: ACCESS_KEY, SECRET_KEY and BOTO_FILE are ignored as of version 2.0. SERVICE_ACCOUNT_FILE is used instead; you can remove them from your configuration."
      return
    fi

    echo ""
    echo "ACCESS_KEY, SECRET_KEY and BOTO_FILE are no longer supported as of version 2.0."
    echo ""
    echo "This image now backs up with 'gcloud storage', which authenticates through the JSON"
    echo "API. HMAC keys only work with the XML API, so they cannot be used anymore."
    echo ""
    echo "To migrate:"
    echo "  1. Create a service account with access to your bucket (role Storage Object Admin)."
    echo "  2. Create a JSON key for it and mount the file in this container."
    echo "  3. Replace ACCESS_KEY/SECRET_KEY (or BOTO_FILE) with SERVICE_ACCOUNT_FILE=/path/to/key.json"
    echo ""
    echo "Version 1.3 keeps working with HMAC keys if you need more time: vinid223/gcloud-storage-backup:V1.3"
    echo ""
}

# Point gcloud at the mounted key file. credential_file_override lets gcloud use
# a service account key directly, with no `gcloud auth activate-service-account`
# round-trip to Google and no credential state to keep in the container.
configure_gcloud_env()
{
    if [[ $SERVICE_ACCOUNT_FILE != "NULL" ]]; then
      export CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$SERVICE_ACCOUNT_FILE"
    fi

    if [[ $PROJECT_ID != "NULL" ]]; then
      export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
    fi
}

# Translate the gsutil rsync flags that GCSOPTIONS used to hold into their
# gcloud storage rsync equivalents, so upgrading does not also mean rewriting
# GCSOPTIONS. Anything unrecognised is passed through untouched: gcloud storage
# flags can be given directly.
translate_gcsoptions()
{
    GCLOUD_OPTIONS=""

    for OPT in $GCSOPTIONS; do
      case "$OPT" in
        -d) GCLOUD_OPTIONS="$GCLOUD_OPTIONS --delete-unmatched-destination-objects" ;;
        -n) GCLOUD_OPTIONS="$GCLOUD_OPTIONS --dry-run" ;;
        -C) GCLOUD_OPTIONS="$GCLOUD_OPTIONS --continue-on-error" ;;
        -e) GCLOUD_OPTIONS="$GCLOUD_OPTIONS --ignore-symlinks" ;;
        -x) GCLOUD_OPTIONS="$GCLOUD_OPTIONS --exclude" ;;
        # rsync is always called recursively, and gcloud storage is parallel by
        # default, so -r/-R and -m have nothing left to map to.
        -r|-R|-m) ;;
        *) GCLOUD_OPTIONS="$GCLOUD_OPTIONS $OPT" ;;
      esac
    done
}


# Welcome
echo "Welcome to Google Cloud Storage Docker"
echo "A backup utility to GCP Bucket"

setup_timezone

# A backup started by hand rather than by cron gets none of the variables cron
# passes along, so fall back to what setup resolved.
if [[ $OPTION = "backup" ]] && [[ $SERVICE_ACCOUNT_FILE = "NULL" ]] && [ -f $STATEFILE ]; then
  . $STATEFILE
fi

configure_gcloud_env

if [[ $OPTION = "setup" ]]; then

  CRONFILE="/etc/crontabs/root"
  CRONENV=""

  check_removed_credentials

  if [[ $SERVICE_ACCOUNT_FILE = "NULL" ]]; then
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

  echo "Found the following files and directores mounted under /data:"
  echo ""
  ls -F /data
  echo ""

  echo "Adding CRON schedule: $CRON_SCHEDULE ($TZ)"

  rm -f $CRONFILE
  rm -f $LOCKFILE

  # Remembered for backups started by hand, which get none of the CRONENV below.
  {
    echo "SERVICE_ACCOUNT_FILE=\"$SERVICE_ACCOUNT_FILE\""
    echo "PROJECT_ID=\"$PROJECT_ID\""
  } > $STATEFILE

  CRONENV="$CRONENV GCSPATH=\"$GCSPATH\""
  CRONENV="$CRONENV GCSOPTIONS=\"$GCSOPTIONS\""
  CRONENV="$CRONENV TZ=\"$TZ\""
  # The key file is passed along because the scheduled run needs it to mint a
  # token.
  CRONENV="$CRONENV SERVICE_ACCOUNT_FILE=\"$SERVICE_ACCOUNT_FILE\""
  CRONENV="$CRONENV PROJECT_ID=\"$PROJECT_ID\""
  # crond gives its jobs a minimal environment, so any CLI setting passed to the
  # container (endpoint overrides, proxy settings, verbosity) is carried over
  # explicitly - otherwise the scheduled run would behave differently from a
  # backup started by hand.
  for VAR in $(env | grep -E '^CLOUDSDK_' | cut -d= -f1); do
    eval "VALUE=\$$VAR"
    CRONENV="$CRONENV $VAR=\"$VALUE\""
  done
  echo "$CRON_SCHEDULE $CRONENV sh /opt/run.sh backup" >> $CRONFILE
  echo "Starting CRON scheduler: $(date)"
  cat $CRONFILE
  crond
  exec tail -f $LOG >> /proc/1/fd/1

elif [[ $OPTION = "backup" ]]; then
  log_info "Starting sync: $(date)"

  if [ -f $LOCKFILE ]; then
    log_info "$LOCKFILE detected, exiting! Already running?"
    exit 1
  else
    touch $LOCKFILE
  fi

  translate_gcsoptions
  # --no-ignore-symlinks keeps the 1.x behaviour of following symlinks; gcloud
  # storage skips them by default.
  GCLOUD_ARGS="--recursive --no-ignore-symlinks$GCLOUD_OPTIONS"
  log_info "Executing gcloud storage rsync $GCLOUD_ARGS /data $GCSPATH..."
  $GCLOUD storage rsync $GCLOUD_ARGS /data $GCSPATH >> $LOG 2>&1

  STATUS=$?
  rm -f $LOCKFILE

  if [ $STATUS -ne 0 ]; then
    log_info "Sync FAILED with exit status $STATUS"
  fi

  log_info "Finished sync: $(date)"
else
  log_info "Unsupported option: $OPTION"
  log_info "See documentation on available options."
  exit 1
fi
