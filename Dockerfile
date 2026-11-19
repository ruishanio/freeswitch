# 编译环境基于官方 Debian 13，系统依赖由 Debian 仓库提供。
FROM debian:trixie-slim AS toolchain
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential autoconf autoconf-archive automake libtool libtool-bin pkg-config cmake \
        bison nasm yasm swig git patch ca-certificates curl file default-jdk-headless \
        erlang-dev libperl-dev python3-dev python3-setuptools liblua5.3-dev \
        uuid-dev zlib1g-dev libssl-dev libpcre2-dev libedit-dev libtpl-dev libsystemd-dev \
        libsqlite3-dev libpq-dev libmariadb-dev unixodbc-dev libgdbm-compat-dev libdb-dev \
        libcurl4-openssl-dev libldns-dev libmemcached-dev libsnmp-dev libexpat1-dev \
        libjpeg62-turbo-dev libtiff-dev libpng-dev libfreetype-dev libsndfile1-dev \
        libspeex-dev libspeexdsp-dev libopus-dev libopusfile-dev libcodec2-dev \
        libopencore-amrnb-dev libshout-dev libmp3lame-dev libmpg123-dev \
        libavformat-dev libavcodec-dev libswscale-dev libswresample-dev \
        flite1-dev libsphinxbase-dev libpocketsphinx-dev && rm -rf /var/lib/apt/lists/*

# 参考镜像的 BroadVoice、SILK 及 SpanDSP 使用 FreeSWITCH 维护的版本。
FROM toolchain AS codecs
WORKDIR /build/codecs
ADD https://codeload.github.com/freeswitch/libbroadvoice/tar.gz/refs/tags/v0.1.0 /tmp/broadvoice.tar.gz
ADD https://codeload.github.com/freeswitch/libsilk/tar.gz/refs/tags/v1.0.9 /tmp/silk.tar.gz
ADD https://codeload.github.com/freeswitch/spandsp/tar.gz/refs/tags/v3.1.1 /tmp/spandsp.tar.gz
RUN --network=none set -eu; for name in broadvoice silk spandsp; do \
        mkdir "$name"; tar -xf "/tmp/$name.tar.gz" -C "$name" --strip-components=1; \
        libdir=/usr/lib; if [ "$name" = spandsp ]; then libdir=/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH); fi; \
        (cd "$name" && autoreconf -fi && ./configure --prefix=/usr --libdir="$libdir" && \
            make -j4 && make DESTDIR=/out install); \
    done

# libks2 和 SignalWire C 客户端的所用提交没有对应版本标签，因此按提交号下载。
# 源码包没有 Git 历史，构建时跳过 Debian 发布包的变更日志生成。
FROM toolchain AS client
WORKDIR /build/client
ADD https://codeload.github.com/signalwire/libks/tar.gz/34fe98ac8afe480a0a75f1290c77931da5cd7a7a /tmp/libks.tar.gz
RUN --network=none tar -xf /tmp/libks.tar.gz --strip-components=1 && \
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DWITH_PACKAGING=OFF && \
    cmake --build build -j4 && DESTDIR=/out cmake --install build && cp -a /out/usr/. /usr/
WORKDIR /build/signalwire-c
ADD https://codeload.github.com/signalwire/signalwire-c/tar.gz/bc4dfcade21e23a767fac16a4624f0ce77b323e8 /tmp/signalwire-c.tar.gz
RUN --network=none tar -xf /tmp/signalwire-c.tar.gz --strip-components=1 && \
    cmake -S . -B . -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_DISABLE_FIND_PACKAGE_Git=TRUE && \
    cmake --build . -j4 && DESTDIR=/out cmake --install .

# 固定 Sofia-SIP 与核心的源码，避免系统库自动升级改变 SIP 栈版本。
FROM toolchain AS build
WORKDIR /build/sofia-sip

ADD https://codeload.github.com/freeswitch/sofia-sip/tar.gz/refs/tags/v1.13.19 /tmp/sofia.tar.gz
RUN --network=none tar -xzf /tmp/sofia.tar.gz --strip-components=1 && ./bootstrap.sh && \
    ./configure --prefix=/usr && make -j4 && make install && ldconfig
COPY --from=codecs /out/ /
COPY --from=client /out/ /
RUN ldconfig
WORKDIR /build/freeswitch
# 指定 FreeSWITCH 版本和语音识别模型。后续编译断网，避免隐式下载。
ADD https://codeload.github.com/signalwire/freeswitch/tar.gz/refs/tags/v1.11.3 /tmp/source.tar.gz
RUN tar -xzf /tmp/source.tar.gz --strip-components=1 && rm /tmp/source.tar.gz
ADD https://files.freeswitch.org/downloads/libs/pocketsphinx-0.8.tar.gz libs/pocketsphinx-0.8.tar.gz
ADD https://files.freeswitch.org/downloads/libs/communicator_semi_6000_20080321.tar.gz libs/communicator_semi_6000_20080321.tar.gz
ADD https://files.freeswitch.org/downloads/libs/sphinxbase-0.8.tar.gz libs/sphinxbase-0.8.tar.gz

COPY modules.conf ./
RUN --network=none ./bootstrap.sh -j && ./configure --enable-portable-binary --disable-dependency-tracking \
    --prefix=/usr --localstatedir=/var --sysconfdir=/etc --with-gnu-ld \
    --with-python3 --with-erlang --with-openssl --enable-core-odbc-support
ARG JOBS=4
RUN --network=none make -j"$JOBS" core
RUN --network=none make -j"$JOBS"
RUN --network=none make DESTDIR=/install install

FROM build AS package
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends busybox tcpdump wireshark-common strip-nondeterminism
COPY scripts/package.sh /tmp/package.sh
COPY image/vanilla.patch /tmp/vanilla.patch
RUN --network=none bash /tmp/package.sh

FROM scratch
WORKDIR /
COPY --from=package /rootfs/ /
COPY --chmod=0755 image/entrypoint.sh /
COPY --chmod=0775 image/healthcheck.sh /
COPY --chmod=0664 image/sounds_version.txt /
HEALTHCHECK --interval=15s --timeout=5s CMD /healthcheck.sh
ENTRYPOINT ["/entrypoint.sh"]
