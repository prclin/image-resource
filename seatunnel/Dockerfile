# stage 1: build seatunnel
FROM docker.nexus.k8s.local/openjdk:8 AS builder

# specify seatunnel version
ARG VERSION=2.3.9

# copy and unzip seatunnel jar
ADD apache-seatunnel-${VERSION}-bin.tar.gz /opt/

# rename seatunnel folder
RUN cd /opt && mv apache-seatunnel-${VERSION} seatunnel

# copy connectors
COPY connectors/ /opt/seatunnel/connectors/

# copy lib
COPY lib/ /opt/seatunnel/lib/

# stage 2: build image
FROM docker.nexus.k8s.local/openjdk:8

# copy seatunnel from builder stage
COPY --from=builder /opt/seatunnel /opt/seatunnel

# specify working directory
WORKDIR /opt/seatunnel