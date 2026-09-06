#!/usr/bin/env bash
set -Eeuo pipefail

ROLE=${1:-}
[[ "${ROLE}" == "prefill" || "${ROLE}" == "decode" ]] || {
  echo "Usage: $0 prefill|decode" >&2
  exit 2
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env
require_command docker

if [[ "${ROLE}" == "prefill" ]]; then
  HOST_IP=${PREFILL_IP}
  HTTP_PORT=${PREFILL_HTTP_PORT}
  BASE_NPU=$(role_base_npu prefill)
  ASCEND_PORT=${PREFILL_ASCEND_BASE_PORT}
  EXTRA_ARGS=${EXTRA_PREFILL_ARGS:-}
else
  HOST_IP=${DECODE_IP}
  HTTP_PORT=${DECODE_HTTP_PORT}
  BASE_NPU=$(role_base_npu decode)
  ASCEND_PORT=${DECODE_ASCEND_BASE_PORT}
  EXTRA_ARGS=${EXTRA_DECODE_ARGS:-}
fi

mkdir -p "${LOG_DIR}"
docker rm -f "$(role_name "${ROLE}")" >/dev/null 2>&1 || true
build_docker_args "${ROLE}"

SERVER_ARGS=(
  --model-path "${MODEL_CONTAINER_PATH}"
  --device npu
  --attention-backend ascend
  --host "${HOST_IP}"
  --port "${HTTP_PORT}"
  --tp-size "${TP_SIZE}"
  --base-gpu-id "${BASE_NPU}"
  --mem-fraction-static "${MEM_FRACTION_STATIC}"
  --context-length "${CONTEXT_LENGTH}"
  --max-running-requests "${MAX_RUNNING_REQUESTS}"
  --dtype "${DTYPE}"
  --disaggregation-mode "${ROLE}"
  --disaggregation-transfer-backend mooncake
  --disaggregation-bootstrap-port "${PREFILL_BOOTSTRAP_PORT}"
)

if [[ "${ENABLE_MOONCAKE_L3:-0}" == "1" ]]; then
  role_local_ip=${PREFILL_IP}
  if [[ "${ROLE}" == "decode" ]]; then
    role_local_ip=${DECODE_IP}
  fi
  mooncake_store_config=$(printf \
    '{"master_server_address":"%s:%s","local_hostname":"%s","metadata_server":"http://%s:%s/metadata","global_segment_size":0,"protocol":"%s","device_name":"%s"}' \
    "${MOONCAKE_MASTER_IP}" \
    "${MOONCAKE_MASTER_PORT}" \
    "${role_local_ip}" \
    "${MOONCAKE_MASTER_IP}" \
    "${MOONCAKE_METADATA_PORT}" \
    "${MOONCAKE_STORE_PROTOCOL}" \
    "${MOONCAKE_STORE_DEVICE:-}")

  SERVER_ARGS+=(
    --enable-hierarchical-cache
    --hicache-size "${HICACHE_L2_GB_PER_RANK}"
    --hicache-io-backend "${HICACHE_IO_BACKEND}"
    --hicache-mem-layout "${HICACHE_MEM_LAYOUT}"
    --hicache-write-policy "${HICACHE_WRITE_POLICY}"
    --hicache-storage-backend mooncake
    --hicache-storage-prefetch-policy "${HICACHE_PREFETCH_POLICY}"
    --hicache-storage-backend-extra-config "${mooncake_store_config}"
  )

  if [[ "${ROLE}" == "decode" && "${ENABLE_DECODE_HICACHE:-1}" == "1" ]]; then
    SERVER_ARGS+=(--disaggregation-decode-enable-radix-cache)
  fi
  if [[ "${ROLE}" == "decode" && "${ENABLE_DECODE_KV_OFFLOAD:-1}" == "1" ]]; then
    SERVER_ARGS+=(--disaggregation-decode-enable-offload-kvcache)
  fi
fi

if [[ "${ROLE}" == "prefill" ]]; then
  SERVER_ARGS+=(--chunked-prefill-size "${CHUNKED_PREFILL_SIZE}")
fi
if [[ "${TRUST_REMOTE_CODE}" == "1" ]]; then
  SERVER_ARGS+=(--trust-remote-code)
fi
if [[ -n "${TOKENIZER_HOST_PATH:-}" ]]; then
  SERVER_ARGS+=(--tokenizer-path "${TOKENIZER_CONTAINER_PATH}")
fi

# EXTRA_*_ARGS is intentionally word-split to support a list of CLI flags.
# Do not place secrets in it.
if [[ -n "${EXTRA_ARGS}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_ARRAY=(${EXTRA_ARGS})
  SERVER_ARGS+=("${EXTRA_ARRAY[@]}")
fi

DOCKER_ARGS+=(
  --env "SGLANG_HOST_IP=${HOST_IP}"
  --env "ASCEND_BASE_PORT=${ASCEND_PORT}"
  --env "ASCEND_AUTO_CONNECT=${ASCEND_AUTO_CONNECT:-1}"
  --env "SGLANG_LOG_LEVEL=${SGLANG_LOG_LEVEL}"
  --env "SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT=${SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT}"
  --env "SGLANG_DISAGGREGATION_WAITING_TIMEOUT=${SGLANG_DISAGGREGATION_WAITING_TIMEOUT}"
)
[[ -n "${HCCL_SOCKET_IFNAME:-}" ]] && DOCKER_ARGS+=(--env "HCCL_SOCKET_IFNAME=${HCCL_SOCKET_IFNAME}")
[[ -n "${GLOO_SOCKET_IFNAME:-}" ]] && DOCKER_ARGS+=(--env "GLOO_SOCKET_IFNAME=${GLOO_SOCKET_IFNAME}")
for network_env_name in \
  HCCL_INTRA_ROCE_ENABLE \
  ASCEND_RDMA_TC \
  ASCEND_RDMA_SL \
  HCCL_RDMA_TIMEOUT \
  HCCL_RDMA_RETRY_CNT \
  ASCEND_CONNECT_TIMEOUT \
  ASCEND_TRANSFER_TIMEOUT; do
  network_env_value=$(printenv "${network_env_name}" 2>/dev/null || true)
  if [[ -n "${network_env_value}" ]]; then
    DOCKER_ARGS+=(--env "${network_env_name}=${network_env_value}")
  fi
done

container_name=$(role_name "${ROLE}")
if [[ "${ENABLE_MOONCAKE_L3:-0}" == "1" ]]; then
  wait_tcp_endpoint "${MOONCAKE_MASTER_IP}" "${MOONCAKE_MASTER_PORT}" 5 || \
    die "Mooncake Master is unavailable at ${MOONCAKE_MASTER_IP}:${MOONCAKE_MASTER_PORT}"
  wait_tcp_endpoint "${MOONCAKE_MASTER_IP}" "${MOONCAKE_METADATA_PORT}" 5 || \
    die "Mooncake metadata service is unavailable at ${MOONCAKE_MASTER_IP}:${MOONCAKE_METADATA_PORT}"
  wait_tcp_endpoint "${role_local_ip}" "${MOONCAKE_STORE_PORT}" 5 || \
    die "Local Mooncake Store is unavailable at ${role_local_ip}:${MOONCAKE_STORE_PORT}"
fi
log "Starting ${ROLE}: NPU base=${BASE_NPU}, TP=${TP_SIZE}, endpoint=${HOST_IP}:${HTTP_PORT}"
docker run "${DOCKER_ARGS[@]}" \
  "${RUNTIME_IMAGE}" \
  bash /opt/sglang-mooncake-deploy/container-entrypoint.sh \
  "${ROLE}" "${SERVER_ARGS[@]}"

for _ in 1 2 3; do
  sleep 1
  container_state=$(docker inspect --format '{{.State.Status}}' "${container_name}")
  [[ "${container_state}" == "running" ]] || break
done

container_state=$(docker inspect --format '{{.State.Status}}' "${container_name}")
container_exit_code=$(docker inspect --format '{{.State.ExitCode}}' "${container_name}")
container_error=$(docker inspect --format '{{.State.Error}}' "${container_name}")
container_path=$(docker inspect --format '{{.Path}}' "${container_name}")
container_args=$(docker inspect --format '{{json .Args}}' "${container_name}")
container_log_driver=$(docker inspect --format '{{.HostConfig.LogConfig.Type}}' "${container_name}")

log "Container state=${container_state} exit_code=${container_exit_code} log_driver=${container_log_driver}"
log "Container command: ${container_path} ${container_args}"

if [[ "${container_state}" != "running" ]]; then
  [[ -n "${container_error}" ]] && log "Docker state error: ${container_error}"
  echo "----- docker logs: ${container_name} -----" >&2
  docker logs --tail 200 "${container_name}" >&2 || true
  echo "----- host log: ${LOG_DIR}/${ROLE}.log -----" >&2
  if [[ -f "${LOG_DIR}/${ROLE}.log" ]]; then
    tail -n 200 "${LOG_DIR}/${ROLE}.log" >&2 || true
  else
    echo "Host log file was not created" >&2
  fi
  die "Container ${container_name} exited during startup"
fi

if [[ -s "${LOG_DIR}/${ROLE}.log" ]]; then
  log "Initial host log:"
  tail -n 20 "${LOG_DIR}/${ROLE}.log" || true
else
  log "WARNING: ${LOG_DIR}/${ROLE}.log is still empty; inspect the container command above"
fi

log "Container started and remains running: ${container_name}"
log "Follow logs: docker logs -f ${container_name}"
