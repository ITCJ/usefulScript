
sed -i 's@//.*archive.ubuntu.com@//mirrors.ustc.edu.cn@g' /etc/apt/sources.list

apt update && apt install -y vim git curl wget openssh-server rsync nvtop htop zsh git pip tmux libnuma-dev lsof net-tools iputils-ping cuda-compat-13-1

apt-get update && apt-get install -y openssh-server

# 检查是否以root用户运行脚本
if [ "$(id -u)" -ne 0 ]; then
  echo "请以root用户运行此脚本。" >&2
  exit 1
fi

# 备份sshd_config文件
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# 取消注释PermitRootLogin prohibit-password配置
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

# 重启SSH服务以应用更改
if [ -f /etc/debian_version ]; then
  service ssh restart  
elif [ -f /etc/redhat-release ]; then
  systemctl restart sshd
else
  echo "未知的操作系统，无法自动重启SSH服务。请手动重启SSH服务。" >&2
  exit 1
fi

cat /gaojiawei/tcj/tcj_mac_con.pub >> ~/.ssh/authorized_keys

echo "Restoring User Keys..."
mkdir -p /root/.ssh
/bin/cp -f /gaojiawei/server_con_keys/id_ed25519 /root/.ssh/id_ed25519
/bin/cp -f /gaojiawei/server_con_keys/id_ed25519.pub /root/.ssh/id_ed25519.pub
chmod 600 /root/.ssh/id_ed25519
chmod 644 /root/.ssh/id_ed25519.pub

# 3. 替换服务器主机密钥 (决定指纹)
echo "Restoring Host Keys..."
/bin/cp -f /gaojiawei/server_con_keys/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key
/bin/cp -f /gaojiawei/server_con_keys/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ed25519_key.pub 

/bin/cp -f /gaojiawei/server_con_keys/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key
/bin/cp -f /gaojiawei/server_con_keys/ssh_host_rsa_key.pub /etc/ssh/ssh_host_rsa_key.pub 

# 设置 Host Key 的严格权限 (私钥必须是 600)
chmod 600 /etc/ssh/ssh_host_ed25519_key
chmod 644 /etc/ssh/ssh_host_ed25519_key.pub
chmod 600 /etc/ssh/ssh_host_rsa_key
chmod 644 /etc/ssh/ssh_host_rsa_key.pub
chown root:root /etc/ssh/ssh_host_ed25519_key*
chown root:root /etc/ssh/ssh_host_rsa_key*

# 5. 重启 SSH 服务以生效
echo "Restarting SSH service..."
systemctl restart sshd



# oh my zsh - fully automated installation
rm -rf /root/.oh-my-zsh
rm -rf /gaojiawei/tcj/ohmyzsh
echo "Installing Oh My Zsh..."
if [ ! -d "/gaojiawei/tcj/ohmyzsh" ]; then
    echo "Cloning Oh My Zsh repository..."
    git clone --depth=1 https://git.sjtu.edu.cn/sjtug/ohmyzsh.git /gaojiawei/tcj/ohmyzsh
    if [ $? -ne 0 ]; then
        echo "Failed to clone Oh My Zsh repository" >&2
        exit 1
    fi
fi

if [ -d "/gaojiawei/tcj/ohmyzsh/tools" ]; then
    cd /gaojiawei/tcj/ohmyzsh/tools
    REMOTE=https://git.sjtu.edu.cn/sjtug/ohmyzsh.git sh install.sh <<EOF
y
EOF
    if [ $? -ne 0 ]; then
        echo "Oh My Zsh installation failed" >&2
        exit 1
    fi
    echo "Oh My Zsh installed successfully!"
    
    # Change ZSH_THEME to ys and add TERM export
    echo "Configuring ZSH theme and terminal settings..."
    sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="ys"/' /root/.zshrc
    echo 'export TERM=xterm-256color' >> /root/.zshrc
    echo "ZSH configuration updated successfully!"
    
    # Set zsh as default shell
    echo "Setting zsh as default shell..."
    chsh -s $(which zsh)
    echo "Default shell set to zsh successfully!"
else
    echo "Oh My Zsh tools directory not found" >&2
    exit 1
fi

# add proxy on in zshrc/bashrc

# Define proxy helper functions and append them to root's bashrc and zshrc idempotently
proxy_functions=$(cat <<'EOF'
proxy_on() {
  export https_proxy="http://127.0.0.1:7899"
  export http_proxy="http://127.0.0.1:7899"
  export all_proxy="socks5://127.0.0.1:7899"
  echo "proxy_on"
}

proxy_off() {
  unset https_proxy http_proxy all_proxy
  echo "proxy_off"
}
EOF
)

for rc in /root/.bashrc /root/.zshrc; do
  if [ -f "$rc" ]; then
    if ! grep -q "proxy_on()" "$rc"; then
      echo "" >> "$rc"
      echo "$proxy_functions" >> "$rc"
      echo "Added proxy functions to $rc"
    else
      echo "proxy functions already present in $rc"
    fi
  else
    echo "$proxy_functions" > "$rc"
    echo "Created $rc with proxy functions"
  fi
done



# uv ()
pip install uv -i https://mirrors.ustc.edu.cn/pypi/simple 
uv python install 3.12.12 #faild due to network
# uv python install 3.12.11

# install latest python
# apt-get install -y software-properties-common
# apt-get install -y autoconf automake libtool

# install nsys
# https://docs.nvidia.com/nsight-systems/InstallationGuide/index.html
apt update
apt install -y --no-install-recommends gnupg
echo "deb http://developer.download.nvidia.com/devtools/repos/ubuntu$(source /etc/lsb-release; echo "$DISTRIB_RELEASE" | tr -d .)/$(dpkg --print-architecture) /" | tee /etc/apt/sources.list.d/nvidia-devtools.list
apt-key adv --fetch-keys http://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/7fa2af80.pub
apt update
apt install nsight-systems-cli -y

# time zone - install tzdata non-interactively
export DEBIAN_FRONTEND=noninteractive
echo "tzdata tzdata/Areas select Asia" | debconf-set-selections
echo "tzdata tzdata/Zones/Asia select Shanghai" | debconf-set-selections
apt-get install -y -q tzdata
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
unset DEBIAN_FRONTEND

nohup /gaojiawei/tcj/easytier-linux-x86_64/easytier-core --hostname hopper2 --machine-id hopper2 --config-server udp://112.124.12.70:22020/admin >/dev/null 2>&1 &

