# SGLang v0.5.16 + Mooncake on Ascend A3

从镜像构建到 PD/L3 推理的完整中文部署步骤见 `BUILD_AND_DEPLOY_PD.md`。

双机 L3 DRAM Pool最简运行步骤见 `QUICKSTART_L3.md`。

PD 最简运行顺序：

```bash
# Prefill节点
./start-l3-node.sh prefill

# Decode节点
./start-l3-node.sh decode

# Router节点
./check-mooncake-l3.sh
./wait-workers.sh
./start-router.sh
./smoke-test.sh
```

This package deploys SGLang Prefill/Decode disaggregation on Ascend A3. The
current default uses Ascend MemFabric for P/D KV transfer and Mooncake Store as
the independent HiCache L3 DRAM backend.

See `RESEARCH.md` for the source-level compatibility analysis, the v0.5.16
documentation conflict, network behavior, and production acceptance gates.

Pinned versions:

- Base image: `quay.io/ascend/sglang:v0.5.16-cann9.0.0-a3`
- Mooncake NPU wheel: `mooncake-transfer-engine-npu==0.3.11.post1`
- P/D transfer path: SGLang `ascend` backend with `memfabric-hybrid`
- L3 storage path: SGLang HiCache with Mooncake Store over TCP

## Why a derived image is required

SGLang v0.5.16 pins Mooncake 0.3.11.post1 in its general Docker build, but the
release's `docker/npu.Dockerfile` installs `memfabric-hybrid` and does not install
the Mooncake NPU wheel. `Dockerfile` adds the matching NPU wheel without replacing
SGLang, torch, torch_npu, CANN, or the NPU kernels from the supplied image.

## Building through an HTTP proxy

This directory contains the derived-image definition. The actual image is
created only when `build-image.sh` runs on a Docker host:

```text
sglang-ascend-mooncake:v0.5.16-cann9.0.0-a3-mc0.3.11.post1
```

If the server requires an authenticated proxy, export it only in the build
shell. Do not write the credential-bearing URL into `Dockerfile` or commit it in
`deploy.env`:

```bash
export http_proxy='http://USER:PASSWORD@PROXY_HOST:PORT'
export https_proxy="${http_proxy}"
export no_proxy="127.0.0.1,localhost,PREFILL_IP,DECODE_IP"

./build-image.sh
```

`build-image.sh` detects upper- and lower-case proxy variables and passes only
their names as Docker predefined proxy build arguments. Values are hidden from
script logging and are not persisted as image `ENV` values. `.dockerignore`
excludes `deploy.env` and common credential/log artifacts from the build context.

Pulling the Quay base image is performed by the Docker daemon. If the base image
is not already local and `docker pull` fails, configure the Docker daemon proxy
or load the base image locally with `docker load`. The `pip install` executed in
the Docker build uses the proxy exported in the build shell.

Proxy variables are not passed to Prefill, Decode, or Router by default. This
prevents internal PD traffic from being sent to the external proxy. If runtime
model downloads are required, configure a carefully scoped runtime proxy and a
`no_proxy` list containing localhost and both worker IPs; local model mounts are
preferred.

The derived image also installs the runtime packages `libibverbs1`,
`ibverbs-providers`, `rdma-core`, `librdmacm1`, `liburing2`, and `libjemalloc2`.
Mooncake's NPU wheel links its common engine objects against `libibverbs.so.1`
even when the selected data transport is Ascend Direct/ADXL. Jemalloc is also
required for stable teardown: without `libjemalloc.so.2`, importing
`mooncake.engine` can appear successful and then abort during Python shutdown
with `corrupted size vs. prev_size`.

On aarch64, jemalloc must also be loaded before torch_npu/CANN consumes the
process static-TLS reserve. Both the preflight Python process and the SGLang
worker entrypoint resolve `libjemalloc.so.2` through `ldconfig` and prepend it to
`LD_PRELOAD` before starting Python. Do not load jemalloc later through
`ctypes.CDLL`, which fails with `cannot allocate memory in static TLS block`.

