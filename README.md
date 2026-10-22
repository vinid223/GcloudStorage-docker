# gcloud-storage-docker

Note : This repository is maintained on a private Forgejo server (CI/CD via Forgejo Actions — see [`.forgejo/workflows/README.md`](.forgejo/workflows/README.md)) and is replicated in realtime on github.

Github repository : https://github.com/vinid223/GcloudStorage-docker
Docker Hub : https://hub.docker.com/r/vinid223/gcloud-storage-backup

gcloud-storage-docker is a Docker container which backs up one or more folders to Google Cloud Storage using the `gcloud storage` tool.

> **Upgrading from 1.x?** Version 2.0 replaces gsutil with `gcloud storage` and no longer accepts
> HMAC keys. `ACCESS_KEY`, `SECRET_KEY` and `BOTO_FILE` are gone; you now mount a service account
> JSON key file instead. See [Migrating from 1.x](#migrating-from-1x). The old configuration is
> kept for reference under [Deprecated: 1.x configuration](#deprecated-1x-configuration).

## Configuration (2.x)

To tell gcloud-storage-docker what to back up, mount your desired volumes under the `/data` directory.

gcloud-storage-docker is configured by setting the following environment variables during
the launch of the container.

### Required

| Variable | Description |
| --- | --- |
| `SERVICE_ACCOUNT_FILE` | Path, inside the container, to a mounted service account JSON key file. See [How to get your service account key file](#how-to-get-your-service-account-key-file). |
| `GCSPATH` | Your GCS bucket and path (ex: `gs://personal-backup-bucket/`). |

The container also needs the key file itself mounted (read-only is recommended), and at least one
folder mounted under `/data`.

### Optional

| Variable | Default | Description |
| --- | --- | --- |
| `GCSOPTIONS` | *(none)* | Extra parameters for `gcloud storage rsync` (ex: `-d` to make the bucket an exact copy of the local files, deleting objects that no longer exist locally). See [Backup options](#backup-options). |
| `PROJECT_ID` | *(none)* | GCP project, if your bucket needs one to be set. |
| `CRON_SCHEDULE` | `0 * * * *` | When to run the backup, in standard CRON notation (every hour by default). |
| `TZ` | `UTC` | Zoneinfo name (ex: `America/Montreal`) used for both the schedule and the log timestamps. An unknown name falls back to UTC and logs a warning at startup. |
| `RUN_ON_STARTUP` | `false` | Set to `true` to run one backup as soon as the container starts, instead of waiting up to a whole schedule interval to find out whether the configuration works. |
| `LOG_MAX_BYTES` | `10485760` (10 MB) | The backup log (`/var/log/cron.log`) is trimmed to its most recent half once it grows past this, so an hourly backup cannot fill the container's disk over months. Set `0` to never trim. |
| `CLOUDSDK_*` | *(none)* | Any Google Cloud CLI setting (endpoint overrides, proxy, ...) set on the container is carried over to the scheduled backups. |

A `CRON_SCHEDULE` that is neither five fields nor an `@macro` (`@daily`, `@hourly`, ...) is rejected
at startup rather than accepted and never fired.

### Removed in 2.0

`ACCESS_KEY`, `SECRET_KEY` and `BOTO_FILE` are no longer supported. If any of them is still set, the
container stops at startup with migration instructions. See [Migrating from 1.x](#migrating-from-1x).

## The settings menu

Every container prints a settings reference when it starts — before it validates
anything, so a container that refuses to start still shows what it was looking
for. It lists every variable, its accepted values and its default, plus the value
that container actually resolved (`now:`), the `GCSOPTIONS` values, and the
commands. It is the first thing in `docker logs`.

To read it without starting anything:

```
docker run --rm vinid223/gcloud-storage-backup help
```

Scheduled backups do not repeat it, so it does not bury the transfer output in
the log.

## Checking on it

The container's stdout is the backup log, so `docker logs -f <container>` follows it live.

The image also declares a **healthcheck** that reports the outcome of the last completed backup, so
a backup that keeps failing shows up in `docker ps` as `unhealthy` instead of only in the log:

```
docker inspect --format '{{.State.Health.Status}}: {{(index .State.Health.Log 0).Output}}' <container>
```

A container that has not completed a backup yet is healthy. Use `docker run --no-healthcheck` to
turn it off.

To run a backup immediately, outside the schedule:

```
docker exec <container> sh /opt/run.sh backup
```

It exits 0 on success and non-zero if the sync failed, so it can be used from a wrapper script or a
monitoring check. Add `-e GCSOPTIONS=-n` to the `docker exec` for a dry run without changing the
container's own configuration.

> Note: `gcloud auth list` inside the container reports *no credentialed accounts* even when
> everything is working. The CLI is pointed straight at the mounted key file rather than at a stored
> login, so an empty `auth list` is expected and is not a sign that authentication is broken. The
> startup log prints the service account actually in use.

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
              vinid223/gcloud-storage-backup
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

`--exclude` takes a regular expression, and it reaches gcloud exactly as written - it is not expanded
against the files in the container. A pattern containing a space has to be quoted *inside* the
variable:

```
-e "GCSOPTIONS=-x 'my notes'"          # one pattern, with a space in it
-e "GCSOPTIONS=-x .*\.log"             # backslashes are kept as-is
```

An unbalanced quote is reported in the log and the backup exits without touching the bucket, rather
than running a half-parsed command.

### Symlinks

`gcloud storage rsync` ignores symlinks by default, where gsutil followed them, so the image passes
`--no-ignore-symlinks` to keep the 1.x behaviour. Pass `-e` (or `--ignore-symlinks`) in `GCSOPTIONS`
to skip them instead; the default is then left out rather than being contradicted.

One difference worth knowing if you have symlinks under `/data`: gsutil never followed *directory*
symlinks, regardless of `-e`, while `gcloud storage` may descend into them. If `/data` contains a
symlink to a directory, check the first run (`GCSOPTIONS=-n` shows what would be copied without
copying it) rather than assuming the contents are identical to 1.x.

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
3. Check the result before the first scheduled run, either with
   `RUN_ON_STARTUP=true` on the container, or with
   `docker exec <container> sh /opt/run.sh backup` followed by `docker logs <container>`.
   Adding `GCSOPTIONS=-n` for that first run makes it a dry run.

If any of the removed variables are still set, the container stops at startup with these
instructions rather than running a backup that cannot authenticate.

Staying on 1.x is also an option: `vinid223/gcloud-storage-backup:V1.3` keeps working with HMAC keys,
and gsutil itself keeps working until Google removes it in March 2027. Pin that tag explicitly:
`latest` now points at 2.x.

## Deprecated: 1.x configuration

> **Deprecated.** This section only applies to `vinid223/gcloud-storage-backup:V1.3` and earlier,
> which back up with gsutil. It is no longer maintained and stops working when Google removes gsutil
> from the Google Cloud CLI after March 2027. A 2.x container given these variables refuses to
> start. Use it only until you have [migrated](#migrating-from-1x).

1.x was configured with these environment variables:

- `ACCESS_KEY` - your GCP HMAC access key for a service account. The string should not contain the
  character `|`.
- `SECRET_KEY` - your GCP HMAC secret key for a service account. The string should not contain the
  character `|`.
- `BOTO_FILE` - path to a mounted boto configuration file containing the access key, the secret key
  and your own settings. When set, `ACCESS_KEY` and `SECRET_KEY` are ignored.
- `GCSPATH`, `GCSOPTIONS` (passed to `gsutil -m rsync -r`) and `CRON_SCHEDULE`, as in 2.x.

To get the HMAC keys:

1. Go to the GCS Settings page, on the
   [Interoperability tab](https://console.cloud.google.com/storage/settings;tab=interoperability).
2. Under `Service account HMAC`, click on a service account if one exists or create a new one by
   clicking on `CREATE A KEY FOR ANOTHER SERVICE ACCOUNT`.
3. Click on `CREATE A KEY` to get the Access Key and Secret Key.

Example invocation with keys in environment variables:

```
docker run -d -v /home/user/Documents:/data/documents \
              -v /home/user/Photos:/data/photos \
              -e "ACCESS_KEY=YOURACCESSKEY" \
              -e "SECRET_KEY=YOURSECRETKEY" \
              -e "GCSPATH=gs://yourgsbucket/" \
              -e "GCSOPTIONS=-d" \
              -e "CRON_SCHEDULE=0 3 * * *" \
              vinid223/gcloud-storage-backup:V1.3
```

Or with a boto file, mounted into the container and pointed at by `BOTO_FILE`:

```
[Credentials]
gs_access_key_id=YOURACCESSKEY
gs_secret_access_key=YOURSECRETKEY

[Boto]

[GoogleCompute]

[GSUtil]
content_language = en
default_api_version = 2

[OAuth2]
```

```
docker run -d -v /home/user/Documents:/data/documents \
              -v /home/user/Photos:/data/photos \
              -v /path/to/local/boto/file:/tmp/boto.tmp \
              -e "BOTO_FILE=/tmp/boto.tmp" \
              -e "GCSPATH=gs://yourgsbucket/" \
              -e "GCSOPTIONS=-d" \
              -e "CRON_SCHEDULE=0 3 * * *" \
              vinid223/gcloud-storage-backup:V1.3
```

## Development

```
docker build -t gcloud-storage-backup .
```

`tests/` holds two suites - a fast one that asserts the exact command the image builds, and an
end-to-end one that runs real transfers against a local Google Cloud Storage stand-in. See
[`tests/README.md`](tests/README.md). CI runs the fast one on every push, plus `shellcheck` and
`hadolint`; the end-to-end suite is meant to be run locally before a release.

## AI disclaimer

AI tools are used to help maintain this project, including writing code, tests and documentation.
Every change is reviewed by the maintainer before it is committed and released.

## Inspiration
https://github.com/joch/docker-s3backup
