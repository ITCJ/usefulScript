#!/usr/bin/env bash
set -Eeuo pipefail

ROLE=${1:?role is required}
shift

# Start file and Docker logging before any environment/library setup so early
# entrypoint failures are observable. Python is also forced to flush output.
mkdir -p /logs
touch "/logs/${ROLE}.log"
exec > >(tee -a "/logs/${ROLE}.log") 2>&1
export PYTHONUNBUFFERED=1
echo "[$(date '+%F %T')] Entrypoint started: role=${ROLE} pid=$$"

source_optional_env() {
  local env_file=$1 source_rc
  if [[ ! -f "${env_file}" ]]; then
    echo "[$(date '+%F %T')] Optional environment file not found: ${env_file}"
    return 0
  fi

  echo "[$(date '+%F %T')] Loading environment: ${env_file}"
  # Vendor environment scripts commonly expand variables that are optional.
  # Disable nounset/errexit only while sourcing, then restore strict mode.
  set +u
  set +e
  # shellcheck disable=SC1090
  source "${env_file}"
  source_rc=$?
  set -Eeuo pipefail

  if ((source_rc != 0)); then
    echo "[$(date '+%F %T')] WARNING: environment script returned ${source_rc}: ${env_file}"
  else
    echo "[$(date '+%F %T')] Environment loaded: ${env_file}"
  fi
}

source_optional_env /usr/local/Ascend/ascend-toolkit/set_env.sh
source_optional_env /usr/local/Ascend/nnal/atb/set_env.sh

# On aarch64, loading jemalloc after torch_npu/CANN has consumed static TLS can
# fail with "cannot allocate memory in static TLS block". Preload it before the
# SGLang Python process starts.
echo "[$(date '+%F %T')] Resolving libjemalloc.so.2"
# Do not make sed quit early: under pipefail that can SIGPIPE ldconfig and make
# the assignment look like a failure even when the library was found.
JEMALLOC_SO=$(ldconfig -p 2>/dev/null | sed -n "/libjemalloc\\.so\\.2/{s/.*=>[[:space:]]*//;p;}")
JEMALLOC_SO=${JEMALLOC_SO%%$'\n'*}
if [[ -z "${JEMALLOC_SO}" ]]; then
  echo "libjemalloc.so.2 was not found; rebuild the derived image" >&2
  exit 1
fi
export LD_PRELOAD="${JEMALLOC_SO}${LD_PRELOAD:+:${LD_PRELOAD}}"
echo "[$(date '+%F %T')] Using jemalloc preload: ${JEMALLOC_SO}"

export ENABLE_ASCEND_TRANSFER_WITH_MOONCAKE=true
export ASCEND_NPU_PHY_ID=-1
export PYTORCH_NPU_ALLOC_CONF=${PYTORCH_NPU_ALLOC_CONF:-expandable_segments:True}
export SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT=${SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT:-600}
export SGLANG_DISAGGREGATION_WAITING_TIMEOUT=${SGLANG_DISAGGREGATION_WAITING_TIMEOUT:-600}

# Do not pass --disaggregation-ib-device: Ascend Direct installs its own
# transport and does not use the CUDA/RDMA HCA-selection path.
echo "[$(date '+%F %T')] Launching SGLang ${ROLE} server"
exec python3 -u -m sglang.launch_server "$@"
