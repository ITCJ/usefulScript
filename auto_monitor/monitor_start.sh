#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"
REQ_FILE="${SCRIPT_DIR}/requirements.txt"

# ── 凭据检查 ──────────────────────────────────────────
if [ -z "${IBASE_ACCOUNT:-}" ] || [ -z "${IBASE_PASSWORD:-}" ]; then
    echo "错误: 请设置环境变量:" >&2
    echo "  export IBASE_ACCOUNT=your_account" >&2
    echo "  export IBASE_PASSWORD=your_password" >&2
    exit 1
fi

# ── Python 检查 ───────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    echo "错误: 需要 Python 3.9+" >&2
    exit 1
fi

PY_VER=$(python3 -c 'import sys; print(sys.version_info[:2] >= (3, 9))')
if [ "$PY_VER" != "True" ]; then
    echo "错误: 需要 Python 3.9+, 当前: $(python3 --version)" >&2
    exit 1
fi

# ── uv 检查/安装 ─────────────────────────────────────
if ! command -v uv &>/dev/null; then
    echo "→ 安装 uv..."
    python3 -m pip install uv -q 2>/dev/null \
        || python3 -m pip install uv --break-system-packages -q 2>/dev/null \
        || { echo "错误: 无法安装 uv" >&2; exit 1; }
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    command -v uv &>/dev/null || { echo "错误: uv 已安装但不在 PATH" >&2; exit 1; }
fi

# ── 虚拟环境 ──────────────────────────────────────────
NEED_INSTALL=false
if [ ! -d "$VENV_DIR" ]; then
    echo "→ 创建虚拟环境 ..."
    uv venv "$VENV_DIR" --python python3
    NEED_INSTALL=true
elif [ "$REQ_FILE" -nt "$VENV_DIR/pyvenv.cfg" ] 2>/dev/null; then
    NEED_INSTALL=true
fi

if $NEED_INSTALL; then
    echo "→ 安装依赖 ..."
    uv pip install -r "$REQ_FILE" --python "$VENV_DIR/bin/python" -q
    echo "→ 安装 Playwright Chromium ..."
    "$VENV_DIR/bin/python" -m playwright install chromium
fi

# ── 启动 ──────────────────────────────────────────────
MODE="${1:---daemon}"
shift 2>/dev/null || true

exec "$VENV_DIR/bin/python" "${SCRIPT_DIR}/dashboard.py" "$MODE" "$@"
