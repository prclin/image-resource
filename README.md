# docker image和helm chart构建资源

> every folder is a docker image or helm chart. And there is a .manifest file in each folder, that file contains the list of files for the build context. when build docker image or helm chart, we should supply the files in the .manifest file to build context.