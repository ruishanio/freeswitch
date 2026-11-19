#!/usr/bin/env python3
"""在隔离容器中验收源码构建镜像，支持在本地对照 AMD64 参考镜像。"""

import argparse
import difflib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
LOADERS = {
    "linux/amd64": "/lib64/ld-linux-x86-64.so.2",
    "linux/arm64": "/lib/ld-linux-aarch64.so.1",
}
REFERENCE = "safarov/freeswitch@sha256:f156e01a96d48944078ed7f0e24304be63ea15f6466cf607a0aeb6cb47761da7"
DIRECTORIES = {
    "base": "/usr", "conf": "/etc/freeswitch", "mod": "/usr/lib/freeswitch/mod",
    "sounds": "/usr/share/freeswitch/sounds", "log": "/var/log/freeswitch",
    "run": "/var/run/freeswitch", "db": "/var/lib/freeswitch/db",
    "script": "/usr/share/freeswitch/scripts", "recordings": "/var/lib/freeswitch/recordings",
}


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True).strip()


def compare(name, expected, actual):
    if expected != actual:
        difference = difflib.unified_diff(
            str(expected).splitlines(), str(actual).splitlines(),
            fromfile="参考值", tofile="实际值", lineterm=""
        )
        raise RuntimeError(f"{name}不一致\n" + "\n".join(difference))


def wait_healthy(container):
    """等待镜像自带的 Docker 健康检查通过，并限制启动等待时间。"""
    for _ in range(90):
        state = json.loads(docker("inspect", "--format", "{{json .State}}", container))
        if not state["Running"]:
            raise RuntimeError(f"容器提前退出，退出码 {state['ExitCode']}")
        if state["Health"]["Status"] == "healthy":
            return
        time.sleep(1)
    raise RuntimeError("90 秒内 Docker 健康检查未通过")