APT mirrors are optional and configured in `deploy.env`:

```bash
# x86_64
APT_MIRROR=https://mirrors.ustc.edu.cn/ubuntu
APT_SECURITY_MIRROR=

# aarch64/ARM; use this instead of APT_MIRROR
APT_PORTS_MIRROR=http://mirrors.ustc.edu.cn/ubuntu-ports
```

`APT_SECURITY_MIRROR` is separate so the official Ubuntu security source can be
retained. During the build, the Dockerfile rewrites both traditional `.list`
files and DEB822 `.sources` files, prints the active source URLs, and then runs
`apt-get update` and package installation. Empty values leave the base image's
APT configuration unchanged.

## Topologies

Single A3 server (optional; TP16 requires 32 NPUs):

```text
client -> router:8000
              |-> prefill:30000, bootstrap:8998, NPU 0-15
              `-> decode:30001,                 NPU 16-31
                    Ascend MemFabric KV transfer
```

Two A3 servers (default):

```text
router -> prefill node:30000/8998, NPU 0-15
       -> decode node:30001,      NPU 0-15
          Ascend MemFabric device_rdma transfer
```

The scripts use `--network host` and `--ipc host`, map the selected NPU device
nodes, mount the host driver/firmware, and use a 64 GiB shared-memory default.

The Prefill and Decode worker containers also mount these host directories
read-write by default:

```text
/home/tcj
/home/caofei
/home/cryang_wx1511021
```

They are configured by the comma-separated `REQUIRED_HOME_MOUNTS` setting.
`preflight.sh` fails early if any configured directory is absent. The Router is
a lightweight network process and does not mount user home directories.

### Mount and runtime-option classification

Compared with `usefulScript/ascend_env/docker_run.sh`:

| Item | Decision | Reason |
| --- | --- | --- |
| `/home/tcj`, `/home/caofei`, `/home/cryang_wx1511021` | Worker required, read-write | Requested shared model/workspace access; validated before startup |
| `/usr/local/Ascend/driver` | Required, writable | Host NPU driver runtime |
| `/usr/local/Ascend/driver/lib64` | Covered by driver mount | Do not add a duplicate child bind mount |
| `/usr/local/Ascend/driver/version.info` | Covered by driver mount | Do not add a duplicate child bind mount |
| `/usr/local/Ascend/driver/tools/hccn_tool` | Covered by driver mount | Used by preflight when it is not available in `PATH` |
| `/usr/local/Ascend/firmware` | Keep when present, read-only | Used by the official SGLang A3 container pattern |
| `/usr/local/Ascend/add-ons` | Keep when present, read-only | Host driver/add-on libraries that some Ascend installations require |
| `/usr/local/dcmi` | Keep when present, read-only | Official CANN container reference uses it for device management |
| `/usr/local/sbin` | Keep, read-only | Provides `npu-smi` and host Ascend management tools |
| Dedicated `npu-smi` mount | Not needed | Already covered by the whole `/usr/local/sbin` mount |
| `/etc/ascend_install.info` | Keep when present, read-only | Host driver/install metadata discovery |
| `/etc/hccn.conf` | Required, read-only | Ascend device RDMA/HCCL obtains local NPU network information from it |
| `/var/queue_schedule` | Keep when present | A3 queue scheduling runtime integration |
| `/dev/infiniband`, `/sys/class/infiniband` | Not used by default | Needed by Mooncake generic mlx5 `rdma` transport, not ADXL `ascend` transport |
| `/dev/socket` | Do not mount | Not present in the CANN/SGLang/Mooncake Ascend references and exposes unspecified host sockets |
| `slog`, profiling, dump paths | Optional | Enabled with `ENABLE_NPU_DIAGNOSTIC_MOUNTS=1` only for diagnostics |
| `/tmp:/tmp` | Not mounted | Mooncake PD does not require shared files; avoids cross-container collisions |
| `--init` | Optional, default off | Enable with `USE_DOCKER_INIT=1` only when the host includes `docker-init` |
| `--user 0:0` | Enabled | Makes the base image's root execution convention explicit |
| `--entrypoint /usr/bin/tini` | Not used | The worker entrypoint already uses `exec`; no extra init binary is required for the baseline |
| `--privileged` | Enabled by default | Required for NPU visibility on several Ascend container hosts |

## Single-node deployment

```bash
cd /Users/tcj/Sync/prj_hw/usefulScript/ascend_mooncake_test
cp deploy.env.example deploy.env
vi deploy.env

