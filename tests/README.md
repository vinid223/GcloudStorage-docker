# Test suite

Two suites, neither of which needs a GCP project, a bucket or real credentials:

| | `smoke.sh` | `run-tests.sh` |
| --- | --- | --- |
| Asserts | the exact command `run.sh` builds, and the decisions around it | that files really transfer, by reading the bucket back |
| `gcloud` | a stub that prints its argv | the real CLI against fake-gcs-server |
| Bind mounts | none | `/data`, the bucket seed, the secrets |
| Runs in CI | **yes**, on every push | no ([why](#why-ci-runs-only-the-smoke-suite)) |
| Takes | ~1 min | ~5 min (~1 min with `SKIP_SLOW=1`) |
| Needs | `docker` | `docker`, `docker compose`, `bash`, `openssl` |

Run both before releasing:

```
IMAGE=$(docker build -q .) tests/smoke.sh
tests/run-tests.sh
```

The rest of this document describes `run-tests.sh`; `smoke.sh` is summarised
[at the end](#smokesh--fast-checks-without-storage).

## Running it

```
./tests/run-tests.sh
```

That is all: the script builds the image, starts the stack, runs every case,
prints a `PASS`/`FAIL` line per case with a summary, and tears everything down
again (also on failure or `Ctrl-C`). It exits non-zero if any case failed, and
is safe to re-run: leftovers from an interrupted run are removed first.

Requirements: Docker (Desktop is fine), `docker compose`, `bash` and `openssl`.

38 cases, about 5 minutes, a third of it the two scheduling cases that wait for
cron to fire. Options:

| | |
| --- | --- |
| `./tests/run-tests.sh transfer -d` | run only cases whose name contains `transfer` or `-d` |
| `SKIP_SLOW=1 ./tests/run-tests.sh` | skip the two cases that wait for cron (~4 min faster) |
| `KEEP_WORK=1 ./tests/run-tests.sh` | keep the work directory instead of deleting it |
| `TEST_WORK_DIR=/path ./tests/run-tests.sh` | put the work directory somewhere specific |

Only failing cases print details (the relevant `/var/log/cron.log`, startup log
or bucket listing), so a passing run stays short.

**One run at a time**, unless you separate them explicitly. A run owns a compose
project (containers, network, built images) and a work directory, and clears both
on the way in so an interrupted run cannot poison the next one - which also means
two default runs in parallel tear down each other's containers and fail in
confusing ways. To run two at once, override both:

```
TEST_PROJECT=mine TEST_WORK_DIR=/tmp/mine ./tests/run-tests.sh
```

## Layout

| Path | |
| --- | --- |
| `docker-compose.yml` | the stack: `fakegcs` (bucket service), `backup` (image under test, `build: ..`), `client` (idle helper used to run `gcloud storage ls` for assertions) |
| `run-tests.sh` | the runner and all cases |
| `fixtures/data/` | the seed tree that gets backed up: `hello.txt`, `logs/app.log`, `notes/readme.md`, `notes/deep/nested.txt`, `skipme/ignored.txt` |

Cases run `sh /opt/run.sh backup` either one-shot in a fresh container (`docker
compose run`) or through `docker exec` into a container started with the real
`setup` entrypoint, depending on whether the case needs the crontab, the env file
or the scheduler.

The runner creates a work directory outside the repo (`$TMPDIR/gcsbackup-tests`
by default) and exports `TEST_WORK_DIR`, which the compose file binds into the
containers:

* `$TEST_WORK_DIR/data` -> `/data` in the backup container, a fresh copy of
  `fixtures/data` before each transfer case;
* `$TEST_WORK_DIR/buckets` -> `/data` in fake-gcs-server, one subdirectory per
  bucket (`buckets/testbucket` is `gs://testbucket`), used as the seed;
* `$TEST_WORK_DIR/secrets` -> `/secrets` in the backup container, holding the
  generated fake key files.

All images are pinned to `linux/amd64` so behaviour is identical on an arm64
host.

### How gcloud is pointed at the fake server

Set on both the `backup` and `client` services:

```
CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE=http://fakegcs:4443/storage/v1/
CLOUDSDK_AUTH_DISABLE_CREDENTIALS=true
CLOUDSDK_CORE_PROJECT=test
```

`run.sh` copies every `CLOUDSDK_*` variable into the env file it writes at setup
(`/tmp/gcsbackup.env`), which the backup path sources, so scheduled runs reach the
fake server too. That is what the "env file carries the settings" and "backup
works in crond's environment" cases check.

### The fake service account key

`run-tests.sh` generates `secrets/sa.json` at startup: a real 2048-bit RSA key
from `openssl genpkey`, wrapped in a service account JSON document
(`type`, `project_id`, `private_key_id`, `private_key`, `client_email`,
`client_id`, `token_uri`). It is syntactically valid, so `run.sh`'s validation
accepts it and gcloud will sign a JWT with it, but it belongs to no real
account. No secret is committed to the repository.

Most cases keep `CLOUDSDK_AUTH_DISABLE_CREDENTIALS=true`, so the transfer
behaviour can be tested without any token at all. One case unsets it to
exercise the real credential path - see below.

## What each case covers

### Image

| Case | Asserts |
| --- | --- |
| gsutil is absent | no `gsutil` on `PATH`, no `/google-cloud-sdk/bin/gsutil`, no `platform/gsutil` component directory |
| gcloud is on PATH | `command -v gcloud` resolves to `/google-cloud-sdk/bin/gcloud` and `gcloud version` runs |
| python3 present, bundled one dropped | `/usr/bin/python3` exists and executes (the key file validation needs it), and the CLI's own `platform/bundledpythonunix` is not in the image |
| declares a HEALTHCHECK | the built image's `Config.Healthcheck` runs `/opt/run.sh healthcheck` |

### Configuration validation (`setup`)

| Case | Asserts |
| --- | --- |
| missing `SERVICE_ACCOUNT_FILE` exits 1 | exit 1 and `SERVICE_ACCOUNT_FILE must be set ...` |
| key file path not found exits 1 | exit 1 and `... not found. Mount the service account key file ...` |
| file is not a service account key exits 1 | a valid JSON file without the key fields is rejected: exit 1 and `... is not a service account JSON key file ...` |
| missing `GCSPATH` exits non-zero | non-zero exit and `GCSPATH required` |
| `ACCESS_KEY` without key file exits 1 | exit 1, the 2.0 migration instructions, including the `SERVICE_ACCOUNT_FILE=/path/to/key.json` line |
| `ACCESS_KEY` with key file warns and starts | the `WARNING: ACCESS_KEY, SECRET_KEY and BOTO_FILE are ignored` line, and the container stays up with the scheduler running |
| `CRON_SCHEDULE` field count is validated | `CRON_SCHEDULE='0 *'` exits 1 reporting `Got 2 field(s)` - the number of fields, not the number of files a `*` would expand to |
| `CRON_SCHEDULE` @macro is accepted | `@daily` passes validation and lands in the crontab as `@daily sh /opt/run.sh backup` |
| default `CRON_SCHEDULE` starts scheduler | with no `CRON_SCHEDULE` at all - what a plain `docker run` uses - setup reaches `Adding CRON schedule: 0 * * * * (UTC)` and writes that crontab |

### Transfer behaviour (`backup`)

Each case resets `/data` to the fixture tree and resets the bucket, then runs
`sh /opt/run.sh backup` - the exact command cron runs - and asserts on the
resulting bucket contents (via `gcloud storage ls`) and on `/var/log/cron.log`.

| Case | Asserts |
| --- | --- |
| initial upload of nested directories | all five fixture objects land in the bucket with their nested names, exit 0, no failure logged |
| re-run copies nothing | a second run on an unchanged tree logs no `Copying file://` and no `Removing gs://`, and leaves the bucket identical |
| new local file is picked up | a file created between two runs is copied, and only that one |
| `GCSOPTIONS=-d` deletes orphan object | `-d` becomes `--delete-unmatched-destination-objects`, a seeded object with no local counterpart is removed from the bucket (see the delete quirk below) |
| `GCSOPTIONS=-n` changes nothing | `-n` becomes `--dry-run`, exit 0, bucket unchanged |
| `GCSOPTIONS=-x` excludes matching paths | `-x skipme` becomes `--exclude skipme` and `skipme/ignored.txt` is not uploaded |
| `-x` accepts a quoted pattern | `GCSOPTIONS="-x 'my notes'"` keeps the pattern with the space in it as one argument, and `my notes/secret.txt` is not uploaded |
| legacy `-d -m -r` behaves like `-d` | the generated command is character-for-character the one `-d` alone produces (`-m`/`-r` are dropped), and the orphan object is still deleted |
| raw gcloud flag is passed through | `GCSOPTIONS=--exclude=logs` reaches gcloud verbatim and `logs/app.log` is not uploaded |
| full translation table | `-d -n -C -e -m -r -R -x skipme --verbosity=warning` produces exactly `--recursive --delete-unmatched-destination-objects --dry-run --continue-on-error --ignore-symlinks --exclude skipme --verbosity=warning` - note `-e` settles the symlink question, so `--no-ignore-symlinks` is not added on top of it |
| unbalanced quote is rejected | `GCSOPTIONS="-x 'unclosed"` exits 2, logs `GCSOPTIONS could not be parsed`, never invokes rsync and leaves the bucket alone |

### Runtime

| Case | Asserts |
| --- | --- |
| failing sync logged and propagated | a `GCSPATH` pointing at a nonexistent bucket logs `Sync FAILED with exit status`, logs the 404, and `run.sh` exits 1 so cron and the healthcheck can see it |
| live lock prevents concurrent run | with a lock file holding the pid of a running process, `run.sh` exits 1, logs `... detected, exiting! Already running?`, never invokes rsync, and the bucket is untouched |
| stale lock is taken over | a lock file holding a dead pid is reported stale, taken over, and the backup runs normally |
| key file is used to mint a token | with `CLOUDSDK_AUTH_DISABLE_CREDENTIALS` unset, gcloud loads the mounted key through `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE` and the error names the fake account (`backup-sa@fake-test-project.iam.gserviceaccount.com`), proving the credential path works; the token request itself is expected to fail |
| log is trimmed past `LOG_MAX_BYTES` | a 40 KB log with `LOG_MAX_BYTES=4096` is trimmed, the trim is noted in the log, and the backup still succeeds |
| healthcheck reports a good backup | `run.sh healthcheck` exits 0 with `no backup has completed yet` before the first run, and 0 with `last backup succeeded` after one |
| healthcheck reports a failed backup | after a failing backup, `run.sh healthcheck` exits 1 with `last backup FAILED with exit status 1` |
| crontab holds schedule and command | the crontab line is exactly `<schedule> sh /opt/run.sh backup` |
| env file carries the settings | `/tmp/gcsbackup.env` holds `GCSPATH`, `GCSOPTIONS`, `TZ`, `SERVICE_ACCOUNT_FILE`, `PROJECT_ID` and every `CLOUDSDK_*` variable (the endpoint override, `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE`, `CLOUDSDK_CORE_PROJECT`, `CLOUDSDK_PYTHON`, `CLOUDSDK_CONFIG`), because crond hands its jobs a minimal environment |
| hand-run `run.sh backup` works | the documented `docker exec <container> sh /opt/run.sh backup` exits 0 and really uploads |
| backup works in crond's environment | the same hand-run, but with the container's own variables stripped (`env -i` with just `HOME`, `SHELL`, `PATH`, `USER`, `LOGNAME`) - what crond actually gives the job. It has to rebuild everything from the env file: same command line, no `Unknown timezone`, exit 0, data uploaded. This is the scheduled path without the wait |
| `RUN_ON_STARTUP` backs up immediately | with `RUN_ON_STARTUP=true`, setup logs `Initial backup finished with exit status 0` and the data is in the bucket before the first scheduled run |

### Scheduling (the slow pair)

| Case | Asserts |
| --- | --- |
| `* * * * *` fires a backup | within ~100 s a scheduled run appears in `/var/log/cron.log` and in `docker logs`, and the data really arrived in the bucket |
| `TZ` applies to cron and timestamps | with `TZ=Asia/Tokyo` and a schedule set to "two minutes from now, Tokyo time" (an hour field that never equals the current UTC hour), the job fires within ~170 s and the log timestamps read `JST` - a UTC-evaluating cron could not have fired it |

## Known fake-server quirks

These are limitations of fake-gcs-server, not bugs in the image. Do not chase
them.

* **Deletes look like failures.** `gcloud storage rm`, and the delete phase of
  `gcloud storage rsync -d`, both log
  `ERROR: Task '...' failed: 'NoneType' object has no attribute 'items'` and
  make rsync exit 1 - even though the object *is* deleted. Real GCS answers a
  delete with `204 No Content`; the fake server's response body is what gcloud
  chokes on. Uploads and listings are unaffected and exit 0.
  Consequence for the tests: the `-d` cases assert on the resulting bucket
  contents, and treat `Sync FAILED with exit status 1` as an expected quirk
  (they do check that the failure is that specific error and nothing else).
* **The data directory is a seed, not a mirror.** fake-gcs-server reads
  `$TEST_WORK_DIR/buckets` once at startup and then keeps all state in memory,
  so uploaded objects never show up on the host and deleted ones stay there.
  Never assert by listing the host directory - always use `gcloud storage ls`.
  To reset a bucket, the runner rewrites the seed and re-creates the container
  (`reset_bucket`).
* **An empty bucket makes `ls` exit 1** with `One or more URLs matched no
  objects.`, which the runner treats as "no objects" rather than an error.

## `smoke.sh` — fast checks without storage

```
tests/smoke.sh                    # build the image, then run everything
IMAGE=my-image tests/smoke.sh     # test an image that is already built
tests/smoke.sh translation lock   # only cases whose name matches an argument
```

44 cases, about a minute, no bucket involved. `gcloud` is replaced by a stub that
prints `ARGV: <what it was called with>`, so a case can assert the generated
command exactly instead of inferring it from a transfer — and can force a failing
exit status on demand. It covers the same ground as the sections above, plus the
things that are awkward to provoke end to end:

- patterns that must survive verbatim: containing a space, containing a
  backslash (`-x .*\.log`), and `*` — none of which may be expanded against the
  working directory;
- **flag existence**: one case greps `gcloud storage rsync --help` for every long
  flag the translator can emit, so bumping `GCLOUD_VERSION` to a CLI that renamed
  or dropped one fails the build rather than the next backup;
- the lock being released when a run is **killed mid-sync**, and an empty lock
  file being taken over;
- the **settings menu**: printed at startup on a good start and on every failing
  one (missing configuration, legacy credentials, a malformed schedule), showing
  the effective values including a timezone that fell back to UTC; available as
  `help`/`--help`/`-h`; printed with the error for an unsupported command; and
  *not* printed by a backup or by the healthcheck, whose output `docker inspect`
  shows;
- `LOG_MAX_BYTES=0` disabling trimming;
- an explicit variable beating the env file, so
  `docker exec -e GCSOPTIONS=-n ... run.sh backup` works for a one-off dry run;
- `.pyc` caches being shipped in the image (without them every run recompiles the
  CLI into the container's writable layer) and no bash being required.

### Why CI runs only the smoke suite

The Forgejo runner executes each job inside a container and hands it the **host**
Docker socket. Bind mounts are resolved by that host daemon, so a directory
created inside the job container — which is where `$TEST_WORK_DIR` would live —
does not exist from the daemon's point of view, and the stack would come up with
empty `/data`, no bucket seed and no key file. `smoke.sh` creates every fixture
*inside* the container it starts, which is why it runs anywhere `docker` does.

## Poking at the stack by hand

```
export TEST_WORK_DIR=/tmp/gcsbackup-work
mkdir -p "$TEST_WORK_DIR"/{data,buckets/testbucket,secrets}
cp -R tests/fixtures/data/. "$TEST_WORK_DIR/data/"
# put a fake key at "$TEST_WORK_DIR/secrets/sa.json" - or run
# KEEP_WORK=1 ./tests/run-tests.sh once and reuse the one it generated

docker compose -f tests/docker-compose.yml up -d fakegcs client
docker compose -f tests/docker-compose.yml run --rm --entrypoint sh backup \
    -c 'sh /opt/run.sh backup; cat /var/log/cron.log'
docker compose -f tests/docker-compose.yml exec client gcloud storage ls -r 'gs://testbucket/**'
docker compose -f tests/docker-compose.yml down
```
