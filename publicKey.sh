#!/bin/bash

DEFAULT_SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJHNA3Rn5p5nrlW8kFUdO4sQzPcBVcQQSbnLiQXoIF4Y tcj@tcjMac"

# 检查是否以root用户运行脚本
if [ "$(id -u)" -ne 0 ]; then
  echo "请以root用户运行此脚本。" >&2
  exit 1
fi

# 要求用户输入公钥，直接回车则使用默认公钥
echo "请输入您的SSH公钥，直接回车使用默认公钥："
read -r ssh_public_key
if [ -z "$ssh_public_key" ]; then
  ssh_public_key="$DEFAULT_SSH_PUBLIC_KEY"
fi

# 确保.ssh目录存在
mkdir -p /root/.ssh

# 将公钥添加到authorized_keys文件中
echo "$ssh_public_key" >> /root/.ssh/authorized_keys

# 确保authorized_keys文件的权限正确
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

echo "PermitRootLogin prohibit-password已取消注释，公钥已添加到authorized_keys，并且SSH服务已重启。"
