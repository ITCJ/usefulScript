#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

bash -n "${SCRIPT_DIR}"/*.sh

grep -Fq 'libibverbs1' "${SCRIPT_DIR}/Dockerfile"
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
grep -Fq 'NPU_SMI_BIN' "${SCRIPT_DIR}/preflight.sh"

echo "Static deployment checks passed"
