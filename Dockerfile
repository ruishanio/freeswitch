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
ADD --checksum=sha256:8a19f6efaab7bdecaa63e03d73d5dfc36592b7e72500e5460d0bf42dacaadefc https://codeload.github.com/freeswitch/libbroadvoice/tar.gz/d4d484e777d347023577e76d5a3a8e9714d554a7 /tmp/broadvoice.tar.gz
ADD --checksum=sha256:358142a6d063c469661306b7191068e0b8cc509f2f78ece2d2cd3db0f561972b https://codeload.github.com/freeswitch/libsilk/tar.gz/493a32f98464ec312c01b918eba4ee2be9fe0eca /tmp/silk.tar.gz
ADD --checksum=sha256:1cb9a0ee3a68a20e84db9702cb82ac643b27e15820e74eb5a69511952dfa27b2 https://codeload.github.com/freeswitch/spandsp/tar.gz/8f1e1646bdec99eac5fd2cd92c35563f736b9b89 /tmp/spandsp.tar.gz
RUN --network=none set -eu; for name in broadvoice silk spandsp; do \
        mkdir "$name"; tar -xf "/tmp/$name.tar.gz" -C "$name" --strip-components=1; \
        libdir=/usr/lib; if [ "$name" = spandsp ]; then libdir=/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH); fi; \
        (cd "$name" && autoreconf -fi && ./configure --prefix=/usr --libdir="$libdir" && \
            make -j4 && make DESTDIR=/out install); \
    done

# mod_signalwire 依赖 libks2 与 C 客户端。源码包没有 Git 历史，跳过 Debian 发布包的变更日志生成。
FROM toolchain AS client
WORKDIR /build/client
ADD --checksum=sha256:9686e1838d78c548a3c9950bda92678d2653bae437dc36e11fd5f6c0e1449b09 https://codeload.github.com/signalwire/libks/tar.gz/34fe98ac8afe480a0a75f1290c77931da5cd7a7a /tmp/libks.tar.gz
RUN --network=none tar -xf /tmp/libks.tar.gz --strip-components=1 && \
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DWITH_PACKAGING=OFF && \
    cmake --build build -j4 && DESTDIR=/out cmake --install build && cp -a /out/usr/. /usr/
WORKDIR /build/signalwire-c
ADD --checksum=sha256:af151e74d6bb5b64860969541369f6ae5cb8783deaec4a2461b738db32080570 https://codeload.github.com/signalwire/signalwire-c/tar.gz/bc4dfcade21e23a767fac16a4624f0ce77b323e8 /tmp/signalwire-c.tar.gz
RUN --network=none tar -xf /tmp/signalwire-c.tar.gz --strip-components=1 && \
    cmake -S . -B . -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_DISABLE_FIND_PACKAGE_Git=TRUE && \
    cmake --build . -j4 && DESTDIR=/out cmake --install .

# 固定 Sofia-SIP 与核心的源码，避免系统库自动升级改变 SIP 栈版本。
FROM toolchain AS build
WORKDIR /build/sofia-sip

ADD --checksum=sha256:0683c6a08750bd89780d8679c504b67b4c54de2e03beb62ae32c8c985562eeab https://codeload.github.com/freeswitch/sofia-sip/tar.gz/6dce59d35535e6dd3945c7b0f76dbf1ba884202d /tmp/sofia.tar.gz
RUN --network=none tar -xzf /tmp/sofia.tar.gz --strip-components=1 && ./bootstrap.sh && \
    ./configure --prefix=/usr && make -j4 && make install && ldconfig
COPY --from=codecs /out/ /
COPY --from=client /out/ /
RUN ldconfig
WORKDIR /build/freeswitch
# 固定源码提交和语音识别模型。后续编译断网，避免隐式下载改变产物。
ADD --checksum=sha256:8d84e49305debdbc2d02b79b1d49850457ca0043a298a01f161f98290565243a https://codeload.github.com/signalwire/freeswitch/tar.gz/ef32e205295e29f034f1453ad245ba5efb07b94a /tmp/source.tar.gz
RUN tar -xzf /tmp/source.tar.gz --strip-components=1 && rm /tmp/source.tar.gz
ADD --checksum=sha256:874c4c083d91c8ff26a2aec250b689e537912ff728923c141c4dac48662cce7a https://files.freeswitch.org/downloads/libs/pocketsphinx-0.8.tar.gz libs/pocketsphinx-0.8.tar.gz
ADD --checksum=sha256:dbb5e9fb85000a7cb97d6958a3ef8d77532dc55fc730ac6979705e8645cb0c18 https://files.freeswitch.org/downloads/libs/communicator_semi_6000_20080321.tar.gz libs/communicator_semi_6000_20080321.tar.gz
ADD --checksum=sha256:55708944872bab1015b8ae07b379bf463764f469163a8fd114cbb16c5e486ca8 https://files.freeswitch.org/downloads/libs/sphinxbase-0.8.tar.gz libs/sphinxbase-0.8.tar.gz

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
