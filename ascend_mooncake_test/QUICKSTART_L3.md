# SGLang Ascend 双机 Mooncake L3 最简部署

更新时间：2026-09-06

## 1. 部署拓扑

```text
Prefill A3（61.28.30.27）
  ├─ Mooncake Master/Metadata
  ├─ Mooncake Store：贡献 16GB DRAM
  ├─ SGLang Prefill：TP=16
  └─ L2 Host Cache：1GB/rank，整机约 16GB

Decode A3（61.28.30.28）
  ├─ Mooncake Store：贡献 16GB DRAM
  ├─ SGLang Decode：TP=16
  └─ L2 Host Cache：1GB/rank，整机约 16GB

Mooncake L3总容量：32GB
P/D KV传输：SGLang Ascend MemFabric（device_rdma）
L2/L3传输：Mooncake Store TCP
```

这是实验性 Ascend L3配置。先使用 TCP 验证，不要直接切换 Host RDMA。

## 2. 两台节点准备

两台机器使用相同分支、脚本和镜像：

```bash
git switch tcj-debug/print_our_tensor
git pull origin tcj-debug/print_our_tensor

cd ascend_mooncake_test
./static-check.sh

docker image inspect \
  sglang-ascend-mooncake:v0.5.16-cann9.0.0-a3-mc0.3.11.post1 \
  --format '{{.Id}} {{.Architecture}}'
```

两台机器的镜像 ID 应相同，架构应为 `arm64`。

两台节点都要确认：

```bash
npu-smi info -l
test -s /etc/hccn.conf
ls /dev/davinci{0..15}
```

## 3. 配置 deploy.env

两台机器使用同一份关键配置：

```bash
DEPLOY_MODE=split
PREFILL_IP=61.28.30.27
DECODE_IP=61.28.30.28

NPU_COUNT_PER_ROLE=16
TP_SIZE=16

MODEL_HOST_PATH=/home/c60040001/ds3.1
MODEL_CONTAINER_PATH=/models/model

ENABLE_MOONCAKE_L3=1
MOONCAKE_MASTER_IP=${PREFILL_IP}
MOONCAKE_MASTER_PORT=50051
MOONCAKE_METADATA_PORT=8080
MOONCAKE_STORE_PORT=8081

MOONCAKE_STORE_GB=16
MOONCAKE_STORE_PROTOCOL=tcp
MOONCAKE_STORE_DEVICE=
MOONCAKE_STORE_NPU_ID=0

PD_TRANSFER_BACKEND=ascend
ASCEND_MF_STORE_URL=tcp://${PREFILL_IP}:24670
ASCEND_MF_TRANSFER_PROTOCOL=device_rdma

HICACHE_L2_GB_PER_RANK=1
HICACHE_IO_BACKEND=kernel_ascend
HICACHE_MEM_LAYOUT=page_first_kv_split
HICACHE_WRITE_POLICY=write_through
HICACHE_PREFETCH_POLICY=timeout

ENABLE_DECODE_HICACHE=1
ENABLE_DECODE_KV_OFFLOAD=1
```

不要在运行 P/D 服务时保留外部 HTTP代理；如果必须保留，`no_proxy` 至少包含：

```bash
export no_proxy='127.0.0.1,localhost,61.28.30.27,61.28.30.28'
export NO_PROXY="${no_proxy}"
```

## 4. 启动 Prefill 节点

必须先启动 Prefill节点，因为 Mooncake Master运行在此节点：

```bash
cd ascend_mooncake_test
./start-l3-node.sh prefill
```

该命令依次执行：

```text
基础预检
→ L3内存和组件预检
→ Mooncake Master/Metadata
→ Prefill Store（贡献16GB）
→ SGLang Prefill
```

检查：

```bash
docker ps --filter name=sglang-mc
docker logs --tail 100 sglang-mc-mooncake-master
docker logs --tail 100 sglang-mc-mooncake-store
docker logs --tail 100 sglang-mc-prefill
```

Prefill节点应有：

```text
sglang-mc-mooncake-master
sglang-mc-mooncake-store
sglang-mc-prefill
```

## 5. 启动 Decode 节点

确认 Decode能访问 Prefill Master：

```bash
timeout 2 bash -c 'exec 3<>/dev/tcp/61.28.30.27/50051'
timeout 2 bash -c 'exec 3<>/dev/tcp/61.28.30.27/8080'
```

然后启动：

```bash
cd ascend_mooncake_test
./start-l3-node.sh decode
```

该命令依次执行：

```text
基础预检
→ L3预检和远程Master检查
→ Decode Store（贡献16GB）
→ SGLang Decode
```

检查：

```bash
docker ps --filter name=sglang-mc
docker logs --tail 100 sglang-mc-mooncake-store
docker logs --tail 100 sglang-mc-decode
```

Decode节点应有：

```text
sglang-mc-mooncake-store
sglang-mc-decode
```

## 6. 检查 L3和启动 Router

任意能够访问两台节点的部署节点执行：

```bash
./check-mooncake-l3.sh
```

四个端点都应为 `READY`：

```text
61.28.30.27:50051  Mooncake Master
61.28.30.27:8080   Metadata
61.28.30.27:8081   Prefill Store
61.28.30.28:8081   Decode Store
```

两个 SGLang Worker健康后启动 Router：

```bash
./wait-workers.sh
./start-router.sh
./smoke-test.sh
```

## 7. 成功判据

P/D 健康：

```text
prefill is healthy
decode is healthy
```

Store日志：

```text
Store service started successfully
```

P/D 日志：

```text
Mooncake store setup successfully
Allocating ... GB host memory for hierarchical KV cache
```

Router冒烟请求能够返回生成文本，并且日志中没有：

```text
Traceback
Mooncake Transfer Engine initialization failed
Failed to setup Mooncake store
bootstrap timeout
waiting timeout
corrupted size vs. prev_size
```

## 8. 日志和诊断

```bash
# Prefill节点
./collect-diagnostics.sh master
./collect-diagnostics.sh store-prefill
./collect-diagnostics.sh prefill

# Decode节点
./collect-diagnostics.sh store-decode
./collect-diagnostics.sh decode
```

主要落盘日志：

```text
/var/log/sglang-mooncake/mooncake-master.log
/var/log/sglang-mooncake/mooncake-store-prefill.log
/var/log/sglang-mooncake/mooncake-store-decode.log
/var/log/sglang-mooncake/prefill.log
/var/log/sglang-mooncake/decode.log
/var/log/sglang-mooncake/router.log
```

## 9. 停止顺序

先在 Decode节点执行：

```bash
./stop.sh
```

再在 Prefill节点执行：

```bash
./stop.sh
```

停止顺序为：

```text
Router → P/D Worker → 本地 Store → Master
```

## 最简命令清单

Prefill节点：

```bash
cd ascend_mooncake_test
./start-l3-node.sh prefill
```

Decode节点：

```bash
cd ascend_mooncake_test
./start-l3-node.sh decode
```

Router节点：

```bash
cd ascend_mooncake_test
./check-mooncake-l3.sh
./wait-workers.sh
./start-router.sh
./smoke-test.sh
```
