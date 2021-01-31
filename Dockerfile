# Stick to ubuntu groovy for now
FROM ubuntu:groovy
LABEL AUTHOR="vinid223@gmail.com"

ENV DEBIAN_FRONTEND="noninteractive" HOME="/root" LC_ALL="C.UTF-8" LANG="en_US.UTF-8" LANGUAGE="en_US.UTF-8"

RUN apt-get update && apt-get install -y --no-install-recommends cron curl gnupg2

# Installing Google Cloud SDK
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg  add - && apt-get update -y && apt-get install google-cloud-sdk -y

RUN apt-get autoremove -y  && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Create folder for data backup
RUN mkdir -p /data

ADD run.sh /
ADD boto.config /root/.boto

RUN chmod +x /run.sh

ENTRYPOINT ["/run.sh"]

CMD ["start"]
