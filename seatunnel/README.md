# seatunnel image build

official image repository: https://hub.docker.com/r/apache/seatunnel

## folder structure

```
seatunnel
├── Dockerfile
├── connectors
├── lib
└──README.md
```
1. connectors: extra connectors for seatunnel
2. lib: extra lib for seatunnel
> when build image, the connectors and lib will be copied to the image /opt/seatunnel/connectors and /opt/seatunnel/lib

# scripts

```
# build image
VERSION=2.3.9
docker build -t seatunnel:${VERSION} --build-arg VERSION=${VERSION} .
```
