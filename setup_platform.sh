
sed -i 's@//.*archive.ubuntu.com@//mirrors.ustc.edu.cn@g' /etc/apt/sources.list

apt update && apt install -y vim git curl wget openssh-server rsync nvtop htop

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