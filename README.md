# usefulScript

## Docker 普通用户权限

配置当前用户：

```bash
./add_usr_to_docker_group.sh
```

配置指定用户：

```bash
./add_usr_to_docker_group.sh <username>
```

脚本会执行以下操作：

1. 创建标准的 `docker` 组。
2. 将用户加入 `docker` 组。
3. 将 `/usr/bin/docker` 修复为 `root:root`、权限 `0755`。
4. 将 `/var/run/docker.sock` 修复为 `root:docker`、权限 `0660`。
5. 输出最终权限，并在当前会话已经具有 `docker` 组权限时测试连接。

完成后重新登录，或运行 `newgrp docker` 刷新当前终端的组权限。

注意：`docker` 组成员可以通过 Docker 获得接近 root 的主机权限，只应加入可信用户。

## Ubuntu APT 换源

运行脚本后，按照菜单选择镜像站：

```bash
./ubuntu_change_mirror.sh
```

支持 `official`、`aliyun`、`tuna`、`ustc` 和 `custom`。脚本会自动识别
Ubuntu 版本代号、CPU 架构以及传统 `sources.list`/DEB822 格式，并在修改前备份。
安全更新默认保留 Ubuntu 官方源。
