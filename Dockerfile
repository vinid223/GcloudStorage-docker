# Alpine 3.24 ships Python 3.14, which the gcloud CLI supports. The CLI bundles
# its own interpreter too, but this image runs it on Alpine's (see
# CLOUDSDK_PYTHON below) and drops the bundled one, so keep the Python version in
# mind when bumping either side: an Alpine release whose python3 is newer than
# what the CLI supports breaks `install.sh`.
FROM alpine:3.24
LABEL AUTHOR="vinid223@gmail.com"

# tzdata provides /usr/share/zoneinfo so a $TZ like America/Montreal resolves;
# without it musl silently ignores named zones and everything stays on UTC.
RUN apk add --no-cache python3 curl tzdata

# Default timezone. Overriding TZ at run time shifts both the CRON_SCHEDULE and
# the log timestamps to that zone.
ENV TZ=UTC

# Put gcloud on PATH so `docker exec <container> gcloud storage ls ...` works
# when debugging. run.sh calls it by absolute path.
ENV PATH="/google-cloud-sdk/bin:$PATH" \
    CLOUDSDK_PYTHON=python3 \
    CLOUDSDK_CONFIG=/root/.config/gcloud

# Version of the Google Cloud CLI to install. Pinned (rather than the floating
# "latest" tarball) so image builds stay reproducible.
ARG GCLOUD_VERSION=590.0.0
# Populated automatically by BuildKit; the default keeps the legacy builder
# working. Google names the ARM 64-bit tarball "linux-arm".
ARG TARGETARCH=amd64

# SHA256 of the two tarballs, so a corrupted or substituted download fails the
# build instead of being installed. Google publishes no checksum file for them,
# so these are computed from the release. When bumping GCLOUD_VERSION, refresh
# both:
#
#   V=<new version>
#   for a in x86_64 arm; do
#     curl -fsSL -O "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-$V-linux-$a.tar.gz"
#     sha256sum "google-cloud-cli-$V-linux-$a.tar.gz"
#   done
ARG GCLOUD_SHA256_AMD64=1503a6fcda689d1e1013a421e2c85850e7f58382c0be7064877b5e1a1038bc64
ARG GCLOUD_SHA256_ARM64=547c5c28ae449a862339edbe73e4254073b33072a364463f581adebf894c5cfa

# Download, verify, install and clean up the Google Cloud CLI in a single layer.
# curl uses -fSL --retry so a slow/flaky runner network fails loudly instead
# of producing a truncated archive (or hanging until the job times out).
#
# Two things are excluded before install rather than removed after it:
#   - gsutil, because backups use `gcloud storage` and Google drops gsutil from
#     the CLI after March 2027 anyway. Excluding it beats `gcloud components
#     remove gsutil`, which byte-compiles the whole CLI on its way out and leaves
#     behind far more .pyc than the gsutil files it deleted.
#   - the bundled Python, because CLOUDSDK_PYTHON above points the CLI at
#     Alpine's python3; keeping both would ship two interpreters and run one.
RUN set -eu; \
    case "$TARGETARCH" in \
        amd64) GCLOUD_ARCH=x86_64; GCLOUD_SHA256="$GCLOUD_SHA256_AMD64" ;; \
        arm64) GCLOUD_ARCH=arm;    GCLOUD_SHA256="$GCLOUD_SHA256_ARM64" ;; \
        *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    TARBALL="google-cloud-cli-${GCLOUD_VERSION}-linux-${GCLOUD_ARCH}.tar.gz"; \
    curl -fSL --retry 5 --retry-delay 5 -O "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${TARBALL}"; \
    echo "${GCLOUD_SHA256}  ${TARBALL}" | sha256sum -c - \
      || { echo "Checksum mismatch for ${TARBALL}. If GCLOUD_VERSION was bumped, refresh GCLOUD_SHA256_AMD64/ARM64 - see the comment above." >&2; exit 1; }; \
    tar -xf "$TARBALL" \
        --exclude 'google-cloud-sdk/bin/gsutil*' \
        --exclude 'google-cloud-sdk/platform/gsutil*' \
        --exclude 'google-cloud-sdk/.install/gsutil*' \
        --exclude 'google-cloud-sdk/platform/bundledpythonunix' \
        --exclude 'google-cloud-sdk/.install/bundled-python3-unix*'; \
    ./google-cloud-sdk/install.sh --usage-reporting false -q; \
    rm "$TARBALL"

RUN mkdir -p /data

COPY run.sh /opt/run.sh

RUN chmod +x /opt/run.sh

# Reports the outcome of the last completed backup, so a silently failing backup
# shows up as an unhealthy container instead of only in the log. A container that
# has not completed a backup yet is healthy. Disable with `--no-healthcheck`.
HEALTHCHECK --interval=5m --timeout=10s --start-period=30s --retries=1 \
    CMD ["sh", "/opt/run.sh", "healthcheck"]

ENTRYPOINT [ "sh", "/opt/run.sh" ]

CMD ["setup"]
