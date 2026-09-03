#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

bash -n "${SCRIPT_DIR}"/*.sh

grep -Fq 'libibverbs1' "${SCRIPT_DIR}/Dockerfile"
grep -Fq 'libjemalloc2' "${SCRIPT_DIR}/Dockerfile"
grep -Fq 'ibverbs-providers' "${SCRIPT_DIR}/Dockerfile"
grep -Fq 'rdma-core' "${SCRIPT_DIR}/Dockerfile"
grep -Fq 'APT_MIRROR' "${SCRIPT_DIR}/Dockerfile"
grep -Fq 'APT_PORTS_MIRROR' "${SCRIPT_DIR}/Dockerfile"
if grep -Eq ';[[:space:]]*\\?[[:space:]]*&&' "${SCRIPT_DIR}/Dockerfile"; then
  echo "Invalid Dockerfile shell sequence: '; &&'" >&2
  exit 1
fi
grep -Fq 'torch.npu.device_count()' "${SCRIPT_DIR}/preflight.sh"
grep -Fq '/dev/davinci_manager' "${SCRIPT_DIR}/preflight.sh"
grep -Fq '/dev/devmm_svm' "${SCRIPT_DIR}/preflight.sh"
grep -Fq '/dev/hisi_hdc' "${SCRIPT_DIR}/preflight.sh"
grep -Fq 'libibverbs.so.1' "${SCRIPT_DIR}/preflight.sh"
grep -Fq 'libjemalloc.so.2' "${SCRIPT_DIR}/preflight.sh"
grep -Fq 'export LD_PRELOAD=' "${SCRIPT_DIR}/preflight.sh"
grep -Fq 'export LD_PRELOAD=' "${SCRIPT_DIR}/container-entrypoint.sh"
if grep -Fq 'ctypes.CDLL("libjemalloc.so.2")' "${SCRIPT_DIR}/preflight.sh"; then
  echo "Late jemalloc loading is forbidden on aarch64" >&2
  exit 1
fi
if grep -Rq '\$NF' \
  "${SCRIPT_DIR}/preflight.sh" \
  "${SCRIPT_DIR}/container-entrypoint.sh"; then
  echo 'Nested container scripts must not use awk $NF under set -u' >&2
  exit 1
fi
if grep -Fq "sed -n '" "${SCRIPT_DIR}/preflight.sh"; then
  echo "Single-quoted sed expressions break the outer bash -lc payload" >&2
  exit 1
fi
grep -Fq 'NPU_SMI_BIN' "${SCRIPT_DIR}/preflight.sh"
grep -Fq 'USE_DOCKER_INIT' "${SCRIPT_DIR}/lib.sh"
grep -Fq 'USE_DOCKER_INIT=0' "${SCRIPT_DIR}/deploy.env.example"

echo "Static deployment checks passed"
