# CI/CD — Forgejo Actions

This project's pipeline runs on **Forgejo Actions** (migrated from GitLab CI).
Two workflows: `docker.yml` (automatic build) and `dockerhub.yml` (manual
Docker Hub release).

## `docker.yml` — build & publish to the Forgejo registry

Triggers: `pull_request` → `master`, `push` → `master` and tags (`*`),
and `workflow_dispatch` (with a `custom_tag` input).

Two jobs, both running in the **`docker:cli`** container:

1. **`lint`** — `shellcheck` on `run.sh`, `tests/smoke.sh` and
   `tests/run-tests.sh`, plus `hadolint` on the `Dockerfile`. Seconds, and it
   gates the build so an obvious mistake doesn't wait on a ~150 MB download.
2. **`build`** — build, **test**, scan, publish.

Both linters read their input from **stdin** (`docker run -i ... - < file`)
rather than from a bind mount. That is not a style choice: the job runs in a
container that drives the *host* Docker daemon through a mounted socket, so a
path inside the job container means nothing to that daemon and
`-v "$PWD:/mnt"` would hand the linter an empty directory. The same constraint
is why `tests/run-tests.sh` cannot run here (see below).

The `build` job publishes as follows:

| Event | Behaviour |
|-------|-----------|
| `pull_request` | Build + push `:pr-<number>` (throwaway tag for testing the PR image). |
| `push` to `master` | Build + push `:<sha>` **and `:latest`**. |
| git tag | Build + push `:<tag>` (does not touch `:latest`). |
| manual (`workflow_dispatch`) | Build + push `:<custom_tag>`. |

`:latest` is owned by master: every push to master moves it. That matters
because `dockerhub.yml` takes no inputs and *always* publishes `:latest`, so
master HEAD has to be what `:latest` points at. Tag builds deliberately leave
`:latest` alone — release tags are created by `dockerhub.yml` *after* it has
already shipped the current `:latest`, so re-pushing `latest` from a tag build
would be redundant at best and (for a tag cut on an older commit) wrong.

Every build stamps `org.opencontainers.image.revision=<sha>` into the image;
`dockerhub.yml` reads it back to find the commit that `:latest` was built from.

The tag list for an event is computed in one step (`Decide which tags to
publish`) and consumed by whichever publish path applies, so the two cannot drift
apart.

All pushes go to the Forgejo container registry only. **Docker Hub is never
published automatically** — see `dockerhub.yml` below.

This collapses the old GitLab `build` / `deploy_tag` / `deploy_latest` /
`deploy_schedule_tag` jobs into one build with conditional publish steps.

### Tests

After the build and **before anything is published**, the job runs
`tests/smoke.sh` against the image it just built. Those cases replace `gcloud`
with a stub that prints the exact argv it was handed, so the `GCSOPTIONS`
translation table, the configuration checks, the lock, the log trimming, the exit
statuses and the healthcheck are all asserted directly. One case greps
`gcloud storage rsync --help` for every flag the translator can emit, so bumping
`GCLOUD_VERSION` to a CLI that renamed or dropped a flag fails the build instead
of failing somebody's backup schedule.

`tests/run-tests.sh` — the end-to-end suite that runs real transfers against
fake-gcs-server — is **not** run in CI. It bind-mounts host directories for
`/data`, the bucket seed and the secrets, which a job container driving the host
daemon through a socket cannot do. Run it locally before releasing; see
[`tests/README.md`](../../tests/README.md).

### Publishing arm64

The `Dockerfile` handles `TARGETARCH` and builds for arm64, but CI publishes
**amd64 only** by default: the runner is amd64 and a plain `docker build` produces
a single-architecture image.

To publish more, set the repository variable `PLATFORMS`, e.g.
`linux/amd64,linux/arm64`. The job then switches to a `docker buildx` path that
builds and pushes a multi-architecture manifest in one step (a multi-arch image
cannot be loaded into the local image store, so it cannot be built first and
retagged afterwards).

