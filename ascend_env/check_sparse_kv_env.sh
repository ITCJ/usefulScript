#!/usr/bin/env bash
set -euo pipefail

# Check the runtime prerequisites for sparse KV cache integration on Ascend.
#
# Expected usage inside the Ascend container:
#   ASCEND_SHM_DIR=/home/tcj/ascendshm \
#   SGL_KERNEL_NPU_DIR=/home/tcj/sgl-kernel-npu \
#   SGLANG_ASCEND_DIR=/home/tcj/sglang-ascend \
#   ./check_sparse_kv_env.sh

PYTHON_BIN="${PYTHON_BIN:-python}"
ASCEND_SHM_DIR="${ASCEND_SHM_DIR:-/home/tcj/ascendshm}"
ASCEND_SHM_BUILD_DIR="${ASCEND_SHM_BUILD_DIR:-${ASCEND_SHM_DIR}/build}"
SGL_KERNEL_NPU_DIR="${SGL_KERNEL_NPU_DIR:-/home/tcj/sgl-kernel-npu}"
SGLANG_ASCEND_DIR="${SGLANG_ASCEND_DIR:-/home/tcj/sglang-ascend}"
RUN_KERNEL_TESTS="${RUN_KERNEL_TESTS:-0}"

section() {
  echo
  echo "==== $* ===="
}

require_file_glob() {
  local pattern="$1"
  local description="$2"

  compgen -G "${pattern}" >/dev/null || {
    echo "ERROR: ${description} not found: ${pattern}" >&2
    return 1
  }
}

section "Python executable"
"${PYTHON_BIN}" - <<'PY'
import sys

print(sys.executable)
print(sys.version)
PY

section "Python package versions"
"${PYTHON_BIN}" -m pip show torch torch_npu triton triton-ascend sgl-kernel-npu || true

section "Triton Ascend CANN extension"
"${PYTHON_BIN}" - <<'PY'
import importlib.util
import sys

import triton

print("python:", sys.executable)
print("triton file:", triton.__file__)
print("triton version:", getattr(triton, "__version__", None))

for name in (
    "triton.language.extra",
    "triton.language.extra.cann",
    "triton.language.extra.cann.extension",
):
    spec = importlib.util.find_spec(name)
    print(f"{name}: {spec}")
    if spec is None:
        raise SystemExit(f"missing required module: {name}")

import triton.language.extra.cann.extension as al  # noqa: F401

print("triton-ascend cann extension import ok")
PY

section "AscendSHM build artifacts"
echo "ASCEND_SHM_BUILD_DIR=${ASCEND_SHM_BUILD_DIR}"
require_file_glob "${ASCEND_SHM_BUILD_DIR}/pyascend_shm*.so" "pyascend_shm extension"
require_file_glob "${ASCEND_SHM_BUILD_DIR}/libascend_shm.so" "libascend_shm"
ls -lh "${ASCEND_SHM_BUILD_DIR}"/pyascend_shm*.so "${ASCEND_SHM_BUILD_DIR}/libascend_shm.so"

section "AscendSHM shared library dependencies"
if command -v ldd >/dev/null 2>&1; then
  ldd "${ASCEND_SHM_BUILD_DIR}"/pyascend_shm*.so
  ldd "${ASCEND_SHM_BUILD_DIR}/libascend_shm.so"
else
  echo "WARN: ldd is not available; skip shared library dependency check"
fi

section "Import pyascend_shm"
export LD_LIBRARY_PATH="${ASCEND_SHM_BUILD_DIR}:${LD_LIBRARY_PATH:-}"
"${PYTHON_BIN}" - <<PY
import sys

sys.path.insert(0, "${ASCEND_SHM_BUILD_DIR}")
import pyascend_shm  # noqa: F401

print("pyascend_shm import ok")
PY

section "Import sparse KV operators"
"${PYTHON_BIN}" - <<'PY'
from sgl_kernel_npu.mem_cache import slot_map_lookup, unidex_copy_inplace

print("slot_map_lookup:", slot_map_lookup)
print("unidex_copy_inplace:", unidex_copy_inplace)
print("sgl_kernel_npu sparse KV operator imports ok")
PY

section "Import Triton-dependent NPU kernels"
"${PYTHON_BIN}" - <<'PY'
import sgl_kernel_npu.norm.add_rmsnorm_bias as add_rmsnorm_bias  # noqa: F401

print("add_rmsnorm_bias import ok")
PY

section "Import sglang sparse_kv_manager"
if [[ -d "${SGLANG_ASCEND_DIR}/python" ]]; then
  PYTHONPATH="${SGLANG_ASCEND_DIR}/python:${PYTHONPATH:-}" "${PYTHON_BIN}" - <<'PY'
import sglang.srt.mem_cache.sparse_kv_manager as sparse_kv_manager  # noqa: F401

print("sglang sparse_kv_manager import ok")
PY
else
  echo "WARN: SGLANG_ASCEND_DIR not found, skip: ${SGLANG_ASCEND_DIR}"
fi

if [[ "${RUN_KERNEL_TESTS}" == "1" ]]; then
  section "Run sparse KV kernel tests"
  if [[ ! -d "${SGL_KERNEL_NPU_DIR}" ]]; then
    echo "ERROR: SGL_KERNEL_NPU_DIR not found: ${SGL_KERNEL_NPU_DIR}" >&2
    exit 1
  fi

  cd "${SGL_KERNEL_NPU_DIR}"
  "${PYTHON_BIN}" tests/python/sgl_kernel_npu/test_slot_map_lookup.py
  "${PYTHON_BIN}" tests/python/sgl_kernel_npu/test_unidex_copy.py
else
  section "Kernel tests skipped"
  echo "Set RUN_KERNEL_TESTS=1 to run:"
  echo "  ${SGL_KERNEL_NPU_DIR}/tests/python/sgl_kernel_npu/test_slot_map_lookup.py"
  echo "  ${SGL_KERNEL_NPU_DIR}/tests/python/sgl_kernel_npu/test_unidex_copy.py"
fi

section "All checks passed"
