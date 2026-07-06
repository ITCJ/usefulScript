#!/usr/bin/env bash
set -euo pipefail

# Ubuntu APT 换源脚本。
# 自动识别版本代号、架构及 sources.list/DEB822 配置格式。

MIRROR_NAME=""
CUSTOM_URL=""

if [[ $# -ne 0 ]]; then
    echo "错误：此脚本无需参数，直接运行后按提示选择镜像站。" >&2
    exit 2
fi

if [[ "$(uname -s)" != "Linux" || ! -r /etc/os-release ]]; then
    echo "错误：未检测到受支持的 Linux 系统。" >&2
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "错误：当前发行版是 ${PRETTY_NAME:-unknown}，此脚本仅支持 Ubuntu。" >&2
    exit 1
fi

CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
if [[ -z "$CODENAME" || ! "$CODENAME" =~ ^[a-z0-9-]+$ ]]; then
    echo "错误：无法识别 Ubuntu 版本代号。" >&2
    exit 1
fi

if ! command -v dpkg >/dev/null 2>&1 || ! command -v apt-get >/dev/null 2>&1; then
    echo "错误：系统缺少 dpkg 或 apt-get。" >&2
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "错误：需要 root 权限，且当前系统未安装 sudo。" >&2
        exit 1
    fi
    exec sudo -- "$0"
fi

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    amd64|i386)
        REPO_KIND="ubuntu"
        OFFICIAL_MAIN="http://archive.ubuntu.com/ubuntu"
        OFFICIAL_SECURITY="http://security.ubuntu.com/ubuntu"
        ;;
    *)
        REPO_KIND="ubuntu-ports"
        OFFICIAL_MAIN="http://ports.ubuntu.com/ubuntu-ports"
        OFFICIAL_SECURITY="$OFFICIAL_MAIN"
        ;;
esac

if [[ ! -t 0 ]]; then
    echo "错误：此脚本需要在交互式终端中运行。" >&2
    exit 2
fi

echo "检测到：${PRETTY_NAME:-Ubuntu}，代号 $CODENAME，架构 $ARCH"
echo "请选择镜像站："
select choice in "Ubuntu 官方" "阿里云" "清华 TUNA" "中科大 USTC" "自定义"; do
    case "$REPLY" in
        1) MIRROR_NAME="official"; break ;;
        2) MIRROR_NAME="aliyun"; break ;;
        3) MIRROR_NAME="tuna"; break ;;
        4) MIRROR_NAME="ustc"; break ;;
        5)
            MIRROR_NAME="custom"
            read -r -p "请输入镜像地址：" CUSTOM_URL
            CUSTOM_URL="${CUSTOM_URL%/}"
            break
            ;;
        *) echo "请输入 1-5。" ;;
    esac
done

case "$MIRROR_NAME" in
    official)
        MIRROR_LABEL="Ubuntu 官方"
        MAIN_URL="$OFFICIAL_MAIN"
        ;;
    aliyun)
        MIRROR_LABEL="阿里云"
        MAIN_URL="https://mirrors.aliyun.com/$REPO_KIND"
        ;;
    tuna)
        MIRROR_LABEL="清华 TUNA"
        MAIN_URL="https://mirrors.tuna.tsinghua.edu.cn/$REPO_KIND"
        ;;
    ustc)
        MIRROR_LABEL="中科大 USTC"
        MAIN_URL="https://mirrors.ustc.edu.cn/$REPO_KIND"
        ;;
    custom)
        MIRROR_LABEL="自定义"
        MAIN_URL="$CUSTOM_URL"
        ;;
esac

if [[ ! "$MAIN_URL" =~ ^https?://[^[:space:]]+$ ]]; then
    echo "错误：镜像地址无效：$MAIN_URL" >&2
    exit 2
fi

if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]] ||
   dpkg --compare-versions "${VERSION_ID:-0}" ge 24.04; then
    SOURCE_FORMAT="deb822"
    TARGET_FILE="/etc/apt/sources.list.d/ubuntu.sources"
else
    SOURCE_FORMAT="list"
    TARGET_FILE="/etc/apt/sources.list"
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/etc/apt/source-backups/$TIMESTAMP"
mkdir -p "$BACKUP_DIR"

if [[ -e "$TARGET_FILE" ]]; then
    cp -a "$TARGET_FILE" "$BACKUP_DIR/"
fi

TEMP_FILE="$(mktemp)"
trap 'rm -f "$TEMP_FILE"' EXIT

if [[ "$SOURCE_FORMAT" == "deb822" ]]; then
    cat >"$TEMP_FILE" <<EOF
Types: deb
URIs: $MAIN_URL
Suites: $CODENAME ${CODENAME}-updates ${CODENAME}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $OFFICIAL_SECURITY
Suites: ${CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
else
    cat >"$TEMP_FILE" <<EOF
deb $MAIN_URL $CODENAME main restricted universe multiverse
deb $MAIN_URL ${CODENAME}-updates main restricted universe multiverse
deb $MAIN_URL ${CODENAME}-backports main restricted universe multiverse
deb $OFFICIAL_SECURITY ${CODENAME}-security main restricted universe multiverse
EOF
fi

install -D -m 0644 "$TEMP_FILE" "$TARGET_FILE"

echo "系统：${PRETTY_NAME:-Ubuntu}"
echo "架构：$ARCH"
echo "镜像：$MIRROR_LABEL"
echo "主源：$MAIN_URL"
echo "安全更新源：$OFFICIAL_SECURITY"
echo "配置文件：$TARGET_FILE（$SOURCE_FORMAT）"
echo "备份目录：$BACKUP_DIR"

echo
echo "正在刷新 APT 缓存..."
apt-get update
