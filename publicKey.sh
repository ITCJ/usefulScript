#!/bin/bash

# 检查是否以root用户运行脚本
if [ "$(id -u)" -ne 0 ]; then
  echo "请以root用户运行此脚本。" >&2
  exit 1
fi

# 要求用户输入公钥
echo "请输入您的SSH公钥："
read ssh_public_key

# 确保.ssh目录存在
mkdir -p /root/.ssh

# 将公钥添加到authorized_keys文件中
echo "$ssh_public_key" >> /root/.ssh/authorized_keys

# 确保authorized_keys文件的权限正确
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

echo "PermitRootLogin prohibit-password已取消注释，公钥已添加到authorized_keys，并且SSH服务已重启。"

