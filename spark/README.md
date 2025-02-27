# spark image build

> current spark version: 2.4.8 with hadoop 2.7.3

official image repository: https://hub.docker.com/r/apache/spark

## folder structure

```
spark
├── jars
├── Dockerfile
├── README.md
```

1. jars: spark jars, if you want to add extra jars, please put them in the jars folder

## scripts

```
# build image
docker build -t spark:2.4.8-hadoop2.7 --build-arg spark_archive_name=spark-2.4.8-bin-hadoop2.7 .
```