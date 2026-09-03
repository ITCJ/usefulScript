# SGLang v0.5.16 + Mooncake on Ascend A3

This package deploys SGLang Prefill/Decode disaggregation on Ascend A3 with
Mooncake Transfer Engine as the KV transfer layer.

See `RESEARCH.md` for the source-level compatibility analysis, the v0.5.16
documentation conflict, network behavior, and production acceptance gates.

Pinned versions:

- Base image: `quay.io/ascend/sglang:v0.5.16-cann9.0.0-a3`
- Mooncake NPU wheel: `mooncake-transfer-engine-npu==0.3.11.post1`
- Transfer path: SGLang `mooncake` backend with Mooncake `ascend` transport
- Metadata mode: `P2PHANDSHAKE`; no `mooncake_master` is required for PD transfer

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

The derived image also installs the runtime RDMA loader packages
`libibverbs1`, `ibverbs-providers`, and `rdma-core`. Mooncake's NPU wheel links
its common engine objects against `libibverbs.so.1` even when the selected data
transport is Ascend Direct/ADXL.

## Topologies

Single A3 server (default):

```text
client -> router:8000
              |-> prefill:30000, bootstrap:8998, NPU 0-15
              `-> decode:30001,                 NPU 16-31
                    Mooncake Ascend Direct KV transfer
```

Two A3 servers:

```text
router -> prefill node:30000/8998, NPU 0-15
       -> decode node:30001,      NPU 0-15
          Mooncake Ascend Direct over the nodes' HCCS/RDMA-capable fabric
```

The scripts use `--network host` and `--ipc host`, map the selected NPU device
nodes, mount the host driver/firmware, and use a 64 GiB shared-memory default.

The Prefill and Decode worker containers also mount these host directories
read-write by default:

```text
/home/tcj
/home/caofei
/home/cryang_wx15110221
```

They are configured by the comma-separated `REQUIRED_HOME_MOUNTS` setting.
`preflight.sh` fails early if any configured directory is absent. The Router is
a lightweight network process and does not mount user home directories.

### Mount and runtime-option classification

Compared with `usefulScript/ascend_env/docker_run.sh`:

| Item | Decision | Reason |
| --- | --- | --- |
| `/home/tcj`, `/home/caofei`, `/home/cryang_wx15110221` | Worker required, read-write | Requested shared model/workspace access; validated before startup |
| `/usr/local/Ascend/driver` | Required, read-only | Host NPU driver runtime |
| `/usr/local/Ascend/driver/lib64` | Covered by driver mount | Do not add a duplicate child bind mount |
| `/usr/local/Ascend/driver/version.info` | Covered by driver mount | Do not add a duplicate child bind mount |
| `/usr/local/Ascend/driver/tools/hccn_tool` | Covered by driver mount | Used by preflight when it is not available in `PATH` |
| `/usr/local/Ascend/firmware` | Keep when present, read-only | Used by the official SGLang A3 container pattern |
| `/usr/local/Ascend/add-ons` | Keep when present, read-only | Host driver/add-on libraries that some Ascend installations require |
| `/usr/local/dcmi` | Keep when present, read-only | Official CANN container reference uses it for device management |
| `/usr/local/sbin` | Keep, read-only | Provides `npu-smi` and host Ascend management tools |
| Dedicated `npu-smi` mount | Not needed | Already covered by the whole `/usr/local/sbin` mount |
| `/etc/ascend_install.info` | Keep when present, read-only | Host driver/install metadata discovery |
| `/etc/hccn.conf` | Required, read-only | Mooncake Ascend Direct obtains local NPU network information from it |
| `/var/queue_schedule` | Keep when present | A3 queue scheduling runtime integration |
| `/dev/infiniband`, `/sys/class/infiniband` | Not used by default | Needed by Mooncake generic mlx5 `rdma` transport, not ADXL `ascend` transport |
| `/dev/socket` | Do not mount | Not present in the CANN/SGLang/Mooncake Ascend references and exposes unspecified host sockets |
| `slog`, profiling, dump paths | Optional | Enabled with `ENABLE_NPU_DIAGNOSTIC_MOUNTS=1` only for diagnostics |
| `/tmp:/tmp` | Not mounted | Mooncake PD does not require shared files; avoids cross-container collisions |
| `--init` | Enabled | Correct signal forwarding and child reaping |
| `--user 0:0` | Enabled | Makes the base image's root execution convention explicit |
| `--entrypoint /usr/bin/tini` | Not used | Redundant with `--init` and conflicts with the worker service entrypoint |
| `--privileged` | Optional | `USE_PRIVILEGED=1`; explicit devices/capabilities are the safer default |

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
- Allow the Ascend Direct ranges. With the defaults and physical NPU 0-15,
  prefill uses roughly TCP 20000-21600 and decode 24000-25600 (each device owns
  a 100-port selection window; include both endpoints and operational margin).
- SGLang v0.5.16 also obtains a free host TCP port for each Mooncake endpoint.
  Allow the host's `net.ipv4.ip_local_port_range` bidirectionally on the trusted
  inference network, or enforce an equivalent host-level port policy outside
  SGLang. Do not expose these ports to an untrusted network.
- Ensure the service IP selected through `SGLANG_HOST_IP` is routable between P
  and D nodes. Do not use `127.0.0.1` in split mode.

## Important settings

- Do not replace `--disaggregation-transfer-backend mooncake` with `ascend` in
  these scripts. In v0.5.16, `ascend` selects `memfabric-hybrid`; this package is
  specifically for the Mooncake NPU wheel and Ascend Direct transport.
- `ENABLE_ASCEND_TRANSFER_WITH_MOONCAKE=true` makes SGLang initialize Mooncake
  with protocol `ascend` rather than CUDA-style `rdma`.
- `ASCEND_NPU_PHY_ID=-1` is intentional. Each TP rank uses its own NPU ID. A
  single fixed physical ID is only appropriate for a one-NPU process/container.
- `--disaggregation-ib-device` is intentionally omitted because it belongs to
  Mooncake's generic RDMA HCA-selection path, not Ascend Direct.
- `PREFILL_ASCEND_BASE_PORT` and `DECODE_ASCEND_BASE_PORT` are separated to
  avoid same-host P/D port-range collisions.
- Worker containers use Docker `--init` and run explicitly as root, matching the
  established Ascend environment startup convention. A separate `tini`
  entrypoint is not used because `--init` already provides PID 1 signal and
  child-process handling.
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

## Scope note: Mooncake Store / HiCache

Mooncake PD transfer and Mooncake Store are separate features. This deployment
uses point-to-point KV transfer only. Do not add `--enable-hierarchical-cache
--hicache-storage-backend mooncake` unless you also intend to deploy and size a
Mooncake distributed store. In the v0.5.16 Ascend feature matrix, the documented
HiCache storage backend is `file`; Mooncake Store on Ascend should therefore be
treated as a separate compatibility-validation project rather than enabled by
default here.
