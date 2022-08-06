FROM alpine:3
LABEL AUTHOR="vinid223@gmail.com"

RUN apk add --no-cache python3 curl

RUN curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-396.0.0-linux-x86_64.tar.gz

# ARM
# RUN curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-396.0.0-linux-arm.tar.gz

RUN tar -xf google-cloud-cli-396.0.0-linux-x86_64.tar.gz

RUN ./google-cloud-sdk/install.sh

RUN rm google-cloud-cli-396.0.0-linux-x86_64.tar.gz

RUN mkdir -p /data

ADD run.sh /opt

RUN chmod +x /opt/run.sh

ENTRYPOINT [ "sh", "/opt/run.sh" ]

CMD ["setup"]