# gcloud-storage-docker

Note : This repository is maintained on a private Forgejo server (CI/CD via Forgejo Actions — see [`.forgejo/workflows/README.md`](.forgejo/workflows/README.md)) and is replicated in realtime on github.

Github repository : https://github.com/vinid223/GcloudStorage-docker
Docker Hub : https://hub.docker.com/r/vinid223/gcloud-storage-backup

gcloud-storage-docker is a Docker container which backs up one or more folders to Google Cloud Storage using the `gcloud storage` tool.

> **Upgrading from 1.x?** Version 2.0 replaces gsutil with `gcloud storage` and no longer accepts
> HMAC keys. `ACCESS_KEY`, `SECRET_KEY` and `BOTO_FILE` are gone; you now mount a service account
> JSON key file instead. See [Migrating from 1.x](#migrating-from-1x).

To tell gcloud-storage-docker what to back up, mount your desired volumes under the `/data` directory.

gcloud-storage-docker is configured by setting the following environment variables during
the launch of the container.

- SERVICE_ACCOUNT_FILE - path to a mounted service account JSON key file, used to authenticate. Required.
- GCSPATH - your GCS bucket and path (ex: gs://personal-backup-bucket/)
- GCSOPTIONS - custom parameters to `gcloud storage rsync`. (ex: "-d" to have a exact copy of the local files (delete on the bucket files that don't exists anymore) )
- PROJECT_ID - optional GCP project, if your bucket needs one to be set.

Files are by default backed up once every hour. You can customize this behavior
using an environment variable which uses the standard CRON notation.

- `CRON_SCHEDULE` - set to `0 * * * *` by default, which means every hour.

The schedule is evaluated in the container timezone, which is UTC by default. Set `TZ` to a
zoneinfo name to use your own timezone for both the schedule and the log timestamps.

- `TZ` - set to `UTC` by default (ex: `America/Montreal`). An unknown name falls back to UTC
  and logs a warning at startup.

## Example invocation

To backup the `Documents` and the `Photos` directories in your home folder, and
running the backup at 03:00 every day, you could use something like this:

```
docker run -d -v /home/user/Documents:/data/documents \ 
              -v /home/user/Photos:/data/photos \ 
              -v /path/to/service-account.json:/secrets/sa.json:ro \ 
              -e "SERVICE_ACCOUNT_FILE=/secrets/sa.json" \ 
              -e "GCSPATH=gs://yourgsbucket/" \ 
              -e "GCSOPTIONS=-d" \ 
              -e "CRON_SCHEDULE=0 3 * * *" \ 
              -e "TZ=America/Montreal" \ 
              vinid223/gcloud-storage-docker 
```

## How to get your service account key file

1. Go to https://console.cloud.google.com/iam-admin/serviceaccounts and create a service account
   (or pick an existing one).
2. Grant it access to your bucket: `Storage Object Admin` on the bucket covers everything rsync
   needs, including the deletions `-d` performs. Without `-d`, `Storage Object User` is enough.
3. Open the service account, go to the `Keys` tab, then `ADD KEY` -> `Create new key` -> `JSON`,
   and download the file.
4. Mount that file into the container and point `SERVICE_ACCOUNT_FILE` at the path inside the
   container, as in the example above. Mounting it read-only (`:ro`) is recommended.

The key file is read at backup time to mint an access token; nothing is written to the container.
The startup log prints which service account is in use so you can confirm the identity.

## Backup options

`GCSOPTIONS` is passed to `gcloud storage rsync`. The command already runs recursively and in
parallel, so the useful additions are:

| Option | Effect |
| --- | --- |
| `--delete-unmatched-destination-objects` (or `-d`) | delete objects in the bucket that no longer exist locally |
| `--dry-run` (or `-n`) | print what would be copied without copying it |
| `--continue-on-error` (or `-C`) | keep going after an individual failure |
| `--exclude REGEX` (or `-x REGEX`) | skip paths matching the regex |
| `--ignore-symlinks` (or `-e`) | do not follow symlinks |

The short forms are the gsutil flags used by 1.x: they are still accepted and translated, so an
existing `GCSOPTIONS` does not need to be rewritten. `-r`, `-R` and `-m` are ignored because
`gcloud storage rsync` is already recursive and parallel. Any other value is passed through
untouched, so any `gcloud storage rsync` flag can be used directly.

## Migrating from 1.x

Version 2.0 backs up with `gcloud storage`, the tool Google recommends, because **gsutil is removed
from the Google Cloud CLI after March 2027**. The catch is authentication: `gcloud storage` uses the
JSON API, and HMAC keys can only sign XML API requests. There is no way to keep using HMAC keys with
it, so the credentials have to change.

| 1.x | 2.0 |
| --- | --- |
| `ACCESS_KEY` + `SECRET_KEY` (HMAC) | `SERVICE_ACCOUNT_FILE` pointing at a mounted JSON key |
| `BOTO_FILE` (HMAC in a boto file) | `SERVICE_ACCOUNT_FILE` pointing at a mounted JSON key |
| `gsutil -m rsync -r` | `gcloud storage rsync --recursive` |

Everything else is unchanged: `/data`, `GCSPATH`, `GCSOPTIONS`, `CRON_SCHEDULE`, `TZ` and the
`setup` / `backup` commands all behave the same way.

Steps:

1. Create a service account and download a JSON key, as described above. The HMAC keys you use
   today already belong to a service account, which you can reuse - the console shows which one
   under `Service account HMAC` in the
   [interoperability settings](https://console.cloud.google.com/storage/settings;tab=interoperability).
2. Mount the key file and replace `ACCESS_KEY` / `SECRET_KEY` (or `BOTO_FILE`) with
   `SERVICE_ACCOUNT_FILE`.
3. Optionally check the result before the first scheduled run:
   `docker exec <container> sh /opt/run.sh backup` and look at `/var/log/cron.log`.

If any of the removed variables are still set, the container stops at startup with these
instructions rather than running a backup that cannot authenticate.

Staying on 1.x is also an option: the `V1.3` tag keeps working with HMAC keys, and gsutil itself
keeps working until Google removes it in March 2027.

## Inspiration
https://github.com/joch/docker-s3backup
