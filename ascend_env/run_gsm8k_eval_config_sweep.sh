#!/usr/bin/env bash
set -Eeuo pipefail

# Sweep GSM8K accuracy across server runtime configs:
#   CUDA graph on/off x max-running-requests BS 1/2, repeated NUM_ITERS times.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

LOG_DIR="${LOG_DIR:-/home/tcj/sglang-ascend/gsm8k_eval_config_sweep_logs}"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
SWEEP_DIR="${SWEEP_DIR:-${LOG_DIR}/sweep_${RUN_TS}}"
NUM_ITERS="${NUM_ITERS:-3}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-0}"
EVAL_SCRIPT="${EVAL_SCRIPT:-${SCRIPT_DIR}/run_gsm8k_eval_with_server_restart.sh}"

mkdir -p "${SWEEP_DIR}"
SWEEP_LOG="${SWEEP_DIR}/sweep.log"

log_msg() {
  echo "$*" | tee -a "${SWEEP_LOG}"
}

run_one_config() {
  local cuda_graph_mode="$1"
  local bs="$2"
  local iter="$3"
  local config_name
  local run_dir
  local status

  if [[ "${cuda_graph_mode}" == "graph" ]]; then
    config_name="cuda_graph_bs${bs}"
  else
    config_name="eager_bs${bs}"
  fi

  run_dir="${SWEEP_DIR}/${config_name}/iter_${iter}"
  mkdir -p "${run_dir}"

  {
    echo "SERVER_CONFIG_NAME=${config_name}"
    echo "CUDA_GRAPH_MODE=${cuda_graph_mode}"
    echo "CUDA_GRAPH_BS=${bs}"
    echo "MAX_RUNNING_REQUESTS=${bs}"
    echo "ITERATION=${iter}"
  } > "${run_dir}/config.env"

  log_msg ""
  log_msg "===== GSM8K_CONFIG_SWEEP $(date '+%F %T') config=${config_name} iter=${iter}/${NUM_ITERS} ====="
  log_msg "run_dir=${run_dir}"

  set +e
  SERVER_CONFIG_NAME="${config_name}" \
    CUDA_GRAPH_MODE="${cuda_graph_mode}" \
    CUDA_GRAPH_BS="${bs}" \
    MAX_RUNNING_REQUESTS="${bs}" \
    ITERATION="${iter}" \
    RESTART_SERVER=1 \
    RUN_DIR="${run_dir}" \
    "${EVAL_SCRIPT}" "$@"
  status=$?
  set -e

  log_msg "[$(date '+%F %T')] config=${config_name} iter=${iter} exit_status=${status}"

  if [[ "${status}" -ne 0 && "${CONTINUE_ON_ERROR}" != "1" ]]; then
    log_msg "Stop on failure. Set CONTINUE_ON_ERROR=1 to keep sweeping after failures."
    exit "${status}"
  fi
}

log_msg "[$(date '+%F %T')] GSM8K config sweep started"
log_msg "sweep_dir=${SWEEP_DIR}"
log_msg "num_iters=${NUM_ITERS}"
log_msg "eval_script=${EVAL_SCRIPT}"
log_msg "configs=(cuda_graph,eager) x bs=(1,2)"

for bs in 1 2; do
  for cuda_graph_mode in graph eager; do
    for iter in $(seq 1 "${NUM_ITERS}"); do
      run_one_config "${cuda_graph_mode}" "${bs}" "${iter}" "$@"
    done
  done
done

log_msg ""
log_msg "[$(date '+%F %T')] GSM8K config sweep finished"
log_msg "sweep_dir=${SWEEP_DIR}"
