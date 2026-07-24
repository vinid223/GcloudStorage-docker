# CI/CD — Forgejo Actions

This project's pipeline runs on **Forgejo Actions** (migrated from GitLab CI).
Two workflows: `docker.yml` (automatic build) and `dockerhub.yml` (manual
Docker Hub release).

## `docker.yml` — build & publish to the Forgejo registry

Triggers: `pull_request` → `master`, `push` → `master` and tags (`*`),
and `workflow_dispatch` (with a `custom_tag` input).

Single `build` job, running in the **`docker:cli`** container:

| Event | Behaviour |
|-------|-----------|
| `pull_request` | Build + push `:pr-<number>` (throwaway tag for testing the PR image). |
| `push` to `master` | Build + push `:<sha>`. |
| git tag | Build + push `:<tag>` and `:latest`. |
| manual (`workflow_dispatch`) | Build + push `:<custom_tag>`. |

All pushes go to the Forgejo container registry only. **Docker Hub is never
published automatically** — see `dockerhub.yml` below.

This collapses the old GitLab `build` / `deploy_tag` / `deploy_latest` /
`deploy_schedule_tag` jobs into one build with conditional publish steps.

## `dockerhub.yml` — manual Docker Hub release

Trigger: `workflow_dispatch` **only**. Run it from the Actions tab with two
inputs:

| Input | Meaning | Example |
|-------|---------|---------|
| `source` | Image already in the Forgejo registry to publish | `v1.3.0`, a commit sha, or `latest` |
| `tags` | Docker Hub tags to create, comma-separated | `1.3.0,latest` |

The job pulls `<registry>/<repo>:<source>`, retags it, and pushes each tag to
`vinid223/gcloud-storage-backup`. It does **not** rebuild — Docker Hub gets the
byte-identical image `docker.yml` built and Trivy scanned. It fails fast with a
clear error if `source` was never pushed to the Forgejo registry.

### Runner requirements
- **No buildx/dind.** The Forgejo runner has no in-job Docker CLI, but the host
  Docker socket is **auto-mounted** into job containers. The job uses the
  `docker:cli` image and the plain `docker` client against that daemon.
- Node is `apk add`-ed first because Forgejo runs JS actions (`checkout`) with
  node inside the container.

## Required secrets / variables
- Secrets:
  - `REGISTRY_TOKEN` (**required**) — a Forgejo **Personal Access Token** with the `write:package` scope, used to log in to the Forgejo container registry. Create it under *Settings → Applications → Access Tokens*, then add it as a repository (or org) secret.
  - `REGISTRY_USERNAME` (optional) — the user that owns `REGISTRY_TOKEN`. Defaults to `github.repository_owner` (`vinid223`); only set it if the PAT belongs to a different account.
  - `DOCKER_HUB_USERNAME`, `DOCKER_HUB_PASSWORD` — Docker Hub (an access token is recommended over a password). Used by `dockerhub.yml` only.
- Variables: `REGISTRY` (defaults to `forge.vinid223.ca`).

> **Why not `GITHUB_TOKEN`?** Forgejo's automatic per-run token **cannot** authenticate against the package registry — `docker login`/`docker push` fails with `unauthorized: reqPackageAccess` no matter what `permissions:` the workflow declares ([forgejo/forgejo#3571](https://codeberg.org/forgejo/forgejo/issues/3571), [#6904](https://codeberg.org/forgejo/forgejo/issues/6904)). A PAT is the supported workaround until that feature lands.

## Optimizations & conventions
- **Concurrency:** a newer push to a ref cancels the in-progress run (tags are unique, so releases are never cancelled).
- **Docker:** built with `DOCKER_BUILDKIT=1`; the host daemon keeps a local layer cache across runs.
- **Image scanning:** the built image is scanned with **Trivy** (`HIGH,CRITICAL`, `--ignore-unfixed`), currently **non-blocking** (`--exit-code 0`) — flip to `1` to fail on findings.
- **Action versions:** `actions/checkout@v6` (latest). Latest majors work on this instance (except `actions/upload-artifact`, which this workflow doesn't use).

## Run locally
```bash
docker build -t gcloud-storage-backup .
```
