#!/usr/bin/env bash
set -Eeuo pipefail

# Sweep GSM8K accuracy across server runtime configs:
#   CUDA graph on/off x max-running-requests BS 1/2, repeated NUM_ITERS times.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

LOG_DIR="${LOG_DIR:-/home/tcj/sglang-ascend/gsm8k_eval_config_sweep_logs}"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
NUM_ITERS="${NUM_ITERS:-3}"
RESUME="${RESUME:-1}"
SWEEP_LABEL="${SWEEP_LABEL:-}"
EVAL_SCRIPT="${EVAL_SCRIPT:-${SCRIPT_DIR}/run_gsm8k_eval_with_server_restart.sh}"

mkdir -p "${LOG_DIR}"

if [[ -n "${SWEEP_LABEL}" ]]; then
  if [[ ! "${SWEEP_LABEL}" =~ ^[[:alnum:]_.-]+$ ]]; then
    echo "Invalid SWEEP_LABEL=${SWEEP_LABEL}; use only letters, digits, '.', '_' or '-'." >&2
    exit 2
  fi
  SWEEP_PREFIX="sweep_${SWEEP_LABEL}"
else
  SWEEP_PREFIX="sweep"
fi

if [[ -z "${SWEEP_DIR:-}" && "${RESUME}" == "1" ]]; then
  latest_sweep_dir="$(find "${LOG_DIR}" -maxdepth 1 -type d -name "${SWEEP_PREFIX}_*" 2>/dev/null | sort | tail -n 1)"
  SWEEP_DIR="${latest_sweep_dir:-${LOG_DIR}/${SWEEP_PREFIX}_${RUN_TS}}"
else
  SWEEP_DIR="${SWEEP_DIR:-${LOG_DIR}/${SWEEP_PREFIX}_${RUN_TS}}"
fi

mkdir -p "${SWEEP_DIR}"
SWEEP_LOG="${SWEEP_DIR}/sweep.log"
STATUS_FILE="${SWEEP_DIR}/status.tsv"

log_msg() {
  echo "$*" | tee -a "${SWEEP_LOG}"
}

is_case_complete() {
  local run_dir="$1"

  [[ "${RESUME}" == "1" ]] || return 1

  if [[ -f "${run_dir}/.complete" ]]; then
    return 0
  fi

  if [[ -f "${run_dir}/exit_status" ]] && [[ "$(cat "${run_dir}/exit_status")" == "0" ]]; then
    return 0
  fi

  if [[ -f "${run_dir}/eval.log" ]] && grep -q "GSM8K eval exit_status=0" "${run_dir}/eval.log"; then
    return 0
  fi

  return 1
}

run_one_config() {
  local cuda_graph_mode="$1"
  local bs="$2"
  local iter="$3"
  local config_name
  local run_dir
  local status
  shift 3

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

  if is_case_complete "${run_dir}"; then
    log_msg "[$(date '+%F %T')] skip completed config=${config_name} iter=${iter}"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$(date '+%F %T')" "${config_name}" "${iter}" "SKIPPED" "${run_dir}" >> "${STATUS_FILE}"
    return 0
  fi

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
  echo "${status}" > "${run_dir}/exit_status"
  if [[ "${status}" -eq 0 ]]; then
    touch "${run_dir}/.complete"
  else
    rm -f "${run_dir}/.complete"
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%F %T')" "${config_name}" "${iter}" "${status}" "${run_dir}" >> "${STATUS_FILE}"

}

init_case_dirs() {
  local bs
  local cuda_graph_mode
  local iter
  local config_name
  local run_dir

  if [[ ! -f "${STATUS_FILE}" ]]; then
    printf 'time\tconfig\titer\texit_status\trun_dir\n' > "${STATUS_FILE}"
  fi

  for bs in 1 2; do
    for cuda_graph_mode in graph eager; do
      if [[ "${cuda_graph_mode}" == "graph" ]]; then
        config_name="cuda_graph_bs${bs}"
      else
        config_name="eager_bs${bs}"
      fi

      for iter in $(seq 1 "${NUM_ITERS}"); do
        run_dir="${SWEEP_DIR}/${config_name}/iter_${iter}"
        mkdir -p "${run_dir}"
        {
          echo "SERVER_CONFIG_NAME=${config_name}"
          echo "CUDA_GRAPH_MODE=${cuda_graph_mode}"
          echo "CUDA_GRAPH_BS=${bs}"
          echo "MAX_RUNNING_REQUESTS=${bs}"
          echo "ITERATION=${iter}"
        } > "${run_dir}/config.env"
      done
    done
  done
}

init_case_dirs

log_msg "[$(date '+%F %T')] GSM8K config sweep started"
log_msg "sweep_dir=${SWEEP_DIR}"
log_msg "sweep_label=${SWEEP_LABEL}"
log_msg "num_iters=${NUM_ITERS}"
log_msg "resume=${RESUME}"
log_msg "eval_script=${EVAL_SCRIPT}"
log_msg "configs=(cuda_graph,eager) x bs=(1,2)"

for config in "graph:1" "eager:1" "graph:2" "eager:2"; do
  cuda_graph_mode="${config%%:*}"
  bs="${config##*:}"
  for iter in $(seq 1 "${NUM_ITERS}"); do
    run_one_config "${cuda_graph_mode}" "${bs}" "${iter}" "$@"
  done
done

log_msg ""
log_msg "[$(date '+%F %T')] GSM8K config sweep finished"
log_msg "sweep_dir=${SWEEP_DIR}"
