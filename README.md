# FreeSWITCH Docker 镜像

[![构建与验证](https://github.com/ruishanio/freeswitch/actions/workflows/image.yml/badge.svg?branch=main)](https://github.com/ruishanio/freeswitch/actions/workflows/image.yml)

从 FreeSWITCH 1.11.3 源码构建的 `linux/amd64` 镜像，包含 103 个模块。编译环境使用官方 `debian:trixie-slim`，运行镜像从 `scratch` 组装。模块、安装路径、vanilla 配置和容器启动行为以 `safarov/freeswitch:1.11.3` 为兼容性基准。

## 快速开始

克隆仓库并使用 Docker Buildx 构建镜像。首次构建需要联网下载 Debian 软件包和上游源码。

```sh
git clone https://github.com/ruishanio/freeswitch.git
cd freeswitch
docker buildx build --platform linux/amd64 --provenance=false --load \
  -t local/freeswitch:1.11.3 .
```

启动一个仅用于本机验证的容器，并查看健康状态。

```sh
docker run -d --rm --name freeswitch-demo --platform linux/amd64 \
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

## 兼容性验证

构建完成后，使用 Python 3 运行与 GitHub Actions 相同的验收脚本。

```sh
python3 scripts/verify.py local/freeswitch:1.11.3
```

脚本使用固定摘要的参考镜像，首次运行时自动拉取。两个镜像分别在隔离容器中接受以下检查，结束后自动清理容器。

- 103 个模块及其共享库依赖，以及默认配置实际加载的模块。
- 运行目录的实际路径，以及 vanilla 配置和媒体资源的文件哈希。
- ESL 状态、Docker 健康检查、EPMD、抓包、正常停止，以及重启后配置和密码的保留。

## 使用 GitHub Actions 发布到 Docker Hub

源码和工作流托管在 GitHub，镜像发布到 Docker Hub。首次发布前，创建目标 Docker Hub 仓库，并在 GitHub 仓库的 **Settings → Secrets and variables → Actions** 中配置以下项目。

| 类型 | 名称 | 值 |
| --- | --- | --- |
| Variable | `DOCKERHUB_USERNAME` | 用于登录 Docker Hub 的用户名 |
| Variable | `DOCKERHUB_REPOSITORY` | 完整镜像仓库名，例如 `myorg/freeswitch` |
| Secret | `DOCKERHUB_TOKEN` | 对目标仓库有读写权限的 Docker Hub 访问令牌 |
| Variable（可选） | `DOCKERHUB_LATEST_TAG` | 同时更新 `latest` 的 Git 标签，例如 `v1.11.3` |

Pull Request、推送到 `main` 和手动运行工作流都会构建并验证镜像。要发布版本，在准备发布的提交上创建并推送 Git 标签。

```sh
git tag v1.11.3
git push origin v1.11.3
```

标签格式为 `v<版本>`，版本取自 [VERSION](VERSION)。同一版本重新打包可追加 `-r1`、`-r2` 等修订号。例如，`v1.11.3-r1` 通过验收后会发布为 `myorg/freeswitch:1.11.3-r1`。实际发布的镜像摘要可在工作流摘要中查看。

## 维护与上游来源

- 调整编译选项或依赖版本时，更新 [Dockerfile](Dockerfile) 中的源码提交和 SHA-256 校验值。FreeSWITCH 核心和模块默认使用 4 个并行编译任务，可在构建时传入 `--build-arg JOBS=2` 调整。
- 增减模块时，修改[模块清单](modules.conf)。[打包脚本](scripts/package.sh) 会核对实际安装的模块并收集运行依赖。
- 升级 FreeSWITCH 时，同步更新 [VERSION](VERSION)、源码锁定值和[验收脚本](scripts/verify.py)中的参考镜像摘要，再检查新版的模块和配置差异。
- 入口脚本和健康检查沿用参考镜像的实现，保留原作者声明。脚本许可证见 [image/COPYING](image/COPYING)。

[FreeSWITCH 1.11.3 源码](https://github.com/signalwire/freeswitch/tree/ef32e205295e29f034f1453ad245ba5efb07b94a) · [参考镜像](https://hub.docker.com/r/safarov/freeswitch) · [发布工作流](.github/workflows/image.yml)