./build-image.sh
./preflight.sh
./start-single-node.sh
./wait-workers.sh
./start-router.sh
./smoke-test.sh
```

At minimum, set `MODEL_HOST_PATH`. For a model smaller than sixteen NPUs, lower
`NPU_COUNT_PER_ROLE` and `TP_SIZE`; decode starts at `NPU_COUNT_PER_ROLE` in
single-node mode. With the defaults, single-node mode requires 32 NPU device
nodes; a standard 16-NPU A3 server should use the two-node deployment instead.

## Two-node deployment

Use the same `deploy.env` on both nodes:

```bash
DEPLOY_MODE=split
PREFILL_IP=10.10.10.11
DECODE_IP=10.10.10.12
HCCL_SOCKET_IFNAME=enp189s0f0
GLOO_SOCKET_IFNAME=enp189s0f0
```

### Two-node Mooncake L3 DRAM pool

The default L3 topology runs Mooncake Master and embedded metadata on the
Prefill A3, plus one Store contributor on each A3:

```text
Prefill A3
  Mooncake Master       :50051
  Embedded Metadata     :8080
  Mooncake Store        :8081, contributes 16GB DRAM
  SGLang Prefill        L2=1GB per TP rank, TP16 ~= 16GB aggregate

Decode A3
  Mooncake Store        :8081, contributes 16GB DRAM
  SGLang Decode         L2=1GB per TP rank, TP16 ~= 16GB aggregate

Shared L3 capacity      16GB + 16GB = 32GB
P/D KV transfer         SGLang Ascend MemFabric/device_rdma
L2/L3 transfer          Mooncake Store over TCP for baseline validation
```

Relevant `deploy.env` defaults:

```bash
ENABLE_MOONCAKE_L3=1
MOONCAKE_MASTER_IP=${PREFILL_IP}
MOONCAKE_MASTER_PORT=50051
MOONCAKE_METADATA_PORT=8080
MOONCAKE_STORE_PORT=8081
MOONCAKE_STORE_GB=16
MOONCAKE_STORE_PROTOCOL=tcp
MOONCAKE_STORE_NPU_ID=0
PD_TRANSFER_BACKEND=ascend
ASCEND_MF_STORE_URL=tcp://${PREFILL_IP}:24670
ASCEND_MF_TRANSFER_PROTOCOL=device_rdma
HICACHE_L2_GB_PER_RANK=1
ENABLE_DECODE_HICACHE=1
ENABLE_DECODE_KV_OFFLOAD=1
```

The Store services contribute the DRAM pool, so both SGLang clients pass
`global_segment_size=0`. `start-role.sh` automatically adds HiCache parameters
when `ENABLE_MOONCAKE_L3=1`. Decode also enables PD decode radix cache and
incremental KV offload to L3.

The installed Store wheel is the Ascend NPU build. Even when Store payload uses
`tcp`, its native components need a valid CANN device context on A3. Each Store
container therefore maps one host NPU (default `/dev/davinci0`) plus the common
Ascend management devices, restricts visibility with
`ASCEND_RT_VISIBLE_DEVICES`, and calls `torch.npu.set_device(0)` in the same
long-running Python process before importing Mooncake Store. Store payload still
uses Host DRAM; this NPU context is only for the Ascend-enabled runtime.

Run on the Prefill node first:

```bash
./start-l3-node.sh prefill
```

This performs the normal preflight, L3 memory/component preflight, starts
Master/Metadata, starts the local Store, then starts SGLang Prefill.

Run on the Decode node after the Master is reachable:

```bash
./start-l3-node.sh decode
```

This checks the remote Master/Metadata, starts the Decode Store, then starts
SGLang Decode. After both workers are healthy, run on the Router node:

```bash
./check-mooncake-l3.sh
./wait-workers.sh
./start-router.sh
./smoke-test.sh
```

Inspect services:

```bash
docker logs -f sglang-mc-mooncake-master
docker logs -f sglang-mc-mooncake-store
docker logs -f sglang-mc-prefill
docker logs -f sglang-mc-decode
```

`stop.sh` stops Router, P/D workers, the local Store, and the Master when it is
present. Run it on Decode first and Prefill second.

The initial Store protocol is TCP intentionally. Switching Store L3 to generic
RDMA requires host RDMA NIC selection and `/dev/infiniband` mounts; it is
separate from the NPU ADXL path used for P/D transfer.

Build or load the derived image on both nodes, then run:

```bash
# Prefill node
./preflight.sh
./start-role.sh prefill