def snapshot(image, platform, *, compare_resources):
    """从全新容器获取模块、资源、路径与启动结果，退出时释放本次创建的容器。"""
    print(f"正在验证 {image}（{platform}）", flush=True)
    container = docker(
        "create", "--network", "none", "--platform", platform,
        "-e", "EPMD=true", "-e", "DUMPCAP=true", image,
    )
    try:
        def run(*arguments):
            return docker("exec", container, *arguments)

        def api(command):
            return run("fs_cli", "-x", command)

        # 使用容器实际选中的镜像 ID，兼容同一个本地标签包含多个平台。
        image_id = docker("inspect", "-f", "{{.Image}}", container)
        metadata = json.loads(docker("image", "inspect", image_id))[0]
        compare("镜像平台", platform, f"{metadata['Os']}/{metadata['Architecture']}")
        config = metadata["Config"]
        docker("start", container)
        wait_healthy(container)
        release = (ROOT / "VERSION").read_text().strip()
        if not api("version").startswith(f"FreeSWITCH Version {release}-"):
            raise RuntimeError("运行的 FreeSWITCH 版本与 VERSION 不符")
        if not api("status").startswith("UP ") or "up and running" not in run("epmd", "-names"):
            raise RuntimeError("FreeSWITCH 或 EPMD 未就绪")

        run("sh", "-ec", 'pidof dumpcap >/dev/null && test -n "$(ls /dumpcap/packets*.pcap)"')

        # 验收本次构建自己的配置和资源，完整哈希仅在手动对照上游时采集。
        run("sh", "-ec", """
            for file in /etc/freeswitch/freeswitch.xml /usr/share/freeswitch/conf/vanilla/vars.xml \
                        /usr/share/freeswitch/tz/timezones.conf.xml /usr/share/freeswitch/fonts/FreeSans.ttf; do
                test -s "$file" || { echo "缺少资源 $file" >&2; exit 1; }
            done
        """)
        files = ""
        if compare_resources:
            files = run("sh", "-ec", """
                find /usr/share/freeswitch /var/lib/freeswitch/images -type f -exec sha256sum '{}' ';'
                sha256sum /entrypoint.sh /healthcheck.sh /sounds_version.txt
                stat -c '%a %n' /entrypoint.sh /healthcheck.sh /sounds_version.txt
            """)
        modules = run("ls", "-1", "/usr/lib/freeswitch/mod")
        manifest = (ROOT / "modules.conf").read_text().splitlines()
        compare("编译模块", "\n".join(sorted(Path(m).name + ".so" for m in manifest)), modules)
        run("sh", "-ec", """
            for tool in fs_cli freeswitch fs_encode fs_ivrd fs_tts fsxs gentls_cert switch_eavesdrop \
                        tone2wav curl grep tcpdump dumpcap epmd busybox; do
                test -x "/usr/bin/$tool" || { echo "缺少 /usr/bin/$tool" >&2; exit 1; }
            done
        """)
        # 动态加载器逐个解析模块，覆盖未由 vanilla 启用的模块及其可选媒体依赖。
        dependencies = run("sh", "-ec", """
            for file in /usr/lib/libfreeswitch.so.1 /usr/lib/freeswitch/mod/*.so; do
                resolved=$("$1" --list "$file")
                echo "$file"
                echo "$resolved" | awk '$2 == "=>" && $3 ~ /^\\// {print $1}' | sort
            done
        """, "check-libraries", LOADERS[platform])
        rows = json.loads(api("show modules as json"))["rows"]
        loaded = sorted({row["filename"] for row in rows if row.get("filename")})
        for module in ("mod_commands", "mod_event_socket"):
            if f"{DIRECTORIES['mod']}/{module}.so" not in loaded:
                raise RuntimeError(f"默认配置未加载 {module}")
        paths = {name: api(f"global_getvar {name}_dir") for name in DIRECTORIES}
        compare("运行目录", DIRECTORIES, paths)

        # 已有配置再次启动时应保留首次生成的 SIP 密码。
        password = api("global_getvar default_password")
        if len(password) != 12 or password.startswith("-ERR"):
            raise RuntimeError("首次启动未生成预期的 SIP 密码")
        docker("stop", "-t", "15", container)
        compare("SIGTERM 退出码", "0", docker("inspect", "-f", "{{.State.ExitCode}}", container))
        docker("start", container)
        wait_healthy(container)
        if api("global_getvar default_password") != password:
            raise RuntimeError("再次启动覆盖了已有 SIP 配置")
        return {
            "容器配置": {k: config.get(k) for k in ("Entrypoint", "Cmd", "Healthcheck", "User", "Env", "WorkingDir", "Volumes", "ExposedPorts")},
            "共享库依赖": dependencies,
            "资源文件": "\n".join(sorted(files.splitlines())),
            "运行路径": paths,
            "已加载模块": "\n".join(loaded),
        }
    finally:
        docker("rm", "-fv", container)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", help="本地源码构建的镜像")
    parser.add_argument("--platform", choices=LOADERS, help="待验证的平台，默认读取本地镜像架构")
    parser.add_argument("--standalone", action="store_true", help="只验收本次构建的镜像，适用于两个架构")
    args = parser.parse_args()
    platform = args.platform or docker("image", "inspect", "-f", "{{.Os}}/{{.Architecture}}", args.image)
    if platform not in LOADERS:
        parser.error(f"不支持的镜像平台 {platform}")
    # 保留原有 AMD64 本地对照命令；CI 在两个平台显式执行独立验收。
    compare_upstream = platform == "linux/amd64" and not args.standalone
    actual = snapshot(args.image, platform, compare_resources=compare_upstream)
    if compare_upstream:
        expected = snapshot(REFERENCE, platform, compare_resources=True)
        for key in expected:
            compare(key, expected[key], actual[key])
    print(f"{platform} 模块、资源、路径、容器配置、健康检查及重启验证通过")
