FROM ubuntu:latest
MAINTAINER vinid223@gmail.com

RUN apt-get update && apt-get -y install cron curl gnupg2 apt-utils

# Run the command on container startup
CMD cron && tail -f /var/log/cron.log

# Installing Google Cloud SDK
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg  add - && apt-get update -y && apt-get install google-cloud-sdk -y

# Create folder for data backup
RUN mkdir -p /data

ADD boto.cfg /root/.boto
ADD run.sh /

ENTRYPOINT ["/run.sh"]
CMD ["start"]
