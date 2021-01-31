FROM debian:jessie
LABEL AUTHOR="vinid223@gmail.com"

ENV DEBIAN_FRONTEND="noninteractive" HOME="/root" LC_ALL="C.UTF-8" LANG="en_US.UTF-8" LANGUAGE="en_US.UTF-8"

RUN apt-get update && apt-get -y install cron curl gnupg2 tzdata

# Installing Google Cloud SDK
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" |  tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
RUN apt-get install apt-transport-https ca-certificates gnupg -y
RUN curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
RUN apt-get update -y &&  apt-get install google-cloud-sdk -y
      
RUN apt-get autoremove -y  && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Create folder for data backup
RUN mkdir -p /data

ADD run.sh /
ADD boto.config /root/.boto

RUN chmod +x /run.sh

ENTRYPOINT ["/run.sh"]

CMD ["start"]
