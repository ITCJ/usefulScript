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
grep -Fq 'expected_device_count=' "${SCRIPT_DIR}/preflight.sh"
grep -Fq 'continuing with device-node and torch_npu validation' "${SCRIPT_DIR}/preflight.sh"
grep -Fq 'continuing with torch_npu device-count validation' "${SCRIPT_DIR}/preflight.sh"
if grep -Fq 'for ((' "${SCRIPT_DIR}/preflight.sh"; then
  echo 'C-style arithmetic loops are forbidden in preflight.sh; use seq' >&2
  exit 1
fi
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
if grep -Eq 'libjemalloc.*p;q;' \
  "${SCRIPT_DIR}/preflight.sh" \
  "${SCRIPT_DIR}/container-entrypoint.sh"; then
  echo "Early sed quit can trigger SIGPIPE under pipefail" >&2
  exit 1
fi
grep -Fq 'NPU_SMI_BIN' "${SCRIPT_DIR}/preflight.sh"
grep -Fq 'USE_DOCKER_INIT' "${SCRIPT_DIR}/lib.sh"
grep -Fq 'USE_DOCKER_INIT=0' "${SCRIPT_DIR}/deploy.env.example"
grep -Fq 'Entrypoint started:' "${SCRIPT_DIR}/container-entrypoint.sh"
grep -Fq 'Loading environment:' "${SCRIPT_DIR}/container-entrypoint.sh"
grep -Fq 'Resolving libjemalloc.so.2' "${SCRIPT_DIR}/container-entrypoint.sh"
grep -Fq 'bash --noprofile --norc' "${SCRIPT_DIR}/container-entrypoint.sh"
grep -Fq 'bash --noprofile --norc' "${SCRIPT_DIR}/mooncake-service-entrypoint.sh"
grep -Fq 'Container state=' "${SCRIPT_DIR}/start-role.sh"
grep -Fq 'DOCKER_LOG_DRIVER=json-file' "${SCRIPT_DIR}/deploy.env.example"
grep -Fq 'Diagnostic archive created:' "${SCRIPT_DIR}/collect-diagnostics.sh"
grep -Fq 'ENABLE_MOONCAKE_L3=1' "${SCRIPT_DIR}/deploy.env.example"
grep -Fq 'disaggregation-decode-enable-radix-cache' "${SCRIPT_DIR}/start-role.sh"
grep -Fq 'disaggregation-decode-enable-offload-kvcache' "${SCRIPT_DIR}/start-role.sh"
grep -Fq 'Mooncake Master is ready' "${SCRIPT_DIR}/start-mooncake-master.sh"
grep -Fq 'Mooncake Store is ready' "${SCRIPT_DIR}/start-mooncake-store.sh"
grep -Fq 'Mooncake L3 preflight passed' "${SCRIPT_DIR}/preflight-mooncake-l3.sh"
grep -Fq '[component-check] passed' "${SCRIPT_DIR}/check-mooncake-l3-components.sh"
grep -Fq 'L3 check phase 1/3' "${SCRIPT_DIR}/preflight-mooncake-l3.sh"
grep -Fq 'must be a non-negative integer' "${SCRIPT_DIR}/preflight-mooncake-l3.sh"
if grep -Fq 'source /usr/local/Ascend/ascend-toolkit/set_env.sh' \
  "${SCRIPT_DIR}/preflight.sh" \
  "${SCRIPT_DIR}/preflight-mooncake-l3.sh"; then
  echo 'Preflight scripts must not directly source vendor set_env.sh' >&2
  exit 1
fi
if grep -Rq '\${!' "${SCRIPT_DIR}" --include='*.sh' --exclude='static-check.sh'; then
  echo 'Bash indirect variable expansion is forbidden; use printenv instead' >&2
  exit 1
fi
grep -Fq 'store-prefill' "${SCRIPT_DIR}/collect-diagnostics.sh"
grep -Fq 'start-l3-node.sh prefill' "${SCRIPT_DIR}/QUICKSTART_L3.md"
grep -Fq 'start-l3-node.sh decode' "${SCRIPT_DIR}/QUICKSTART_L3.md"

echo "Static deployment checks passed"
