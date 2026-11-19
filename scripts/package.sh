#!/usr/bin/env bash
# 在编译容器内按参考镜像的 Debian 路径组装根文件系统。
set -euo pipefail

root=/rootfs
multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
share=$root/usr/share/freeswitch
modules=$root/usr/lib/freeswitch/mod
mkdir -p "$root"/{etc,usr/bin,usr/lib,usr/share/doc/freeswitch} "$modules" \
    "$share"/{conf,fonts,lang,scripts,sounds,tz} "$root/var/lib/freeswitch/images"
ln -s usr/bin "$root/bin"
ln -s usr/lib "$root/lib"
# 仅部分 Debian 架构通过 /lib64 提供 ELF 解释器。
if [[ -d /usr/lib64 ]]; then
    mkdir -p "$root/usr/lib64"
    ln -s usr/lib64 "$root/lib64"
fi

# 仅收集本次编译产物。遇到漏编或意外增加的模块，在组装阶段就中止。
diff -u <(sed 's|.*/||; s/$/.so/' modules.conf | LC_ALL=C sort) \
    <(find /install/usr/lib/freeswitch/mod -name '*.so' -printf '%f\n' | LC_ALL=C sort)
cp -a /install/usr/lib/freeswitch/mod/*.so "$modules/"
cp -a /install/usr/bin/. "$root/usr/bin/"
cp -a /install/usr/lib/libfreeswitch.so.* "$root/usr/lib/"
# 让 ldd 解析到本次编译的核心库，最终镜像只收集运行时 SONAME。
cp -a /install/usr/lib/libfreeswitch.so.* /usr/lib/
ldconfig

# 保留软链接和实际目标，例如 epmd 和 ELF 解释器。镜像根与编译容器具有相同的 /usr 布局。
copy_chain() {
    local path=$1 target
    while true; do
        mkdir -p "$root$(dirname "$path")"
        cp -aT "$path" "$root$path"
        [[ -L $path ]] || break
        target=$(readlink "$path")
        if [[ $target = /* ]]; then path=$target; else path=$(dirname "$path")/$target; fi
        path=$(realpath -ms "$path")
    done
}

for command in busybox tcpdump dumpcap curl grep epmd; do
    copy_chain "$(command -v "$command")"
done
# Debian 的 tcpdump 在部分构建环境位于 sbin，参考镜像公开 /usr/bin/tcpdump。
if [[ ! -e $root/usr/bin/tcpdump ]]; then cp -L "$(command -v tcpdump)" "$root/usr/bin/tcpdump"; fi
while IFS= read -r applet; do
    [[ -e $root/usr/bin/$applet || -L $root/usr/bin/$applet ]] || ln -s /usr/bin/busybox "$root/usr/bin/$applet"
done < <(busybox --list)

# 收集所有模块和工具的传递依赖，包括默认配置未加载的模块。
binaries=("$modules"/*.so)
for path in "$root"/usr/bin/* "$root"/usr/lib/erlang/erts-*/bin/epmd; do
    [[ -f $path && ! -L $path ]] || continue
    if readelf -h "$path" >/dev/null 2>&1; then binaries+=("$path"); fi
done
ldd "${binaries[@]}" > /tmp/dependencies
if grep 'not found' /tmp/dependencies >&2; then exit 1; fi
awk '$2 == "=>" && $3 ~ /^\// {print $3} $1 ~ /^\// && $2 ~ /^\(/ {print $1}' \
    /tmp/dependencies | LC_ALL=C sort -u > /tmp/libraries
while IFS= read -r path; do copy_chain "$path"; done < /tmp/libraries
# glibc 的字符集转换和名称解析插件由运行时按需加载，ldd 无法枚举。
dpkg-query -L "libc6:$(dpkg --print-architecture)" | awk -v prefix="/usr/lib/$multiarch/" 'index($0, prefix) == 1 {print substr($0, 2)}' > /tmp/glibc-files
tar -C / --no-recursion -cf - -T /tmp/glibc-files | tar -C "$root" -xf -
strip --strip-unneeded "${binaries[@]}" "$root"/usr/lib/libfreeswitch.so.1.0.0

cp -a conf/vanilla "$share/conf/"
cp "$share/conf/vanilla/vars.xml" "$share/conf/vanilla/vars.xml.orig"
patch -d "$share/conf/vanilla" -p1 < /tmp/vanilla.patch
for language in de en es fr he pt ru; do cp -a "conf/vanilla/lang/$language" "$share/lang/"; done
cp conf/vanilla/autoload_configs/timezones.conf.xml "$share/tz/"
cp fonts/{FreeMono,FreeSans}.ttf "$share/fonts/"
cp images/*.png "$root/var/lib/freeswitch/images/"
# 复现参考 Debian 软件包写入 PNG 元数据的 UTC 时间（2026-08-28 21:45:44）。
strip-nondeterminism --timestamp 1787953544 "$root"/var/lib/freeswitch/images/*.png
cp -a /install/usr/share/freeswitch/grammar "$share/"
if [[ -f $share/grammar/model/communicator/COPYING ]]; then
    mv "$share/grammar/model/communicator/COPYING" "$root/usr/share/doc/freeswitch/grammar-COPYING"
fi
install -D -m 0644 src/mod/languages/mod_python3/freeswitch.py "$root/usr/lib/python3/dist-packages/freeswitch.py"
# 证书链接指向 Debian 公共信任库。
mkdir -p "$root/etc/ssl"
cp -a /etc/ssl/certs "$root/etc/ssl/"
cp -a /usr/share/ca-certificates "$root/usr/share/"
cp /etc/nsswitch.conf "$root/etc/"
copy_chain "/etc/ld.so.conf.d/$multiarch.conf"
copy_chain /usr/sbin/update-ca-certificates
install -D -m 0644 debian/freeswitch-systemd.freeswitch.service "$root/usr/lib/systemd/system/freeswitch.service"
install -D -m 0644 debian/freeswitch-systemd.freeswitch.tmpfile "$root/usr/lib/tmpfiles.d/freeswitch.conf"
mkdir -p "$root/usr/lib/ssl"
ln -s /etc/ssl/certs "$root/usr/lib/ssl/certs"
cp LICENSE docs/COPYING "$root/usr/share/doc/freeswitch/"
cp fonts/OFL.txt "$root/usr/share/doc/freeswitch/fonts-OFL.txt"

chroot "$root" /usr/bin/freeswitch -version
