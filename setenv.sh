#!/usr/bin/env bash

ln -s /root/siton-data-guoguodata/tcj/ /root/tcj

if [[ "$1" == "--zsh" ]]; then
    INSTALL_ZSH="true"
    shift
else
    INSTALL_ZSH="false"
fi

is_root() {
    return "$(id -u)"
}

has_sudo() {
    local prompt
    prompt=$(sudo -nv 2>&1)
    if [ $? -eq 0 ]; then
        echo "has_sudo__pass_set"
    elif echo "$prompt" | grep -q '^sudo:'; then
        echo "has_sudo__needs_pass"
    else
        echo "no_sudo"
    fi
}

if is_root; then
    sudo_cmd=""
else
    HAS_SUDO=$(has_sudo)
    sudo_cmd="sudo"
    if [ "$HAS_SUDO" == "has_sudo__needs_pass" ]; then
        echo "You need to supply the password to use sudo."
        sudo -v
    elif [ "$HAS_SUDO" == "has_sudo__pass_set" ]; then
        echo "You already have sudo privileges."
    else
        echo "You need to have sudo privileges to run this script for some packages."
        exit 1
    fi
fi

cd "$HOME" || exit

# 换源
# 检查是否存在备份文件
if [ -f /etc/apt/sources.list.bak ]; then
    echo "备份文件 /etc/apt/sources.list.bak 已存在，跳过换源操作。"
else
    # 备份原有的 sources.list 文件
    cp /etc/apt/sources.list /etc/apt/sources.list.bak

    # 写入新的源配置
    cat <<EOF > /etc/apt/sources.list
deb https://mirror.sjtu.edu.cn/ubuntu/ focal main restricted universe multiverse
# deb-src https://mirror.sjtu.edu.cn/ubuntu/ focal main restricted universe multiverse
deb https://mirror.sjtu.edu.cn/ubuntu/ focal-updates main restricted universe multiverse
# deb-src https://mirror.sjtu.edu.cn/ubuntu/ focal-updates main restricted universe multiverse
deb https://mirror.sjtu.edu.cn/ubuntu/ focal-backports main restricted universe multiverse
# deb-src https://mirror.sjtu.edu.cn/ubuntu/ focal-backports main restricted universe multiverse
deb https://mirror.sjtu.edu.cn/ubuntu/ focal-security main restricted universe multiverse
# deb-src https://mirror.sjtu.edu.cn/ubuntu/ focal-security main restricted universe multiverse

# deb https://mirror.sjtu.edu.cn/ubuntu/ focal-proposed main restricted universe multiverse
# deb-src https://mirror.sjtu.edu.cn/ubuntu/ focal-proposed main restricted universe multiverse
EOF

    # 更新 apt 缓存
    apt-get update

    echo "源已成功更换为上海交通大学镜像源，并已更新 apt 缓存。"
fi


$sudo_cmd apt-get -y update && $sudo_cmd apt-get install -y \
    ssh openssh-server gcc libtinfo-dev zlib1g-dev build-essential \
    cmake libedit-dev libxml2-dev llvm tmux wget curl git vim zsh

# 配置代理
cat > ~/.bashrc << EOF
function proxy_on() {
    export http_proxy=http://127.0.0.1:7899
    export https_proxy=\$http_proxy
    echo -e "终端代理已开启。"
}

function proxy_off(){
    unset http_proxy https_proxy
    echo -e "终端代理已关闭。"
}
EOF


# 安装zsh
if [[ "$INSTALL_ZSH" == "true" ]]; then

    wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh
    sed '/exec zsh -l/d' ./install.sh >./install_wo_exec.sh
    sh install_wo_exec.sh
    rm install.sh install_wo_exec.sh

    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
    git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
    git clone https://github.com/zsh-users/zsh-history-substring-search ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-history-substring-search
    sed "s/plugins=(git)/plugins=(git extract zsh-autosuggestions zsh-history-substring-search zsh-syntax-highlighting)/g" "${HOME}/.zshrc" >"${HOME}/.tmp_zshrc" && mv "${HOME}/.tmp_zshrc" "${HOME}/.zshrc"
fi

# export env
# echo '' >>"$HOME/.zshrc"
# echo 'export PATH=/root/siton-data-guoguodata/tcj/miniconda3/bin:$PATH' >>"$HOME/.zshrc"
# echo 'export PATH=/usr/local/cuda/bin:$PATH' >>"$HOME/.zshrc"
# echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >>"$HOME/.zshrc"


# # >>> conda initialize >>>
# # !! Contents within this block are managed by 'conda init' !!

# __conda_setup="$('/root/siton-data-guoguodata/tcj/miniconda3/bin/conda' 'shell.bash' 'hook' 2> /dev/null)"
# if [ $? -eq 0 ]; then
#     eval "$__conda_setup"
# else
#     if [ -f "/root/tcj/miniconda3/etc/profile.d/conda.sh" ]; then
#         . "/root/tcj/miniconda3/etc/profile.d/conda.sh"
#     else
#         export PATH="/root/siton-data-guoguodata/tcj/miniconda3/bin:$PATH"
#     fi
# fi
# unset __conda_setup
# # <<< conda initialize <<<