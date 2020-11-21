# gcloud-storage-docker

Note : This repository is maintained on a private Gitlab server and is replicated in realtime on github.

Github repository : https://github.com/vinid223/GcloudStorage-docker
Docker Hub : https://hub.docker.com/r/vinid223/gcloud-storage-backup

gcloud-storage-docker is a Docker container which backs up one or more folders to Google Cloud Storage using the gsutil tool.

To tell gcloud-storage-docker what to back up, mount your desired volumes under the `/data` directory.

gcloud-storage-docker is configured by setting the following environment variables during
the launch of the container.

- ACCESS_KEY - your GCP access key for a service account
- SECRET_KEY - your GCP secret key for a service account
- GCSPATH - your GCS bucket and path (ex: gs://personal-backup-bucket/)
- GCSOPTIONS - custom parameters to gsutil. (ex: "-d" to have a exact copy of the local files (delete on the bucket files that don't exists anymore) )

Files are by default backed up once every hour. You can customize this behavior
using an environment variable which uses the standard CRON notation.

- `CRON_SCHEDULE` - set to `0 * * * *` by default, which means every hour.

## Example invocation

To backup the `Documents` and the `Photos` directories in your home folder, and
running the backup at 03:00 every day, you could use something like this:

```
docker run -d -v /home/user/Documents:/data/documents \ 
              -v /home/user/Photos:/data/photos \ 
              -e "ACCESS_KEY=YOURACCESSKEY" \ 
              -e "SECRET_KEY=YOURSECRETKEY" \ 
              -e "GCSPATH=gs://yourgsbucket/" \ 
              -e "GCSOPTIONS=-d" \ 
              -e "CRON_SCHEDULE=0 3 * * *" \ 
              vinid223/gcloud-storage-docker 
```

## How to get your Access Key and Secret Key

1. Go to your GCS Settings page, on the Interoperability tab here https://console.cloud.google.com/storage/settings;tab=interoperability
2. Under `Service account HMAC`, click on a service account if one exists or create a new one by clicking on `CREATE A KEY FOR ANOTHER SERVICE ACCOUNT`
3. Click on `CREATE A KEY` and you should see your Access Key and Secret Key

## Inspiration
https://github.com/joch/docker-s3backup
