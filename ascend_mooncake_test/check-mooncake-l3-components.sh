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
from mooncake.store import MooncakeDistributedStore, MooncakeHostMemAllocator

print("Mooncake L3 components import: OK")
print("MooncakeDistributedStore:", MooncakeDistributedStore)
print("MooncakeHostMemAllocator:", MooncakeHostMemAllocator)
PY

echo "[component-check] passed"