# Decode node
./preflight.sh
./start-role.sh decode

# Either node, after both workers are healthy
./wait-workers.sh
./start-router.sh
./smoke-test.sh
```

Network requirements for split mode:

- Allow `PREFILL_HTTP_PORT`, `DECODE_HTTP_PORT`, and `PREFILL_BOOTSTRAP_PORT`.
- Allow `ASCEND_MF_STORE_URL` (default `61.28.30.27:24670`) from both nodes.
- Ensure the NPU device-RDMA/HCCL network is configured and mutually reachable.
- Mooncake L3 Store over TCP still uses dynamic Mooncake RPC/data ports; allow
  the trusted-node ranges and host ephemeral ports required by that path.
- Ensure the service IP selected through `SGLANG_HOST_IP` is routable between P
  and D nodes. Do not use `127.0.0.1` in split mode.

## Important settings

- `PD_TRANSFER_BACKEND=ascend` is the default and selects `memfabric-hybrid` for
  P/D KV transfer. Both nodes must use the same `ASCEND_MF_STORE_URL`.
- `ASCEND_MF_TRANSFER_PROTOCOL=device_rdma` is used for the two-node A3 path.
- Mooncake remains enabled independently as the HiCache L3 storage backend;
  `MOONCAKE_STORE_PROTOCOL=tcp` controls L2/L3 transfer only.
- The legacy `PD_TRANSFER_BACKEND=mooncake` path is retained for comparison but
  is not recommended with Mooncake NPU 0.3.11.post1 because its Ascend Direct
  endpoint can be malformed as `IP:RPC_PORT:ADXL_PORT`.
- Worker containers run explicitly as root. Docker `--init` is disabled by
  default because some Ascend server Docker packages omit the `docker-init`
  executable. Set `USE_DOCKER_INIT=1` only after verifying the host supports it;
  the worker and router commands already use `exec` for direct signal delivery.
- `/usr/local/Ascend/add-ons` and `/etc/localtime` are mounted read-only when
  present. The whole `/usr/local/sbin` is already mounted, so a second dedicated
  `npu-smi` bind mount is unnecessary.
- `/etc/hccn.conf` is required and mounted read-only. `preflight.sh` also calls
  `hccn_tool` when available to display the NPU network IP for every selected
  physical device.
- `ASCEND_AUTO_CONNECT=1` is enabled for CANN 9.0. Set
  `HCCL_INTRA_ROCE_ENABLE=1` only when the verified topology should use the NPU
  RoCE/RDMA path instead of the default HCCS path. RDMA TC/SL, retry, and timeout
  variables are exposed in `deploy.env` but left unset for baseline validation.
- `/tmp:/tmp` is intentionally not mounted: Mooncake PD transfer uses network
  endpoints, not a shared filesystem, and a host-wide writable `/tmp` creates
  avoidable cross-container interference.
- Set `ENABLE_NPU_DIAGNOSTIC_MOUNTS=1` only when host `slog`, profiling, or dump
  collection is required. These writable diagnostic mounts are not needed for
  normal serving.
- `USE_PRIVILEGED=1` remains available for hosts whose driver policy requires
  it. The default uses explicit NPU device mappings and capabilities so Prefill
  and Decode retain their intended device boundary.
- The first deployment should keep `EXTRA_PREFILL_ARGS` and
  `EXTRA_DECODE_ARGS` empty. Add model-specific quantization, MoE, DP-attention,
  graph, or speculative decoding flags only after the basic PD path passes.

## Validation and troubleshooting

```bash
docker ps --filter name=sglang-mc
docker logs -f sglang-mc-prefill
docker logs -f sglang-mc-decode
docker logs -f sglang-mc-router

