#!/bin/bash

# Parameters
OPTION="$1"
# GCSPATH=${GCSPATH:?"GCSPATH required"}
# GCSOPTIONS=${GCSOPTIONS}
CRON_SCHEDULE=${CRON_SCHEDULE:-0 * * * *}

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
    echo "$INPUT" | tee -a $LOG
}


# Welcome
log_info "Welcome to Google Cloud Storage Docker"
log_info "A backup utility to GCP Bucket"

if [[ $OPTION = "setup" ]]; then

    CRONFILE="/etc/crontabs/root"
    CRONENV=""

    log_info "Found the following files and directores mounted under /data:"
    log_info ""
    ls -F /data
    log_info ""

    log_info "Adding CRON schedule: $CRON_SCHEDULE"

        rm -f $CRONFILE

        echo "$CRON_SCHEDULE sh /opt/run.sh backup" >> $CRONFILE
        cat $CRONFILE
        crond
        exec tail -f $LOG >> /proc/1/fd/1
else
    log_info "Unsupported option: $OPTION"
    log_info "See documentation on available options."
    exit 1
fi
