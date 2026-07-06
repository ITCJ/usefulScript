#!/usr/bin/env bash
set -euo pipefail

# 让指定用户无需 sudo 即可使用 Docker，并检查最终权限。
# 用法：
#   ./add_usr_to_docker_group.sh              # 配置当前用户
#   ./add_usr_to_docker_group.sh <username>   # 配置指定用户

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "错误：此脚本仅适用于 Linux。" >&2
    exit 1
fi

TARGET_USER="${1:-${SUDO_USER:-$(id -un)}}"

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "错误：用户不存在：$TARGET_USER" >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1 && [[ ! -e /usr/bin/docker ]]; then
    echo "错误：未找到 Docker，请先安装 Docker Engine。" >&2
    exit 1
fi

run_as_root() {
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

echo "[1/4] 创建 docker 组"
run_as_root groupadd -f docker

echo "[2/4] 将 $TARGET_USER 加入 docker 组"
run_as_root usermod -aG docker "$TARGET_USER"

echo "[3/4] 修复 Docker 客户端执行权限"
if [[ -e /usr/bin/docker ]]; then
    run_as_root chown root:root /usr/bin/docker
    run_as_root chmod 0755 /usr/bin/docker
else
    DOCKER_BIN="$(command -v docker)"
    run_as_root chmod a+rx "$DOCKER_BIN"
fi

echo "[4/4] 修复 Docker socket 权限"
if [[ -S /var/run/docker.sock ]]; then
    run_as_root chown root:docker /var/run/docker.sock
    run_as_root chmod 0660 /var/run/docker.sock
else
    echo "提示：/var/run/docker.sock 不存在，请确认 Docker 服务已经启动。" >&2
fi

echo
echo "== 配置结果 =="
id "$TARGET_USER"

if [[ -e /usr/bin/docker ]]; then
    ls -l /usr/bin/docker
else
    ls -l "$(command -v docker)"
fi

if [[ -e /var/run/docker.sock ]]; then
    ls -l /var/run/docker.sock
    stat -c 'socket: mode=%a uid=%u gid=%g owner=%U:%G' /var/run/docker.sock
fi

echo
if [[ "$TARGET_USER" == "$(id -un)" ]] && id -nG | tr ' ' '\n' | grep -qx docker; then
    echo "当前会话已具有 docker 组权限，开始连接测试："
    DOCKER_HOST=unix:///var/run/docker.sock docker ps
else
    echo "配置完成。组权限会在重新登录后生效。"
    echo "当前用户也可运行以下命令刷新终端："
    echo "  newgrp docker"
    echo "之后执行："
    echo "  docker ps"
fi
