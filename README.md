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
