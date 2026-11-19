# FreeSWITCH Docker 镜像

基于 FreeSWITCH 1.11.3 源码构建，支持 `linux/amd64` 和 `linux/arm64`，包含 [103 个模块](modules.conf)。

## 本地运行

在仓库根目录构建并启动容器。

```sh
docker build -t local/freeswitch:1.11.3 .
docker run -d --name freeswitch -v freeswitch-conf:/etc/freeswitch local/freeswitch:1.11.3
```
