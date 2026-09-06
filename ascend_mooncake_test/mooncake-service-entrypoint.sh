#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE=${1:?service is required: master or store}
ROLE=${2:-}

case "${SERVICE}" in
  master) log_name=mooncake-master ;;
  store)
    [[ "${ROLE}" == "prefill" || "${ROLE}" == "decode" ]] || {
      echo "store role must be prefill or decode" >&2
      exit 2
    }
    log_name="mooncake-store-${ROLE}"
    ;;
  *)
    echo "Unknown Mooncake service: ${SERVICE}" >&2
    exit 2
    ;;
esac

mkdir -p /logs
touch "/logs/${log_name}.log"
exec > >(tee -a "/logs/${log_name}.log") 2>&1
export PYTHONUNBUFFERED=1
echo "[$(date '+%F %T')] Mooncake ${SERVICE} entrypoint started: role=${ROLE:-none} pid=$$"

source_optional_env() {
  local env_file=$1 env_snapshot source_rc
  [[ -f "${env_file}" ]] || return 0
  echo "[$(date '+%F %T')] Loading environment: ${env_file}"
  env_snapshot=$(mktemp /tmp/mooncake-vendor-env.XXXXXX)
  set +e
  bash --noprofile --norc -c '
set +u
set +e
source "$1" >/dev/null
source_rc=$?
if ((source_rc == 0)); then
  export -p
fi
exit "${source_rc}"
' _ "${env_file}" >"${env_snapshot}"
  source_rc=$?
  set -e
  if ((source_rc != 0)); then
    echo "[$(date '+%F %T')] WARNING: environment script returned ${source_rc}: ${env_file}"
  elif [[ -s "${env_snapshot}" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "${env_snapshot}"
    set -u
    echo "[$(date '+%F %T')] Environment loaded: ${env_file}"
  else
    echo "[$(date '+%F %T')] WARNING: environment script produced no exported environment: ${env_file}"
  fi
  rm -f -- "${env_snapshot}"
  set -Eeuo pipefail
}

source_optional_env /usr/local/Ascend/ascend-toolkit/set_env.sh

JEMALLOC_SO=$(ldconfig -p 2>/dev/null | sed -n "/libjemalloc\\.so\\.2/{s/.*=>[[:space:]]*//;p;}")
JEMALLOC_SO=${JEMALLOC_SO%%$'\n'*}
[[ -n "${JEMALLOC_SO}" ]] || {
  echo "libjemalloc.so.2 was not found; rebuild the derived image" >&2
  exit 1
}
export LD_PRELOAD="${JEMALLOC_SO}${LD_PRELOAD:+:${LD_PRELOAD}}"
echo "[$(date '+%F %T')] Using jemalloc preload: ${JEMALLOC_SO}"

if [[ "${SERVICE}" == "master" ]]; then
  : "${MOONCAKE_METADATA_PORT:?MOONCAKE_METADATA_PORT is required}"
  : "${MOONCAKE_EVICTION_HIGH_WATERMARK:?MOONCAKE_EVICTION_HIGH_WATERMARK is required}"
  echo "[$(date '+%F %T')] Launching Mooncake Master on port 50051 with metadata port ${MOONCAKE_METADATA_PORT}"
  MOONCAKE_MASTER_BIN=$(python3 -c 'import mooncake, os; print(os.path.join(os.path.dirname(mooncake.__file__), "mooncake_master"))')
  [[ -x "${MOONCAKE_MASTER_BIN}" ]] || {
    echo "Mooncake Master binary is missing: ${MOONCAKE_MASTER_BIN}" >&2
    exit 1
  }
  exec "${MOONCAKE_MASTER_BIN}" \
    --enable_http_metadata_server=true \
    --http_metadata_server_port="${MOONCAKE_METADATA_PORT}" \
    --eviction_high_watermark_ratio="${MOONCAKE_EVICTION_HIGH_WATERMARK}"
fi

: "${MOONCAKE_LOCAL_HOSTNAME:?MOONCAKE_LOCAL_HOSTNAME is required}"
: "${MOONCAKE_MASTER:?MOONCAKE_MASTER is required}"
: "${MOONCAKE_TE_META_DATA_SERVER:?MOONCAKE_TE_META_DATA_SERVER is required}"
: "${MOONCAKE_GLOBAL_SEGMENT_SIZE:?MOONCAKE_GLOBAL_SEGMENT_SIZE is required}"
: "${MOONCAKE_STORE_PORT:?MOONCAKE_STORE_PORT is required}"

echo "[$(date '+%F %T')] Launching Mooncake Store role=${ROLE} host=${MOONCAKE_LOCAL_HOSTNAME} segment=${MOONCAKE_GLOBAL_SEGMENT_SIZE} protocol=${MOONCAKE_PROTOCOL:-tcp}"
exec python3 -u -m mooncake.mooncake_store_service \
  --port="${MOONCAKE_STORE_PORT}"
