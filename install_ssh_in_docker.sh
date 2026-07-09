#!/bin/bash

SSH_PORT="${SSH_PORT:-2223}"
# apt-get update
apt-get install -y openssh-server

# 检查是否以root用户运行脚本
if [ "$(id -u)" -ne 0 ]; then
  echo "请以root用户运行此脚本。" >&2
  exit 1
fi

# 备份sshd_config文件
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# 取消注释PermitRootLogin prohibit-password配置
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

# 配置SSH监听端口，默认2223，可通过环境变量SSH_PORT覆盖
if grep -qE '^[#[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
  sed -i "s/^[#[:space:]]*Port[[:space:]].*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
else
  echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config
fi

# 重启SSH服务以应用更改
if [ -f /etc/debian_version ]; then
  service ssh restart  
elif [ -f /etc/redhat-release ]; then
  systemctl restart sshd
else
  echo "未知的操作系统，无法自动重启SSH服务。请手动重启SSH服务。" >&2
  exit 1
fi

echo "PermitRootLogin prohibit-password已取消注释，SSH端口已设置为${SSH_PORT}，并且SSH服务已重启。"





