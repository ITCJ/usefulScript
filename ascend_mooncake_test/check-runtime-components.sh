#!/usr/bin/env bash
set -Eeo pipefail

echo "[runtime-check] architecture=$(uname -m)"
export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/ascend-toolkit/latest/lib64:${LD_LIBRARY_PATH:-}"

npu_smi_bin=$(command -v npu-smi 2>/dev/null || true)
[[ -n "${npu_smi_bin}" ]] || npu_smi_bin=/usr/local/bin/npu-smi
[[ -x "${npu_smi_bin}" ]] || npu_smi_bin=/usr/local/sbin/npu-smi
if [[ -x "${npu_smi_bin}" ]]; then
  if "${npu_smi_bin}" info -l; then
    echo "[runtime-check] npu-smi summary completed successfully"
  else
    npu_smi_rc=$?
    echo "[runtime-check] WARNING: npu-smi returned rc=${npu_smi_rc}; continuing with torch_npu validation"
  fi
else
  echo "[runtime-check] npu-smi is not visible" >&2
  exit 1
fi

for library_name in libibverbs.so.1 libjemalloc.so.2; do
  if ldconfig -p | grep -F "${library_name}" >/dev/null; then
    echo "[runtime-check] ${library_name}: found"
  else
    echo "[runtime-check] ${library_name}: missing; rebuild with ./build-image.sh" >&2
    exit 1
  fi
done

jemalloc_so=$(find /usr/lib /lib -name libjemalloc.so.2 -print -quit 2>/dev/null)
[[ -n "${jemalloc_so}" ]] || {
  echo "[runtime-check] unable to resolve libjemalloc.so.2 path" >&2
  exit 1
}
export LD_PRELOAD="${jemalloc_so}${LD_PRELOAD:+:${LD_PRELOAD}}"
echo "[runtime-check] jemalloc preload=${jemalloc_so}"

expected_npu_count=${EXPECTED_NPU_COUNT:-}
[[ "${expected_npu_count}" =~ ^[0-9]+$ ]] || {
  echo "[runtime-check] EXPECTED_NPU_COUNT must be an integer" >&2
  exit 1
}

python3 -u -X faulthandler - <<'PY'
import ctypes
import importlib.metadata as md
import os

import sglang
import torch
import torch_npu
from mooncake.engine import TransferEngine

if os.environ.get("PD_TRANSFER_BACKEND") == "ascend":
    from memfabric_hybrid import TransferEngine as MemFabricTransferEngine
    from memfabric_hybrid import create_config_store
else:
    MemFabricTransferEngine = None
    create_config_store = None

ctypes.CDLL("libibverbs.so.1")
expected = int(os.environ["EXPECTED_NPU_COUNT"])
actual = torch.npu.device_count()
jemalloc_loaded = any(
    "libjemalloc.so.2" in line
    for line in open("/proc/self/maps", encoding="utf-8")
)

print("sglang:", getattr(sglang, "__version__", "unknown"))
print("torch:", torch.__version__)
print("torch_npu:", torch_npu.__version__)
print("torch.npu.device_count:", actual)
print("mooncake-transfer-engine-npu:", md.version("mooncake-transfer-engine-npu"))
print("libibverbs.so.1 load: OK")
print("libjemalloc.so.2 preloaded:", jemalloc_loaded)
print("Mooncake TransferEngine import: OK", TransferEngine)
if MemFabricTransferEngine is not None:
    print("MemFabric TransferEngine import: OK", MemFabricTransferEngine)
    print("MemFabric create_config_store import: OK", create_config_store)

if not jemalloc_loaded:
    raise RuntimeError("libjemalloc.so.2 was not preloaded before Python startup")
if actual < expected:
    raise RuntimeError(
        f"Expected at least {expected} visible NPUs, but torch_npu found {actual}"
    )
PY

echo "[runtime-check] passed"