Before setting it:

- The runner needs **binfmt/QEMU** for the foreign architecture. The workflow
  installs it with `docker run --privileged --rm tonistiigi/binfmt --install all`,
  which requires the daemon to allow privileged containers.
- Every architecture is **rebuilt** (amd64 comes from the layer cache; the rest
  do not), and the arm64 build runs under emulation. The gcloud CLI's
  `install.sh` byte-compiles the whole CLI, which is slow enough emulated that
  `timeout-minutes: 60` on the job usually has to go up.
- Tests and the Trivy scan still run against the natively built amd64 image.


One more thing to change before arm64 reaches Docker Hub: `dockerhub.yml`
publishes with `docker pull` + `docker tag` + `docker push`, and a plain `pull`
resolves a multi-architecture manifest down to the **runner's own
architecture** — so Docker Hub would quietly keep getting amd64 only. Copying the
whole manifest instead needs `buildx`:

```sh
docker buildx imagetools create \
  -t "vinid223/gcloud-storage-backup:${version}" \
  -t "vinid223/gcloud-storage-backup:latest" \
  "${IMAGE}:latest"
```

That is left as-is for now because `PLATFORMS` defaults to amd64, where pull and
retag is correct and keeps the published image byte-identical to the one that was
tested and scanned. Note that `imagetools create` copies without pulling, so the
`org.opencontainers.image.revision` label the release step reads would have to be
fetched separately (`docker buildx imagetools inspect --raw`).

## `dockerhub.yml` — Docker Hub release + Forgejo release

Trigger: `workflow_dispatch` **only, with no inputs** — the dispatch path used
here cannot pass parameters, so everything the job needs is derived. Run it from
the Actions tab and it:

1. pulls `<registry>/<repo>:latest` — always the source, never a rebuild, so
   Docker Hub gets the byte-identical image `docker.yml` built and Trivy scanned.
   Fails fast with a clear error if `:latest` was never pushed;
2. resolves the **source commit** from the image's
   `org.opencontainers.image.revision` label (falls back to `github.sha`, with a
   warning, for images built before that label existed);
3. computes the **next version** (see below);
4. pushes `vinid223/gcloud-storage-backup:<version>` and `:latest`;
5. creates the git tag `<version>` in Forgejo on the source commit, then a
   Forgejo release for it with a changelog since the previous version tag.

Steps 4–5 are in that order on purpose: a release never exists for an image
that didn't ship.

### Version numbering

The next version is derived from the git tags — no input, no file to edit:

- the **highest existing version tag** wins, whatever its shape: `V`-prefixed or
  not, 2- or 3-part (`V1.3`, `V1.2.0`, `1.1.7`) are all normalized to
  `major.minor.patch` for comparison;
- the default bump is **minor**, and the tag created is always
  `V<major>.<minor>.<patch>` → `V1.3` yields **`V1.4.0`**;
- put `[major]`, `[minor]` or `[patch]` in the source commit's message to
  override the bump for that run (`[patch]` on top of `V1.3` → `V1.3.1`);
- no version tags at all → `V1.0.0`;
- if the computed version already exists as a tag, the run fails instead of
  overwriting it.

Change `DEFAULT_BUMP` in the workflow's `env:` to make patch (or major) the
default instead.

### Release notes

`git log --no-merges <previous version tag>..<source commit>` as a bullet list
(`- subject (sha)`), plus the published image reference and a compare link. If
there are no commits since the previous tag the release is still cut, with a
warning and a “No changes.” body. “Previous version” here is the same highest
tag the version calculation used — not `/releases/latest` — so tags that predate
Forgejo releases are handled correctly.

The tag and release calls go through the Forgejo (Gitea-compatible) API, which
is why the workflow declares `permissions: contents: write`. The automatic run
token is enough for this — only the *package registry* rejects it (see below).
Set the optional `RELEASE_TOKEN` secret (a PAT with repo write) only if your
instance forbids run tokens from creating tags/releases.

