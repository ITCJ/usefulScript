#!/bin/bash

# 获取当前脚本所在的绝对路径
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ================= 变量定义 =================
# 1. 设置 oh-my-zsh 安装在当前目录下的 .oh-my-zsh 文件夹
export ZSH="$CURRENT_DIR/.oh-my-zsh"
# 2. 设置 .zshrc 生成在当前目录下
export ZSHRC="$CURRENT_DIR/.zshrc"
# 3. 自定义插件目录
export CUSTOM_DIR="$ZSH/custom"

echo "📂 安装路径: $CURRENT_DIR"

# ================= 1. 克隆 Oh My Zsh (Gitee 镜像) =================
if [ -d "$ZSH" ]; then
    echo "✅ Oh My Zsh 目录已存在，跳过克隆。"
else
    echo "⬇️  正在克隆 Oh My Zsh..."
    git clone --depth=1 https://gitee.com/mirrors/oh-my-zsh.git "$ZSH"
fi

# ================= 2. 生成并修改本地 .zshrc =================
echo "⚙️  配置私有 .zshrc..."
# 从模板复制
cp "$ZSH/templates/zshrc.zsh-template" "$ZSHRC"

# 【关键步骤】修改 .zshrc 中的 ZSH 路径
# 默认是 $HOME/.oh-my-zsh，我们需要改为当前目录的绝对路径
# 使用 | 作为分隔符，防止路径中的 / 报错
sed -i.bak "s|export ZSH=\$HOME/.oh-my-zsh|export ZSH=$ZSH|g" "$ZSHRC"

# ================= 3. 下载插件 (Gitee 镜像) =================
echo "🔌 下载插件..."

# 语法高亮
if [ ! -d "$CUSTOM_DIR/plugins/zsh-syntax-highlighting" ]; then
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "$CUSTOM_DIR/plugins/zsh-syntax-highlighting"
fi

# 自动建议
if [ ! -d "$CUSTOM_DIR/plugins/zsh-autosuggestions" ]; then
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$CUSTOM_DIR/plugins/zsh-autosuggestions"
fi

# 历史搜索
if [ ! -d "$CUSTOM_DIR/plugins/zsh-history-substring-search" ]; then
    git clone --depth=1 https://github.com/zsh-users/zsh-history-substring-search "$CUSTOM_DIR/plugins/zsh-history-substring-search"
fi

# ================= 4. 启用插件 =================
echo "📝 更新插件列表..."
sed -i.bak "s/plugins=(git)/plugins=(git extract zsh-autosuggestions zsh-history-substring-search zsh-syntax-highlighting)/g" "$ZSHRC"
rm -f "$ZSHRC.bak"


# ================= 5.私有化 tmux =================
# Tmux Socket (保持在根目录，方便查找，也可以移入 .config/tmux)
TMUX_SOCKET="$CURRENT_DIR/tmux.sock"

# Tmux 配置文件目录与路径
TMUX_CONF_DIR="$CURRENT_DIR/.config/tmux"
TMUX_CONF="$TMUX_CONF_DIR/tmux.conf"

# 指定 Zsh 环境 (确保 Tmux 内部能找到私有的 .zshrc)
export ZDOTDIR="$CURRENT_DIR"

# 指定 tmux 二进制路径 (如果在当前目录 bin 下，否则使用系统默认)
if [ -f "$CURRENT_DIR/bin/tmux" ]; then
    TMUX_BIN="$CURRENT_DIR/bin/tmux"
else
    TMUX_BIN="tmux"
fi

# 1. 确保 .config/tmux 目录存在
if [ ! -d "$TMUX_CONF_DIR" ]; then
    echo "不存在配置目录，退出脚本。"
    exit 1
else
    echo "✅ tmux配置目录已存在，跳过创建。"
fi