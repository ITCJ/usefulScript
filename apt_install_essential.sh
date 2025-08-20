
sed -i 's@//.*archive.ubuntu.com@//mirrors.ustc.edu.cn@g' /etc/apt/sources.list

apt update && apt install -y vim git curl wget openssh-server rsync nvtop htop uv zsh

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

# oh my zsh
cd /gaojiawei/tcj/ohmyzsh/tools
REMOTE=https://mirrors.tuna.tsinghua.edu.cn/git/ohmyzsh.git sh install.sh