A `concurrency` group with `cancel-in-progress: false` serializes runs, since
two concurrent ones would race on the version number.

### Runner requirements
- **No dind.** The Forgejo runner has no in-job Docker CLI, but the host Docker
  socket is **auto-mounted** into job containers. The jobs use the `docker:cli`
  image and the plain `docker` client against that daemon. `docker:cli` does ship
  the `compose` and `buildx` plugins, which is what makes the optional multi-arch
  path possible.
- Because that daemon is on the host, **no job can bind-mount its own
  workspace** — paths inside the job container do not exist for the daemon. Both
  linters therefore read from stdin, and the end-to-end test suite runs locally
  rather than in CI.
- Node is `apk add`-ed first because Forgejo runs JS actions (`checkout`) with
  node inside the container.

## Required secrets / variables
- Secrets:
  - `REGISTRY_TOKEN` (**required**) — a Forgejo **Personal Access Token** with the `write:package` scope, used to log in to the Forgejo container registry. Create it under *Settings → Applications → Access Tokens*, then add it as a repository (or org) secret.
  - `REGISTRY_USERNAME` (optional) — the user that owns `REGISTRY_TOKEN`. Defaults to `github.repository_owner` (`vinid223`); only set it if the PAT belongs to a different account.
  - `DOCKER_HUB_USERNAME`, `DOCKER_HUB_PASSWORD` — Docker Hub (an access token is recommended over a password). Used by `dockerhub.yml` only.
  - `RELEASE_TOKEN` (optional) — PAT with repo write, used for creating the tag/release in `dockerhub.yml`. Falls back to the automatic `GITHUB_TOKEN`, which normally works for the repo API.
- Variables:
  - `REGISTRY` (defaults to `forge.vinid223.ca`).
  - `PLATFORMS` (defaults to `linux/amd64`) — architectures to publish. See
    [Publishing arm64](#publishing-arm64) before widening it.

> **Why not `GITHUB_TOKEN`?** Forgejo's automatic per-run token **cannot** authenticate against the package registry — `docker login`/`docker push` fails with `unauthorized: reqPackageAccess` no matter what `permissions:` the workflow declares ([forgejo/forgejo#3571](https://codeberg.org/forgejo/forgejo/issues/3571), [#6904](https://codeberg.org/forgejo/forgejo/issues/6904)). A PAT is the supported workaround until that feature lands.

## Optimizations & conventions
- **Concurrency:** a newer push to a ref cancels the in-progress run (tags are unique, so releases are never cancelled).
- **Docker:** built with `DOCKER_BUILDKIT=1`; the host daemon keeps a local layer cache across runs.
- **Linting:** `shellcheck` at `--severity=warning`, `hadolint` at
  `--failure-threshold warning`. Three hadolint rules are ignored deliberately
  (`DL3048` the legacy `AUTHOR` label, `DL3018` apk version pinning, `DL4006`
  pipefail) — the reasons are in the workflow next to the flags.
- **Image scanning:** the built image is scanned with **Trivy** (`HIGH,CRITICAL`, `--ignore-unfixed`), currently **non-blocking** (`--exit-code 0`) — flip to `1` to fail on findings.
- **Action versions:** `actions/checkout@v6` (latest). Latest majors work on this instance (except `actions/upload-artifact`, which this workflow doesn't use).

## Run locally
```bash
# build
docker build -t gcloud-storage-backup .

# the checks CI runs
docker run --rm -i koalaman/shellcheck:stable --severity=warning -s sh - < run.sh
docker run --rm -i hadolint/hadolint hadolint \
  --ignore DL3048 --ignore DL3018 --ignore DL4006 \
  --failure-threshold warning - < Dockerfile
IMAGE=gcloud-storage-backup tests/smoke.sh

# the end-to-end suite CI cannot run (real transfers, ~5 min)
tests/run-tests.sh
```
