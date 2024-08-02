#!/bin/bash

# 检查是否提供了install_home参数
if [ -z "$1" ]; then
  echo "请提供Miniconda的安装路径，例如：$0 /path/to/install/miniconda3"
  exit 1
fi

INSTALL_HOME="$1"
mkdir -p "$INSTALL_HOME"

# 下载Miniconda安装脚本到指定目录
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O "$INSTALL_HOME/miniconda.sh"

# bash $INSTALL_HOME/miniconda.sh -u -p $INSTALL_HOME   
bash $INSTALL_HOME/miniconda.sh -b -u -p $INSTALL_HOME  #silent mode

$INSTALL_HOME/bin/conda init bash
$INSTALL_HOME/bin/conda init zsh