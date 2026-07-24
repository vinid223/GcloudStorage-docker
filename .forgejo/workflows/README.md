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

All pushes go to the Forgejo container registry only. **Docker Hub is never
published automatically** — see `dockerhub.yml` below.

This collapses the old GitLab `build` / `deploy_tag` / `deploy_latest` /
`deploy_schedule_tag` jobs into one build with conditional publish steps.

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
  - `RELEASE_TOKEN` (optional) — PAT with repo write, used for creating the tag/release in `dockerhub.yml`. Falls back to the automatic `GITHUB_TOKEN`, which normally works for the repo API.
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
