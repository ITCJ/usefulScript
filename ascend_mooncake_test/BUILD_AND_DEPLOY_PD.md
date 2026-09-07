# SGLang Ascend：从镜像构建到 PD 推理部署

更新时间：2026-09-06

本文覆盖两节点 Ascend A3 环境，从派生镜像构建开始，到完成 SGLang Prefill/Decode（PD）推理并接入 Mooncake L3 DRAM Pool。

## 1. 部署拓扑

```text
Prefill A3：61.28.30.27
  ├─ Mooncake Master/Metadata
  ├─ Mooncake Store：贡献 16GB Host DRAM
  └─ SGLang Prefill：TP=16

Decode A3：61.28.30.28
  ├─ Mooncake Store：贡献 16GB Host DRAM
  └─ SGLang Decode：TP=16

Mooncake L3：32GB（2×16GB）
SGLang L2：1GB/TP rank，TP16 下约 16GB/节点
P/D KV：Mooncake Ascend Direct
L2/L3：Mooncake Store TCP
```

## 2. 前提

- 两节点均为 Atlas 800I A3。
- 每节点可访问 `/dev/davinci0` 至 `/dev/davinci15`。
- 主机驱动和 `/etc/hccn.conf` 已配置。
- 模型同时放在两节点，宿主机路径 `/home/c60040001/ds3.1`。
- 分支 `tcj-debug/print_our_tensor`。

```bash
cd /home/tcj/usefulScript
git switch tcj-debug/print_our_tensor
git pull origin tcj-debug/print_our_tensor
```

## 3. 配置

```bash
cd /home/tcj/usefulScript/ascend_mooncake_test
cp deploy.env.example deploy.env
vi deploy.env
```

必须修改或确认：

```bash
MODEL_HOST_PATH=/home/c60040001/ds3.1
MODEL_CONTAINER_PATH=/models/model

DEPLOY_MODE=split
PREFILL_IP=61.28.30.27
DECODE_IP=61.28.30.28

NPU_COUNT_PER_ROLE=16
TP_SIZE=16

REQUIRED_HOME_MOUNTS=/home/tcj,/home/caofei,/home/cryang_wx1511021

APT_PORTS_MIRROR=http://mirrors.ustc.edu.cn/ubuntu-ports

MOONCAKE_STORE_NPU_ID=0
USE_PRIVILEGED=1
```

若模型较小，可下调 `NPU_COUNT_PER_ROLE` 和 `TP_SIZE`；当前默认按 16 张 NPU 计算。

## 4. 构建派生镜像

在两台节点分别执行，或只在一台构建后 `docker save/load` 分发：

```bash
export http_proxy='http://USER:PASSWORD@PROXY:PORT'
export https_proxy="${http_proxy}"
export no_proxy='127.0.0.1,localhost,61.28.30.27,61.28.30.28'

./static-check.sh
./build-image.sh
```

构建完成后取消代理：

```bash
unset http_proxy https_proxy no_proxy
unset HTTP_PROXY HTTPS_PROXY NO_PROXY
```

检查镜像：

```bash
docker image inspect \
  sglang-ascend-mooncake:v0.5.16-cann9.0.0-a3-mc0.3.11.post1 \
  --format '{{.Id}} {{.Architecture}}'
```

两台镜像 ID 应一致，架构应为 `arm64`。

## 5. 预检

Prefill 节点：

```bash
./preflight.sh
./preflight-mooncake-l3.sh prefill
```

Decode 节点：

```bash
./preflight.sh
./preflight-mooncake-l3.sh decode
```

基础预检应在容器内显示：

```text
torch.npu.device_count: 16
Preflight passed
```

L3 预检应显示：

```text
Mooncake L3 preflight passed
```

## 6. Prefill 节点启动

第一次建议逐组件启动：

```bash
./start-mooncake-master.sh
./start-mooncake-store.sh prefill
./start-role.sh prefill
```

后续一键启动：

```bash
./start-l3-node.sh prefill
```

检查：

```bash
docker ps --filter name=sglang-mc
docker logs -f sglang-mc-mooncake-store
docker logs -f sglang-mc-prefill
```

关键日志：

```text
Mooncake Store Ascend context initialized
Store service started successfully
Mooncake store setup successfully
Allocating ... GB host memory for hierarchical KV cache
```

健康检查：

```bash
curl --fail http://61.28.30.27:30000/health
```

## 7. Decode 节点启动

```bash
./start-mooncake-store.sh decode
./start-role.sh decode
```

或一键启动：

```bash
./start-l3-node.sh decode
```

健康检查：

```bash
curl --fail http://61.28.30.28:30001/health
```

## 8. 检查 L3 并启动 Router

```bash
./check-mooncake-l3.sh
./wait-workers.sh
./start-router.sh
./smoke-test.sh
```

四端均应 `READY`：

```text
61.28.30.27:50051
61.28.30.27:8080
61.28.30.27:8081
61.28.30.28:8081
```

成功标志：

```text
prefill is healthy
decode is healthy
Router /health 通过
smoke-test 返回生成文本
```

## 9. 容器权限与 NPU 可见性

当前部署包已自动：

- 给所有容器挂载全部 `/dev/davinci*` 及三个管理设备。
- 使用 `USE_PRIVILEGED=1`。
- 以可写方式挂载 `/usr/local/Ascend/driver`。
- Prefill/Decode 显式设置 `ASCEND_RT_VISIBLE_DEVICES=0,1,...,15`。
- Preflight 在同一容器内验证 `torch.npu.device_count()`。
- Store 使用一张逻辑 NPU 并调用 `torch.npu.set_device(0)`。

若 `torch.npu.device_count()` 返回 0，优先检查：

```bash
ls -l /dev/davinci*
docker inspect --format '{{json .HostConfig.Devices}}' sglang-mc-prefill
```

## 10. 网络端口

两节点间需放通：

| 端口/范围 | 用途 |
|---:|---|
| 30000 | Prefill HTTP |
| 30001 | Decode HTTP |
| 8998 | PD Bootstrap |
| 8000 | Router |
| 50051 | Mooncake Master |
| 8080 | Mooncake Metadata |
| 8081 | Mooncake Store |
| 20000-21600 | Prefill Ascend Direct |
| 24000-25600 | Decode Ascend Direct |
| 临时端口 | Mooncake 动态 RPC |

## 11. 日志与诊断

```bash
./collect-diagnostics.sh master
./collect-diagnostics.sh store-prefill
./collect-diagnostics.sh prefill
./collect-diagnostics.sh store-decode
./collect-diagnostics.sh decode
```

落盘位置：

```text
/var/log/sglang-mooncake/
```

## 12. 停止

Decode 节点：

```bash
./stop.sh
```

Prefill 节点：

```bash
./stop.sh
```
