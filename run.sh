!/bin/bash

# Set sane bash defaults
set -o errexit
set -o pipefail

OPTION="$1"
SERVICE_ACCOUNT=${SERVICE_ACCOUNT:?"SERVICE_ACCOUNT required"}
KEY_FILE_JSON=${KEY_FILE_JSON:?"KEY_FILE_JSON required"}
GCSPATH=${GCSPATH:?"GCSPATH required"}
CRON_SCHEDULE=${CRON_SCHEDULE:-0 * * * *}

LOCKFILE="/tmp/gcloudlock.lock"
LOG="/var/log/cron.log"
KEYFILE="/tmp/keyfile"

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
  
  ls -F /data > ./inputFiles

  # https://cloud.google.com/sdk/docs/authorizing

  echo "Adding CRON schedule: $CRON_SCHEDULE"
  CRONENV="$CRONENV SERVICE_ACCOUNT=$SERVICE_ACCOUNT"
  CRONENV="$CRONENV KEY_FILE_JSON=$KEY_FILE_JSON"
  CRONENV="$CRONENV GCSPATH=$GCSPATH"
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
  gcloud auth activate-service-account $SERVICE_ACCOUNT --key-file=$KEYFILE | tee -a $LOG
  cat inputFiles | gsutil -m cp -r -I $GCSPATH | tee -a $LOG
  rm -f $LOCKFILE
  echo "Finished sync: $(date)" | tee -a $LOG

else
  echo "Unsupported option: $OPTION" | tee -a $LOG
  exit 1
fi
