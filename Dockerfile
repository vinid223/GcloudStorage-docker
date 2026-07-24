# Alpine 3.24 ships Python 3.14, which is inside the range required by the
# bundled gsutil (5.36+ requires Python 3.9-3.14) and by the gcloud CLI itself.
# Keep the Python version in mind when bumping either side: an Alpine release
# whose python3 is newer than what gsutil supports breaks `install.sh`.
FROM alpine:3.24
LABEL AUTHOR="vinid223@gmail.com"

# py3-crcmod is the compiled CRC32C implementation gsutil looks for; without it
# every rsync run prints a "compiled crcmod not available" warning and falls
# back to the slow pure-Python path.
# tzdata provides /usr/share/zoneinfo so a $TZ like America/Montreal resolves;
# without it musl silently ignores named zones and everything stays on UTC.
RUN apk add --no-cache python3 py3-crcmod curl tzdata

# Default timezone. Overriding TZ at run time shifts both the CRON_SCHEDULE and
# the log timestamps to that zone; the default keeps the previous UTC behaviour.
ENV TZ=UTC

# Version of the Google Cloud CLI to install. Pinned (rather than the floating
# "latest" tarball) so image builds stay reproducible.
ARG GCLOUD_VERSION=577.0.0
# Populated automatically by BuildKit; the default keeps the legacy builder
# working. Google names the ARM 64-bit tarball "linux-arm".
ARG TARGETARCH=amd64

# Download, install and clean up the Google Cloud CLI in a single layer.
# curl uses -fSL --retry so a slow/flaky runner network fails loudly instead
# of producing a truncated archive (or hanging until the job times out).
RUN case "$TARGETARCH" in \
        amd64) GCLOUD_ARCH=x86_64 ;; \
        arm64) GCLOUD_ARCH=arm ;; \
        *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && TARBALL="google-cloud-cli-${GCLOUD_VERSION}-linux-${GCLOUD_ARCH}.tar.gz" \
    && curl -fSL --retry 5 --retry-delay 5 -O "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${TARBALL}" \
    && tar -xf "$TARBALL" \
    && ./google-cloud-sdk/install.sh --usage-reporting false -q \
    && rm "$TARBALL"

RUN mkdir -p /data

ADD run.sh /opt
ADD boto.config /root/.boto

RUN chmod +x /opt/run.sh

ENTRYPOINT [ "sh", "/opt/run.sh" ]

CMD ["setup"]
