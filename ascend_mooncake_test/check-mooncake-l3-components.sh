#!/usr/bin/env bash
set -Eeo pipefail

echo "[component-check] architecture=$(uname -m)"

# Avoid vendor set_env.sh in checks. The host driver is mounted at this path and
# the CANN runtime is already present in the derived image.
export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/ascend-toolkit/latest/lib64:${LD_LIBRARY_PATH:-}"

master_command=$(command -v mooncake_master 2>/dev/null || true)
[[ -n "${master_command}" ]] || {
  echo "[component-check] mooncake_master command not found" >&2
  exit 1
}
echo "[component-check] mooncake_master=${master_command}"

jemalloc_so=$(find /usr/lib /lib -name libjemalloc.so.2 -print -quit 2>/dev/null)
[[ -n "${jemalloc_so}" ]] || {
  echo "[component-check] libjemalloc.so.2 not found" >&2
  exit 1
}
echo "[component-check] jemalloc=${jemalloc_so}"

export LD_PRELOAD="${jemalloc_so}${LD_PRELOAD:+:${LD_PRELOAD}}"

python3 -u - <<'PY'
import os
import torch
import torch_npu  # noqa: F401

logical_device_id = int(os.environ.get("MOONCAKE_STORE_LOGICAL_NPU_ID", "0"))
device_count = torch.npu.device_count()
if device_count <= logical_device_id:
    raise RuntimeError(
        f"Store component check requires logical NPU {logical_device_id}, "
        f"but torch_npu sees {device_count} device(s)"
    )
torch.npu.set_device(logical_device_id)
print(
    "Mooncake Store Ascend context check: OK",
    f"logical_device={logical_device_id}",
    f"visible_device_count={device_count}",
)

from mooncake.store import MooncakeDistributedStore, MooncakeHostMemAllocator

print("Mooncake L3 components import: OK")
print("MooncakeDistributedStore:", MooncakeDistributedStore)
print("MooncakeHostMemAllocator:", MooncakeHostMemAllocator)
PY

echo "[component-check] passed"
