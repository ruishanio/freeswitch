# FreeSWITCH Docker 镜像

[![镜像构建](https://github.com/ruishanio/freeswitch/actions/workflows/image.yml/badge.svg?branch=main)](https://github.com/ruishanio/freeswitch/actions/workflows/image.yml)

从 FreeSWITCH 1.11.3 源码构建的 Docker 镜像，支持 **Linux AMD64** 和 **Linux ARM64**。两个架构均包含 103 个模块。编译环境使用官方 `debian:trixie-slim`，运行镜像从 `scratch` 组装。模块、安装路径、vanilla 配置和容器启动行为以 `safarov/freeswitch:1.11.3` 为兼容性基准。

## 快速开始

克隆仓库并使用 Docker Buildx 为本机架构构建镜像。首次构建需要联网下载 Debian 软件包和上游源码。

```sh
git clone https://github.com/ruishanio/freeswitch.git
cd freeswitch
docker buildx build --provenance=false --load \
  -t local/freeswitch:1.11.3 .
```

在另一种架构上构建时，可在 Buildx 命令中指定 `--platform linux/amd64` 或 `--platform linux/arm64`，本机需要已配置相应的模拟器或原生构建节点。

启动一个本地容器，并查看健康状态。

```sh
docker run -d --rm --name freeswitch-demo \
  --network none local/freeswitch:1.11.3
docker inspect --format '{{.State.Health.Status}}' freeswitch-demo
```

状态变为 `healthy` 后，通过 `fs_cli` 查询服务。示例容器在停止后自动移除。

```sh
docker exec freeswitch-demo fs_cli -x status
docker stop freeswitch-demo
```

## 容器配置

首次启动会把 vanilla 配置复制到 `/etc/freeswitch` 并生成随机 SIP 密码。需要保留配置时，可在 `docker run` 时添加 `-v freeswitch-conf:/etc/freeswitch`。该目录已包含 `freeswitch.xml` 时，入口脚本会沿用已有配置和密码。

| 容器路径 | 用途 |
| --- | --- |
| `/etc/freeswitch` | 当前生效的配置 |
| `/usr/share/freeswitch/conf/vanilla` | 首次启动使用的默认配置 |
| `/usr/lib/freeswitch/mod` | 已编译的模块 |
| `/usr/share/freeswitch/sounds` | 下载并解压的语音资源 |

| 环境变量 | 用途 |
| --- | --- |
| `SOUND_TYPES`、`SOUND_RATES` | 同时设置后下载语音包，例如 `SOUND_TYPES=en-us-callie:music`、`SOUND_RATES=8000:16000`。可用类型见[语音包清单](image/sounds_version.txt)。 |
| `EPMD` | 设为 `true` 时启动 Erlang Port Mapper Daemon。 |
| `DUMPCAP` | 设为 `true` 时启动滚动抓包，文件写入 `/dumpcap`。 |

## 使用 GitHub Actions 发布到 Docker Hub

源码和工作流托管在 GitHub，镜像发布到 Docker Hub。首次发布前，创建目标 Docker Hub 仓库，并在 GitHub 仓库的 **Settings → Secrets and variables → Actions** 中配置以下项目。

| 类型 | 名称 | 值 |
| --- | --- | --- |
| Variable | `DOCKERHUB_USERNAME` | 用于登录 Docker Hub 的用户名 |
| Variable | `DOCKERHUB_REPOSITORY` | 完整镜像仓库名，例如 `myorg/freeswitch` |
| Secret | `DOCKERHUB_TOKEN` | 对目标仓库有读写权限的 Docker Hub 访问令牌 |
| Variable（可选） | `DOCKERHUB_LATEST_TAG` | 同时更新 `latest` 的 Git 标签，例如 `v1.11.3` |

Pull Request、推送到 `main` 和手动运行工作流都会在两个架构的原生 Linux 节点上分别编译镜像。版本标签触发的工作流会将两个架构打包为一份镜像清单，并推送到 Docker Hub。要发布版本，在准备发布的提交上创建并推送 Git 标签。

```sh
git tag v1.11.3
git push origin v1.11.3
```

标签格式为 `v<版本>`，版本取自 [VERSION](VERSION)。同一版本重新打包可追加 `-r1`、`-r2` 等修订号。例如，`v1.11.3-r1` 会发布为 `myorg/freeswitch:1.11.3-r1`。两个架构共用同一个版本标签，Docker 拉取时会自动选择与宿主机匹配的镜像。工作流摘要记录多架构镜像的摘要。

## 维护与上游来源

- 编译选项和依赖版本在 [Dockerfile](Dockerfile) 中维护。libks 和 SignalWire C 客户端按提交号下载。FreeSWITCH 核心和模块默认使用 4 个并行编译任务，可在构建时传入 `--build-arg JOBS=2` 调整。
- 增减模块时，修改[模块清单](modules.conf)。[打包脚本](scripts/package.sh) 按清单收集模块及其运行依赖。
- 升级 FreeSWITCH 时，同步更新 [VERSION](VERSION)、Dockerfile 中的 FreeSWITCH 版本标签，并按新版调整模块清单。
- 入口脚本和健康检查沿用参考镜像的实现，保留原作者声明。脚本许可证见 [image/COPYING](image/COPYING)。

[FreeSWITCH 1.11.3 源码](https://github.com/signalwire/freeswitch/tree/v1.11.3) · [参考镜像](https://hub.docker.com/r/safarov/freeswitch) · [发布工作流](.github/workflows/image.yml)