grep -E "Mooncake|Ascend|Transfer Engine|ERROR|Traceback" \
  /var/log/sglang-mooncake/*.log
```

Expected worker logs include successful Mooncake Transfer Engine initialization
and Ascend transport startup. Common failures:

- `No module named mooncake`: the derived image was not used.
- `libibverbs.so.1: cannot open shared object file`: an older copy of the
  derived image is still in use; rebuild with `./build-image.sh` on both nodes.
- `corrupted size vs. prev_size` followed by exit code 134 after
  `Mooncake TransferEngine import: OK`: `libjemalloc2` is missing from an older
  derived image. Rebuild the updated image on both nodes; do not mask this with
  `os._exit()`.
- `OSError: libjemalloc.so.2: cannot allocate memory in static TLS block`: an
  older preflight loaded jemalloc through `ctypes` after importing torch_npu.
  Update the scripts; the fixed preflight and worker entrypoint use
  `LD_PRELOAD` before Python starts.
- `can't get ascend_hal device count`: NPU character devices or host driver
  mounts are missing. The updated `preflight.sh` maps the selected NPUs and
  validates `torch.npu.device_count()` inside the same runtime image.
- `can not use command npu-smi info`: ensure the host has `npu-smi` in PATH,
  `/usr/local/bin`, or `/usr/local/sbin`; preflight now mounts and runs it in the
  validation container.
- `Failed to install Ascend transport`: the generic Mooncake wheel was installed
  instead of `mooncake-transfer-engine-npu`, or CANN/driver libraries mismatch.
- Peer/bootstrap timeout: `PREFILL_IP`, bootstrap port, dynamic Mooncake RPC
  ports, or Ascend Direct port ranges are blocked/unroutable.
- Invalid/wrong NPU endpoint: a remapped visibility scheme conflicts with
  `--base-gpu-id`; first test without `ASCEND_RT_VISIBLE_DEVICES` remapping.
- HCCL or Gloo binds the wrong NIC: set both socket interface variables.

Stop all local components with:

```bash
./stop.sh
```

Run local script/Dockerfile regression checks with:

```bash
./static-check.sh
```

Collect an exited or running worker/router diagnostic bundle before restarting
or deleting its container:

```bash
./collect-diagnostics.sh prefill
./collect-diagnostics.sh decode
./collect-diagnostics.sh router
./collect-diagnostics.sh master
./collect-diagnostics.sh store-prefill
./collect-diagnostics.sh store-decode
```

The command creates `sglang-mc-<role>-diagnostics-<timestamp>.tar.gz` in the
current directory. It captures state, exit/OOM information, the actual command,
mounts, device mappings, Docker/host logs, NPU/HCCN information, image metadata,
and runtime library/package checks. It deliberately does not export the full
container environment or copy `deploy.env`, preventing proxy credentials from
being placed in the archive. Review logs for internal IPs and model paths before
sharing the bundle.

## Scope note: Mooncake Store / HiCache

Mooncake PD transfer and Mooncake Store are separate features. This deployment
uses point-to-point KV transfer only. Do not add `--enable-hierarchical-cache
--hicache-storage-backend mooncake` unless you also intend to deploy and size a
Mooncake distributed store. In the v0.5.16 Ascend feature matrix, the documented
HiCache storage backend is `file`; Mooncake Store on Ascend should therefore be
treated as a separate compatibility-validation project rather than enabled by
default here.
