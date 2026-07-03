# CI/CD — Forgejo Actions

This project's pipeline runs on **Forgejo Actions** (migrated from GitLab CI).
One workflow: `docker.yml`.

## `docker.yml` — build & publish the image

Triggers: `pull_request` → `master`, `push` → `master` and tags (`*`),
and `workflow_dispatch` (with a `custom_tag` input).

Single `build` job, running in the **`docker:cli`** container:

| Event | Behaviour |
|-------|-----------|
| `pull_request` | Build + push `:pr-<number>` to the Forgejo container registry (throwaway tag for testing the PR image). |
| `push` to `master` | Build + push `:<sha>` to the Forgejo container registry. |
| git tag | Build + push `:<tag>` and `:latest` to **both** the Forgejo registry and Docker Hub (`vinid223/gcloud-storage-backup`). |
| manual (`workflow_dispatch`) | Build + push `:<custom_tag>` to the registry and Docker Hub. |

This collapses the old GitLab `build` / `deploy_tag` / `deploy_latest` /
`deploy_schedule_tag` jobs into one build with conditional publish steps.

### Runner requirements
- **No buildx/dind.** The Forgejo runner has no in-job Docker CLI, but the host
  Docker socket is **auto-mounted** into job containers. The job uses the
  `docker:cli` image and the plain `docker` client against that daemon.
- Node is `apk add`-ed first because Forgejo runs JS actions (`checkout`) with
  node inside the container.

## Required secrets / variables
- Secrets: `GITHUB_TOKEN` (auto-provided, Forgejo registry — the workflow grants it `packages: write`), `DOCKER_HUB_USERNAME`, `DOCKER_HUB_PASSWORD` (Docker Hub — a Hub access token is recommended over a password; needed only for tag/manual publishes).
- Variables: `REGISTRY` (defaults to `forge.vinid223.ca`).

> **`unauthorized: reqPackageAccess`?** The Forgejo container registry rejected the login because the token lacked package write scope. The workflow-level `permissions: packages: write` block fixes this. If it persists on your Forgejo version, replace `secrets.GITHUB_TOKEN` in the Forgejo login step with a Personal Access Token (scope `write:package`) stored as a secret.

## Optimizations & conventions
- **Concurrency:** a newer push to a ref cancels the in-progress run (tags are unique, so releases are never cancelled).
- **Docker:** built with `DOCKER_BUILDKIT=1`; the host daemon keeps a local layer cache across runs.
- **Image scanning:** the built image is scanned with **Trivy** (`HIGH,CRITICAL`, `--ignore-unfixed`), currently **non-blocking** (`--exit-code 0`) — flip to `1` to fail on findings.
- **Action versions:** `actions/checkout@v6` (latest). Latest majors work on this instance (except `actions/upload-artifact`, which this workflow doesn't use).

## Run locally
```bash
docker build -t gcloud-storage-backup .
```
