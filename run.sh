#!/bin/bash

# Set sane bash defaults
set -o errexit
set -o pipefail

OPTION="$1"
ACCESS_KEY=${ACCESS_KEY:?"ACCESS_KEY required"}
SECRET_KEY=${SECRET_KEY:?"SECRET_KEY required"}
GCSPATH=${GCSPATH:?"GCSPATH required"}
GCSOPTIONS=${GCSOPTIONS}
CRON_SCHEDULE=${CRON_SCHEDULE:-0 * * * *}

LOCKFILE="/tmp/gcloudlock.lock"
LOG="/var/log/cron.log"

sed -i "s/replace_gs_access_key_id/$ACCESS_KEY/g" /root/.boto
sed -i "s/replace_gs_secret_access_key/$SECRET_KEY/g" /root/.boto

trap "rm -f $LOCKFILE" EXIT

if [ ! -e $LOG ]; then
  touch $LOG
fi

if [[ $OPTION = "start" ]]; then

  CRONFILE="/etc/cron.d/gcloud_backup"
  CRONENV=""

  echo "Found the following files and directores mounted under /data:"
  echo
  ls -F /data
  echo
  
  # https://cloud.google.com/sdk/docs/authorizing

  echo "Adding CRON schedule: $CRON_SCHEDULE"
  CRONENV="$CRONENV ACCESS_KEY=$ACCESS_KEY"
  CRONENV="$CRONENV SECRET_KEY=$SECRET_KEY"
  CRONENV="$CRONENV GCSPATH=$GCSPATH"
  CRONENV="$CRONENV GCSOPTIONS=\"$GCSOPTIONS\""
  rm -f $CRONFILE # Remove CRONFILE on start to avoid multiple inserts in the file
  echo "$CRON_SCHEDULE root $CRONENV bash /run.sh backup" >> $CRONFILE

  echo "Starting CRON scheduler: $(date)"
  cron
  exec tail -f $LOG 2> /dev/null

elif [[ $OPTION = "backup" ]]; then
  echo "Starting sync: $(date)" | tee $LOG

  if [ -f $LOCKFILE ]; then
    echo "$LOCKFILE detected, exiting! Already running?" | tee -a $LOG
    exit 1
  else
    touch $LOCKFILE
  fi

  echo "Executing gsutil sync /data/ $GCSPATH..." | tee -a $LOG
  gsutil -m rsync -r $GCSOPTIONS /data $GCSPATH | tee -a $LOG
  rm -f $LOCKFILE
  echo "Finished sync: $(date)" | tee -a $LOG

else
  echo "Unsupported option: $OPTION" | tee -a $LOG
  exit 1
fi
