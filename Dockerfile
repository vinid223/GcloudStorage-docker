# Alpine 3.24 ships Python 3.14, which the gcloud CLI supports (it bundles 3.14
# itself). Keep the Python version in mind when bumping either side: an Alpine
# release whose python3 is newer than what the CLI supports breaks `install.sh`.
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
ARG GCLOUD_VERSION=577.0.0
# Populated automatically by BuildKit; the default keeps the legacy builder
# working. Google names the ARM 64-bit tarball "linux-arm".
ARG TARGETARCH=amd64

# Download, install and clean up the Google Cloud CLI in a single layer.
# curl uses -fSL --retry so a slow/flaky runner network fails loudly instead
# of producing a truncated archive (or hanging until the job times out).
# The bundled gsutil is removed right away: backups use `gcloud storage`, and
# Google drops gsutil from the CLI after March 2027 anyway. Removing a component
# byte-compiles the whole CLI on the way out, which adds ~250 MB of .pyc caches -
# far more than the gsutil files it deleted - so those are dropped too. They are
# only caches: every .pyc has its .py sitting next to it.
RUN case "$TARGETARCH" in \
        amd64) GCLOUD_ARCH=x86_64 ;; \
        arm64) GCLOUD_ARCH=arm ;; \
        *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && TARBALL="google-cloud-cli-${GCLOUD_VERSION}-linux-${GCLOUD_ARCH}.tar.gz" \
    && curl -fSL --retry 5 --retry-delay 5 -O "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${TARBALL}" \
    && tar -xf "$TARBALL" \
    && ./google-cloud-sdk/install.sh --usage-reporting false -q \
    && ./google-cloud-sdk/bin/gcloud components remove gsutil --quiet \
    && find ./google-cloud-sdk -name '*.pyc' -delete \
    && rm "$TARBALL"

RUN mkdir -p /data

ADD run.sh /opt

RUN chmod +x /opt/run.sh

ENTRYPOINT [ "sh", "/opt/run.sh" ]

CMD ["setup"]
