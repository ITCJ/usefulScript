#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

bash -n "${SCRIPT_DIR}"/*.sh

grep -Fq 'libibverbs1' "${SCRIPT_DIR}/Dockerfile"
grep -Fq 'ibverbs-providers' "${SCRIPT_DIR}/Dockerfile"
grep -Fq 'rdma-core' "${SCRIPT_DIR}/Dockerfile"
grep -Fq 'torch.npu.device_count()' "${SCRIPT_DIR}/preflight.sh"
grep -Fq '/dev/davinci_manager' "${SCRIPT_DIR}/preflight.sh"
grep -Fq '/dev/devmm_svm' "${SCRIPT_DIR}/preflight.sh"
grep -Fq '/dev/hisi_hdc' "${SCRIPT_DIR}/preflight.sh"
grep -Fq 'libibverbs.so.1' "${SCRIPT_DIR}/preflight.sh"
grep -Fq 'NPU_SMI_BIN' "${SCRIPT_DIR}/preflight.sh"

echo "Static deployment checks passed"
