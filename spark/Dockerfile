# stage 1
FROM docker.nexus.k8s.local/openjdk:8-jdk-slim AS builder

ARG spark_archive_name=spark-2.4.8-bin-hadoop2.7

ADD ${spark_archive_name}.tgz /tmp

RUN set -ex && \
    mkdir -p /opt/spark && \
    mkdir -p /opt/spark/work-dir && \
    touch /opt/spark/RELEASE && \
    cp -r /tmp/${spark_archive_name}/bin /opt/spark/bin && \
    cp -r /tmp/${spark_archive_name}/sbin /opt/spark/sbin && \
    cp -r /tmp/${spark_archive_name}/jars /opt/spark/jars && \
    cp /tmp/${spark_archive_name}/kubernetes/dockerfiles/spark/entrypoint.sh /opt/

COPY jars/ /opt/spark/jars/

# stage 2
FROM docker.nexus.k8s.local/openjdk:8-jdk-slim

COPY --from=builder /opt /opt

RUN set -ex && \
    sed -i 's/http:/https:/g' /etc/apt/sources.list && \
    sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list && \
    echo "deb https://mirrors.aliyun.com/debian/ bullseye main contrib non-free" > /etc/apt/sources.list && \
    echo "deb https://mirrors.aliyun.com/debian/ bullseye-updates main contrib non-free" >> /etc/apt/sources.list && \
    echo "deb https://mirrors.aliyun.com/debian-security/ bullseye-security main contrib non-free" >> /etc/apt/sources.list && \
    apt-get update && \
    ln -s /lib /lib64 && \
    apt install -y bash tini libc6 libpam-modules libnss3 && \
    rm /bin/sh && \
    ln -sv /bin/bash /bin/sh && \
    echo "auth required pam_wheel.so use_uid" >> /etc/pam.d/su && \
    chgrp root /etc/passwd && chmod ug+rw /etc/passwd && \
    rm -rf /var/cache/apt/*

ENV SPARK_HOME=/opt/spark

WORKDIR /opt/spark/work-dir

ENTRYPOINT [ "/opt/entrypoint.sh" ]
