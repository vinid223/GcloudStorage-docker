#!/bin/bash

# Parameters
OPTION="$1"
BOTO_FILE=${BOTO_FILE:-"NULL"}
ACCESS_KEY=${ACCESS_KEY:-"NULL"}
SECRET_KEY=${SECRET_KEY:-"NULL"}
GCSPATH=${GCSPATH:?"GCSPATH required"}
GCSOPTIONS=${GCSOPTIONS}
CRON_SCHEDULE=${CRON_SCHEDULE:-0 * * * *}
TZ=${TZ:-UTC}

# Internal variables
LOCKFILE="/tmp/gcloudlock.lock"
LOG="/var/log/cron.log"

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
# /etc/localtime is written too: that makes the schedule, this script and gsutil
# all agree on the same zone. An unknown zone would silently fall back to UTC,
# so it is reported loudly instead.
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


# Welcome
echo "Welcome to Google Cloud Storage Docker"
echo "A backup utility to GCP Bucket"

setup_timezone

if [[ $OPTION = "setup" ]]; then

  CRONFILE="/etc/crontabs/root"
  CRONENV=""

  if [[ $BOTO_FILE = "NULL" ]]; then
    if [[ $ACCESS_KEY = "NULL" ]] || [[ $SECRET_KEY = "NULL" ]]; then
      echo "ACCESS_KEY and SECRET_KEY must have a value when BOTO_FILE is not set"
      echo "Exiting"
      exit 1
    fi

    echo "Configuring ACCESS KEYS"
    sed -i "s|replace_gs_access_key_id|$ACCESS_KEY|g" /root/.boto
    sed -i "s|replace_gs_secret_access_key|$SECRET_KEY|g" /root/.boto
  else
    echo "Copy $BOTO_FILE to /root/.boto"
    cp $BOTO_FILE /root/.boto
  fi

  echo "Found the following files and directores mounted under /data:"
  echo ""
  ls -F /data
  echo ""

  echo "Adding CRON schedule: $CRON_SCHEDULE ($TZ)"

  rm -f $CRONFILE
  rm -f $LOCKFILE

  CRONENV="$CRONENV GCSPATH=\"$GCSPATH\""
  CRONENV="$CRONENV GCSOPTIONS=\"$GCSOPTIONS\""
  CRONENV="$CRONENV TZ=\"$TZ\""
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

  log_info "Executing gsutil sync /data/ $GCSPATH..."
  CLOUDSDK_PYTHON="python3" sh /google-cloud-sdk/bin/gsutil -m rsync -r $GCSOPTIONS /data $GCSPATH >> $LOG 2>&1
  rm -f $LOCKFILE
  log_info "Finished sync: $(date)"
else
  log_info "Unsupported option: $OPTION"
  log_info "See documentation on available options."
  exit 1
fi
