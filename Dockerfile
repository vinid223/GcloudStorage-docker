# Pinned to alpine:3.18 (Python 3.11). alpine:3 now floats to Python 3.12+,
# which removed the deprecated `imp` module that the bundled google-cloud-cli
# 396.0.0 bootstrapping code still imports, breaking `install.sh`.
FROM alpine:3.18
LABEL AUTHOR="vinid223@gmail.com"

RUN apk add --no-cache python3 curl

# Download, install and clean up the Google Cloud CLI in a single layer.
# curl uses -fSL --retry so a slow/flaky runner network fails loudly instead
# of producing a truncated archive (or hanging until the job times out).
# ARM hosts: swap the URL for google-cloud-cli-396.0.0-linux-arm.tar.gz
RUN curl -fSL --retry 5 --retry-delay 5 -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-396.0.0-linux-x86_64.tar.gz \
    && tar -xf google-cloud-cli-396.0.0-linux-x86_64.tar.gz \
    && ./google-cloud-sdk/install.sh --usage-reporting false -q \
    && rm google-cloud-cli-396.0.0-linux-x86_64.tar.gz

RUN mkdir -p /data

ADD run.sh /opt
ADD boto.config /root/.boto

RUN chmod +x /opt/run.sh

ENTRYPOINT [ "sh", "/opt/run.sh" ]

CMD ["setup"]