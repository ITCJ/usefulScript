
sed -i 's@//.*archive.ubuntu.com@//mirrors.ustc.edu.cn@g' /etc/apt/sources.list

apt update && apt install -y vim git curl wget openssh-server rsync nvtop htop zsh git pip tmux

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

# 替换服务器指纹密钥
echo "Replacing SSH host keys..."
rm /root/.ssh/id_rsa /root/.ssh/id_rsa.pub
# 复制新的密钥文件
cp /gaojiawei/server_con_keys/id_ed25519 /root/.ssh/id_ed25519_key
cp /gaojiawei/server_con_keys/id_ed25519.pub /root/.ssh/id_ed25519_key.pub

cp /gaojiawei/server_con_keys/id_ed25519 /etc/ssh/ssh_host_ed25519_key
cp /gaojiawei/server_con_keys/id_ed25519.pub /etc/ssh/ssh_host_ed25519_key.pub 

# 设置正确的权限
chmod 600 /root/.ssh/id_ed25519_key
chmod 644 /root/.ssh/id_ed25519_key.pub
chmod 600 /etc/ssh/id_ed25519_key
chmod 644 /etc/ssh/id_ed25519_key.pub
chown root:root /root/.ssh/id_ed25519_key /root/.ssh/id_ed25519_key.pub
echo "SSH host keys replaced successfully!"



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



# uv ()
pip install uv
uv python install 3.12.12
uv python install 3.12.11


#time zone
apt-get install -y tzdata
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

