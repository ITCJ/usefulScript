#!/usr/bin/env bash
set -Eeuo pipefail

# Unified accuracy-eval lifecycle. The GSM8K and AIME26 entrypoints share
# server restart, sweep, branch comparison, logging, and tensor-dump handling.
#
#   ./run_gsm8k_eval.sh single   # evaluate an already running server
#   ./run_gsm8k_eval.sh sweep    # restart server for each mode/BS/iteration
#   ./run_gsm8k_eval.sh compare  # switch branches and sweep each branch
#
# Configure through environment variables. Remaining arguments are forwarded
# to the selected evaluator.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

case "${1:-}" in
  single|sweep|compare)
    RUN_MODE="$1"
    shift
    ;;
  -h|--help)
    RUN_MODE="help"
    shift
    ;;
  *)
    RUN_MODE="${RUN_MODE:-single}"
    ;;
esac
EXTRA_EVAL_ARG_COUNT=$#
EXTRA_EVAL_ARGS=("$@")

EVAL_NAME="${EVAL_NAME:-gsm8k}"
BENCHMARK_LABEL="${BENCHMARK_LABEL:-GSM8K}"
ENTRYPOINT_NAME="${ENTRYPOINT_NAME:-run_gsm8k_eval.sh}"
REPO_DIR="${REPO_DIR:-/home/tcj/sglang-ascend}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-6699}"
BASE_URL="${BASE_URL:-}"
MODEL_PATH="${MODEL_PATH:-}"
API="${API:-chat}"
THINKING_MODE="${THINKING_MODE:-}"
export CONTEXT_LENGTH="${CONTEXT_LENGTH:-40000}"
GSM8K_DATA_PATH="${GSM8K_DATA_PATH:-${SCRIPT_DIR}/gsm8k_test.jsonl}"
AIME26_DATA_PATH="${AIME26_DATA_PATH:-${SCRIPT_DIR}/aime26}"

case "${EVAL_NAME}" in
  gsm8k)
    NUM_EXAMPLES="${NUM_EXAMPLES:-200}"
    NUM_SHOTS="${NUM_SHOTS:-5}"
    MAX_TOKENS="${MAX_TOKENS:-2048}"
    TEMPERATURE="${TEMPERATURE:-0.0}"
    TOP_P="${TOP_P:-1.0}"
    RUN_PREFIX="${RUN_PREFIX:-gsm8k}"
    ;;
  aime26)
    NUM_EXAMPLES="${NUM_EXAMPLES:-30}"
    NUM_SHOTS=0
    MAX_TOKENS="${MAX_TOKENS:-32768}"
    TEMPERATURE="${TEMPERATURE:-1.0}"
    TOP_P="${TOP_P:-1.0}"
    RUN_PREFIX="${RUN_PREFIX:-aime26}"
    EVALSCOPE_BIN="${EVALSCOPE_BIN:-${REPO_DIR}/test_env_evalscope/bin/evalscope}"
    AIME26_DATASET_ARGS="${AIME26_DATASET_ARGS:-{\"aime26\":{\"dataset_id\":\"${AIME26_DATA_PATH}\"}}}"
    AIME26_GENERATION_CONFIG="${AIME26_GENERATION_CONFIG:-{\"max_tokens\":${MAX_TOKENS},\"temperature\":${TEMPERATURE},\"top_p\":${TOP_P}}}"
    ;;
  *)
    echo "Unsupported EVAL_NAME='${EVAL_NAME}'." >&2
    exit 2
    ;;
esac

# Keep logs, reports, and tensor dumps outside the git worktree by default.
LOG_DIR="${LOG_DIR:-/home/tcj/${EVAL_NAME}_eval_logs}"
RUN_TS="${RUN_TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"

SERVER_START_SCRIPT="${SERVER_START_SCRIPT:-${SCRIPT_DIR}/start.sh}"
SERVER_STOP_TIMEOUT_SEC="${SERVER_STOP_TIMEOUT_SEC:-120}"
READY_CHECK_TIMEOUT_SEC="${READY_CHECK_TIMEOUT_SEC:-6000}"
SERVER_READY_PATH="${SERVER_READY_PATH:-/v1/models}"

TENSOR_DUMP="${TENSOR_DUMP:-0}"
TENSOR_DUMP_LAYERS="${TENSOR_DUMP_LAYERS:-all}"
TENSOR_DUMP_LEVEL="${TENSOR_DUMP_LEVEL:-minimal}"
TENSOR_DUMP_START_CALL="${TENSOR_DUMP_START_CALL:-0}"
TENSOR_DUMP_MAX_CALLS="${TENSOR_DUMP_MAX_CALLS:-0}"

NUM_ITERS="${NUM_ITERS:-3}"
RESUME="${RESUME:-1}"
SWEEP_LABEL="${SWEEP_LABEL:-}"
SWEEP_CONFIGS="${SWEEP_CONFIGS:-eager:1}"

BASE_BRANCH="${BASE_BRANCH:-pr/ascend-sparse-kv-clean-v2-base}"
OUR_BRANCH="${OUR_BRANCH:-tcj-debug/print_our_tensor}"
BRANCH_REMOTE="${BRANCH_REMOTE:-origin}"
UPDATE_FROM_REMOTE="${UPDATE_FROM_REMOTE:-1}"
COMPARE_VARIANTS="${COMPARE_VARIANTS:-base ours}"
COMPARE_LABEL="${COMPARE_LABEL:-${SWEEP_LABEL:-branch_compare}}"

CURRENT_LOG=""
ORIGINAL_BRANCH=""
ORIGINAL_HEAD=""
RESTORE_CHECKOUT=0

usage() {
  cat <<EOF
Usage:
  ${ENTRYPOINT_NAME} single [evaluator arguments...]
  ${ENTRYPOINT_NAME} sweep [evaluator arguments...]
  ${ENTRYPOINT_NAME} compare [evaluator arguments...]

Modes:
  single   Evaluate an existing server; set RESTART_SERVER=1 to restart it.
  sweep    Restart and test SWEEP_CONFIGS (default: eager:1) NUM_ITERS times.
  compare  Switch BASE_BRANCH/OUR_BRANCH and run the same sweep on each.

Examples:
  NUM_EXAMPLES=2 ./${ENTRYPOINT_NAME} single
  NUM_ITERS=3 SWEEP_CONFIGS='eager:1 graph:1' ./${ENTRYPOINT_NAME} sweep
  COMPARE_VARIANTS='base ours' NUM_ITERS=1 ./${ENTRYPOINT_NAME} compare
EOF
}

log_msg() {
  if [[ -n "${CURRENT_LOG}" ]]; then
    echo "$*" | tee -a "${CURRENT_LOG}"
  else
    echo "$*"
  fi
}

validate_common_options() {
  local resolved_evalscope_bin

  case "${TENSOR_DUMP}" in
    0|1) ;;
    *)
      echo "TENSOR_DUMP must be 0 or 1, got '${TENSOR_DUMP}'." >&2
      return 2
      ;;
  esac
  if [[ "${TENSOR_DUMP_LEVEL}" != "minimal" && "${TENSOR_DUMP_LEVEL}" != "full" ]]; then
    echo "TENSOR_DUMP_LEVEL must be minimal or full." >&2
    return 2
  fi
  if [[ ! "${TENSOR_DUMP_START_CALL}" =~ ^[0-9]+$ ||
        ! "${TENSOR_DUMP_MAX_CALLS}" =~ ^[0-9]+$ ]]; then
    echo "Tensor dump call bounds must be non-negative integers." >&2
    return 2
  fi
  if [[ ! -d "${REPO_DIR}" ]]; then
    echo "REPO_DIR does not exist: ${REPO_DIR}" >&2
    return 2
  fi
  if [[ "${EVAL_NAME}" == "gsm8k" && ! -f "${GSM8K_DATA_PATH}" ]]; then
    echo "GSM8K_DATA_PATH does not exist: ${GSM8K_DATA_PATH}" >&2
    return 2
  fi
  if [[ "${EVAL_NAME}" == "aime26" ]]; then
    if [[ ! -d "${AIME26_DATA_PATH}" ]]; then
      echo "AIME26_DATA_PATH does not exist: ${AIME26_DATA_PATH}" >&2
      return 2
    fi
    if [[ ! -f "${AIME26_DATA_PATH}/test.jsonl" ]]; then
      echo "AIME26 test split does not exist: ${AIME26_DATA_PATH}/test.jsonl" >&2
      return 2
    fi
    if [[ -x "${EVALSCOPE_BIN}" ]]; then
      :
    elif resolved_evalscope_bin="$(command -v "${EVALSCOPE_BIN}" 2>/dev/null)" &&
         [[ -n "${resolved_evalscope_bin}" ]]; then
      EVALSCOPE_BIN="${resolved_evalscope_bin}"
    elif resolved_evalscope_bin="$(command -v evalscope 2>/dev/null)" &&
         [[ -n "${resolved_evalscope_bin}" ]]; then
      EVALSCOPE_BIN="${resolved_evalscope_bin}"
    else
      echo "EvalScope executable was not found: ${EVALSCOPE_BIN}" >&2
      echo "AIME26 requires EvalScope >= 1.5.1; set EVALSCOPE_BIN explicitly." >&2
      return 2
    fi
    if [[ -z "${EVAL_MODEL:-}" && -z "${MODEL_PATH}" ]]; then
      echo "AIME26 requires MODEL_PATH or EVAL_MODEL." >&2
      return 2
    fi
  fi
}

server_processes_still_running() {
  pgrep -f "sglang.*launch_server" >/dev/null 2>&1 ||
    pgrep -f "sglang::" >/dev/null 2>&1
}

stop_server() {
  local start_time
  local elapsed

  pkill -f "sglang.*launch_server" >/dev/null 2>&1 || true
  pkill -f "sglang::" >/dev/null 2>&1 || true
  start_time="$(date +%s)"
  while server_processes_still_running; do
    elapsed=$(( $(date +%s) - start_time ))
    if (( elapsed >= SERVER_STOP_TIMEOUT_SEC )); then
      log_msg "Server processes did not exit within ${SERVER_STOP_TIMEOUT_SEC}s."
      pgrep -af "sglang.*launch_server" | tee -a "${CURRENT_LOG}" || true
      pgrep -af "sglang::" | tee -a "${CURRENT_LOG}" || true
      return 1
    fi
    sleep 1
  done
}

wait_for_server_ready() {
  local url="http://${HOST}:${PORT}${SERVER_READY_PATH}"
  local start_time
  local elapsed

  start_time="$(date +%s)"
  log_msg "[$(date '+%F %T')] waiting up to ${READY_CHECK_TIMEOUT_SEC}s for ${url}"
  while true; do
    if curl -fsS --max-time 5 "${url}" >/dev/null 2>&1; then
      elapsed=$(( $(date +%s) - start_time ))
      log_msg "[$(date '+%F %T')] server ready after ${elapsed}s"
      return 0
    fi
    elapsed=$(( $(date +%s) - start_time ))
    if (( elapsed >= READY_CHECK_TIMEOUT_SEC )); then
      log_msg "Server did not become ready within ${READY_CHECK_TIMEOUT_SEC}s."
      return 1
    fi
    sleep 2
  done
}

start_server() {
  local server_log="$1"

  stop_server
  if [[ ! -x "${SERVER_START_SCRIPT}" ]]; then
    log_msg "Server start script is not executable: ${SERVER_START_SCRIPT}"
    return 1
  fi
  log_msg "[$(date '+%F %T')] starting server; log=${server_log}"
  nohup "${SERVER_START_SCRIPT}" > "${server_log}" 2>&1 &
  log_msg "server_pid=$!"
  wait_for_server_ready
}

configure_tensor_dump() {
  local run_dir="$1"
  local dump_dir="${TENSOR_DUMP_DIR:-${run_dir}/tensor_dump}"

  if [[ "${TENSOR_DUMP}" == "0" ]]; then
    unset SGLANG_NPU_SPARSE_DEBUG_DIR
    unset SGLANG_NPU_SPARSE_DEBUG_LAYERS
    unset SGLANG_NPU_SPARSE_DEBUG_LEVEL
    unset SGLANG_NPU_SPARSE_DEBUG_START_CALL
    unset SGLANG_NPU_SPARSE_DEBUG_MAX_CALLS
    return
  fi
  mkdir -p "${dump_dir}"
  export SGLANG_NPU_SPARSE_DEBUG_DIR="${dump_dir}"
  export SGLANG_NPU_SPARSE_DEBUG_LAYERS="${TENSOR_DUMP_LAYERS}"
  export SGLANG_NPU_SPARSE_DEBUG_LEVEL="${TENSOR_DUMP_LEVEL}"
  export SGLANG_NPU_SPARSE_DEBUG_START_CALL="${TENSOR_DUMP_START_CALL}"
  export SGLANG_NPU_SPARSE_DEBUG_MAX_CALLS="${TENSOR_DUMP_MAX_CALLS}"
}

collect_eval_artifacts() {
  local eval_log="$1"
  local run_dir="$2"
  local artifact

  while IFS= read -r artifact; do
    if [[ -f "${artifact}" ]]; then
      mv -- "${artifact}" "${run_dir}/"
    fi
  done < <(sed -n \
    -e 's/^Writing report to //p' \
    -e 's/^Writing results to //p' \
    "${eval_log}")
}

run_eval_case() {
  local run_dir="$1"
  local restart_server="$2"
  local config_name="${3:-single}"
  local iteration="${4:-1}"
  local eval_log="${run_dir}/eval.log"
  local server_log="${run_dir}/server.log"
  local eval_status
  local num_threads
  local eval_model
  local api_url
  local normalized_base_url
  local model_path_without_slash
  local -a cmd

  if [[ "${restart_server}" != "0" && "${restart_server}" != "1" ]]; then
    echo "RESTART_SERVER must be 0 or 1." >&2
    return 2
  fi
  mkdir -p "${run_dir}"
  CURRENT_LOG="${eval_log}"
  configure_tensor_dump "${run_dir}"
  export MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-1}"
  if [[ -n "${NUM_THREADS:-}" ]]; then
    num_threads="${NUM_THREADS}"
  elif [[ "${config_name}" == "single" ]]; then
    num_threads=128
  else
    num_threads="${MAX_RUNNING_REQUESTS}"
  fi

  log_msg "[$(date '+%F %T')] ${BENCHMARK_LABEL} eval started"
  log_msg "repo_dir=${REPO_DIR} run_dir=${run_dir}"
  log_msg "config=${config_name} iteration=${iteration}"
  log_msg "cuda_graph_mode=${CUDA_GRAPH_MODE:-} cuda_graph_bs=${CUDA_GRAPH_BS:-}"
  log_msg "max_running_requests=${MAX_RUNNING_REQUESTS}"
  log_msg "context_length=${CONTEXT_LENGTH} max_output_tokens=${MAX_TOKENS}"
  log_msg "num_examples=${NUM_EXAMPLES} num_threads=${num_threads} num_shots=${NUM_SHOTS}"
  if [[ "${EVAL_NAME}" == "gsm8k" ]]; then
    log_msg "gsm8k_data_path=${GSM8K_DATA_PATH}"
  else
    log_msg "aime26_data_path=${AIME26_DATA_PATH}"
    log_msg "generation_config=${AIME26_GENERATION_CONFIG}"
  fi
  log_msg "tensor_dump=${TENSOR_DUMP} tensor_dump_dir=${SGLANG_NPU_SPARSE_DEBUG_DIR:-}"

  if [[ "${restart_server}" == "1" ]]; then
    start_server "${server_log}"
  else
    echo "Server restart disabled; using the existing server." > "${server_log}"
  fi

  cd "${REPO_DIR}"
  export PYTHONPATH="${REPO_DIR}/python${PYTHONPATH:+:${PYTHONPATH}}"
  export OPENAI_API_KEY="${OPENAI_API_KEY:-EMPTY}"
  if [[ "${EVAL_NAME}" == "gsm8k" ]]; then
    cmd=(
      python3 -m sglang.test.run_eval
      --eval-name gsm8k
      --num-examples "${NUM_EXAMPLES}"
      --num-threads "${num_threads}"
      --num-shots "${NUM_SHOTS}"
      --max-tokens "${MAX_TOKENS}"
      --temperature "${TEMPERATURE}"
      --top-p "${TOP_P}"
      --api "${API}"
    )
    if [[ -n "${MODEL_PATH}" ]]; then
      cmd+=(--model "${MODEL_PATH}")
    fi
    if [[ -n "${BASE_URL}" ]]; then
      cmd+=(--base-url "${BASE_URL}")
    else
      cmd+=(--host "${HOST}" --port "${PORT}")
    fi
    if [[ -n "${THINKING_MODE}" ]]; then
      cmd+=(--thinking-mode "${THINKING_MODE}")
    fi
    cmd+=(--gsm8k-data-path "${GSM8K_DATA_PATH}")
  else
    model_path_without_slash="${MODEL_PATH%/}"
    eval_model="${EVAL_MODEL:-${model_path_without_slash##*/}}"
    if [[ -n "${BASE_URL}" ]]; then
      normalized_base_url="${BASE_URL%/}"
      case "${normalized_base_url}" in
        */v1/chat/completions) api_url="${normalized_base_url}" ;;
        */v1) api_url="${normalized_base_url}/chat/completions" ;;
        *) api_url="${normalized_base_url}/v1/chat/completions" ;;
      esac
    else
      api_url="http://${HOST}:${PORT}/v1/chat/completions"
    fi
    mkdir -p "${run_dir}/evalscope_output"
    cmd=(
      "${EVALSCOPE_BIN}" eval
      --model "${eval_model}"
      --api-url "${api_url}"
      --eval-type openai_api
      --datasets aime26
      --eval-batch-size "${EVAL_BATCH_SIZE:-${num_threads}}"
      --limit "${NUM_EXAMPLES}"
      --generation-config "${AIME26_GENERATION_CONFIG}"
      --work-dir "${EVALSCOPE_WORK_DIR:-${run_dir}/evalscope_output}"
    )
    cmd+=(--dataset-args "${AIME26_DATASET_ARGS}")
    if [[ -n "${DATASET_DIR:-}" ]]; then
      cmd+=(--dataset-dir "${DATASET_DIR}")
    fi
  fi
  if (( EXTRA_EVAL_ARG_COUNT > 0 )); then
    cmd+=("${EXTRA_EVAL_ARGS[@]}")
  fi

  printf 'Running: ' | tee -a "${eval_log}"
  printf '%q ' "${cmd[@]}" | tee -a "${eval_log}"
  printf '\n' | tee -a "${eval_log}"
  set +e
  "${cmd[@]}" 2>&1 | tee -a "${eval_log}"
  eval_status=${PIPESTATUS[0]}
  set -e
  if [[ "${EVAL_NAME}" == "gsm8k" ]]; then
    collect_eval_artifacts "${eval_log}" "${run_dir}"
  fi
  log_msg "[$(date '+%F %T')] ${BENCHMARK_LABEL} eval exit_status=${eval_status}"
  log_msg "artifacts saved in: ${run_dir}"
  return "${eval_status}"
}

validate_sweep_options() {
  local config
  local -a configs

  if [[ ! "${NUM_ITERS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "NUM_ITERS must be a positive integer." >&2
    return 2
  fi
  if [[ "${RESUME}" != "0" && "${RESUME}" != "1" ]]; then
    echo "RESUME must be 0 or 1." >&2
    return 2
  fi
  read -r -a configs <<< "${SWEEP_CONFIGS}"
  if [[ "${#configs[@]}" -eq 0 ]]; then
    echo "SWEEP_CONFIGS must not be empty." >&2
    return 2
  fi
  for config in "${configs[@]}"; do
    if [[ ! "${config}" =~ ^(graph|eager):[1-9][0-9]*$ ]]; then
      echo "Invalid sweep config '${config}'; expected graph:N or eager:N." >&2
      return 2
    fi
  done
}

case_is_complete() {
  local run_dir="$1"
  [[ "${RESUME}" == "1" && -f "${run_dir}/.complete" ]]
}

run_sweep() {
  local sweep_dir="$1"
  local sweep_log="${sweep_dir}/sweep.log"
  local status_file="${sweep_dir}/status.tsv"
  local config mode bs config_name run_dir iter case_status
  local overall_status=0
  local -a configs

  validate_sweep_options
  read -r -a configs <<< "${SWEEP_CONFIGS}"
  mkdir -p "${sweep_dir}"
  if [[ ! -f "${status_file}" ]]; then
    printf 'time\tconfig\titer\texit_status\trun_dir\n' > "${status_file}"
  fi
  CURRENT_LOG="${sweep_log}"
  log_msg "[$(date '+%F %T')] ${BENCHMARK_LABEL} sweep started"
  log_msg "sweep_dir=${sweep_dir} configs=${configs[*]} num_iters=${NUM_ITERS} resume=${RESUME}"

  for config in "${configs[@]}"; do
    mode="${config%%:*}"
    bs="${config##*:}"
    if [[ "${mode}" == "graph" ]]; then
      config_name="cuda_graph_bs${bs}"
    else
      config_name="eager_bs${bs}"
    fi
    for ((iter = 1; iter <= NUM_ITERS; iter++)); do
      run_dir="${sweep_dir}/${config_name}/iter_${iter}"
      mkdir -p "${run_dir}"
      {
        echo "SERVER_CONFIG_NAME=${config_name}"
        echo "CUDA_GRAPH_MODE=${mode}"
        echo "CUDA_GRAPH_BS=${bs}"
        echo "MAX_RUNNING_REQUESTS=${bs}"
        echo "ITERATION=${iter}"
      } > "${run_dir}/config.env"

      CURRENT_LOG="${sweep_log}"
      if case_is_complete "${run_dir}"; then
        log_msg "skip completed config=${config_name} iter=${iter}"
        printf '%s\t%s\t%s\tSKIPPED\t%s\n' \
          "$(date '+%F %T')" "${config_name}" "${iter}" "${run_dir}" >> "${status_file}"
        continue
      fi
      set +e
      (
        set -Eeuo pipefail
        export CUDA_GRAPH_MODE="${mode}"
        export CUDA_GRAPH_BS="${bs}"
        export MAX_RUNNING_REQUESTS="${bs}"
        run_eval_case "${run_dir}" 1 "${config_name}" "${iter}"
      )
      case_status=$?
      set -e
      CURRENT_LOG="${sweep_log}"
      echo "${case_status}" > "${run_dir}/exit_status"
      if [[ "${case_status}" -eq 0 ]]; then
        touch "${run_dir}/.complete"
      else
        rm -f "${run_dir}/.complete"
        overall_status=1
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%F %T')" "${config_name}" "${iter}" "${case_status}" "${run_dir}" >> "${status_file}"
    done
  done
  CURRENT_LOG="${sweep_log}"
  log_msg "[$(date '+%F %T')] ${BENCHMARK_LABEL} sweep finished; status=${overall_status}"
  return "${overall_status}"
}

resolve_default_sweep_dir() {
  local prefix="sweep"
  local latest=""

  if [[ -n "${SWEEP_LABEL}" ]]; then
    if [[ ! "${SWEEP_LABEL}" =~ ^[[:alnum:]_.-]+$ ]]; then
      echo "Invalid SWEEP_LABEL='${SWEEP_LABEL}'." >&2
      return 2
    fi
    prefix="sweep_${SWEEP_LABEL}"
  fi
  if [[ "${RESUME}" == "1" ]]; then
    latest="$(find "${LOG_DIR}" -maxdepth 1 -type d -name "${prefix}_*" 2>/dev/null | sort | tail -n 1)"
  fi
  echo "${SWEEP_DIR:-${latest:-${LOG_DIR}/${prefix}_${RUN_TS}}}"
}

branch_exists() {
  local branch="$1"
  git -C "${REPO_DIR}" show-ref --verify --quiet "refs/heads/${branch}" ||
    git -C "${REPO_DIR}" show-ref --verify --quiet "refs/remotes/${BRANCH_REMOTE}/${branch}"
}

switch_branch() {
  local branch="$1"

  if git -C "${REPO_DIR}" show-ref --verify --quiet "refs/heads/${branch}"; then
    git -C "${REPO_DIR}" switch "${branch}"
  else
    git -C "${REPO_DIR}" switch --track -c "${branch}" "${BRANCH_REMOTE}/${branch}"
  fi
  if [[ "${UPDATE_FROM_REMOTE}" == "1" ]] &&
     git -C "${REPO_DIR}" show-ref --verify --quiet "refs/remotes/${BRANCH_REMOTE}/${branch}"; then
    git -C "${REPO_DIR}" merge --ff-only "${BRANCH_REMOTE}/${branch}"
  fi
}

restore_original_checkout() {
  local previous_status=$?
  set +e
  if [[ "${RESTORE_CHECKOUT}" == "1" ]]; then
    stop_server
    if [[ -n "${ORIGINAL_BRANCH}" ]]; then
      git -C "${REPO_DIR}" switch "${ORIGINAL_BRANCH}" >> "${CURRENT_LOG}" 2>&1
    else
      git -C "${REPO_DIR}" switch --detach "${ORIGINAL_HEAD}" >> "${CURRENT_LOG}" 2>&1
    fi
    RESTORE_CHECKOUT=0
  fi
  return "${previous_status}"
}

run_compare() {
  local common_label="${COMPARE_LABEL#base_}"
  local compare_dir compare_log status_file variant branch variant_status commit
  local overall_status=0
  local -a variants

  common_label="${common_label#our_}"
  if [[ ! "${common_label}" =~ ^[[:alnum:]_.-]+$ ]]; then
    echo "Invalid COMPARE_LABEL='${COMPARE_LABEL}'." >&2
    return 2
  fi
  if [[ ! -d "${REPO_DIR}/.git" && ! -f "${REPO_DIR}/.git" ]]; then
    echo "REPO_DIR is not a git worktree: ${REPO_DIR}" >&2
    return 2
  fi
  if ! git -C "${REPO_DIR}" diff --quiet ||
     ! git -C "${REPO_DIR}" diff --cached --quiet; then
    echo "Tracked changes exist in ${REPO_DIR}; commit or stash them first." >&2
    return 2
  fi
  if [[ "${UPDATE_FROM_REMOTE}" == "1" ]]; then
    git -C "${REPO_DIR}" fetch --prune "${BRANCH_REMOTE}"
  elif [[ "${UPDATE_FROM_REMOTE}" != "0" ]]; then
    echo "UPDATE_FROM_REMOTE must be 0 or 1." >&2
    return 2
  fi

  read -r -a variants <<< "${COMPARE_VARIANTS}"
  if [[ "${#variants[@]}" -eq 0 ]]; then
    echo "COMPARE_VARIANTS must contain base, ours, or both." >&2
    return 2
  fi
  for variant in "${variants[@]}"; do
    case "${variant}" in
      base) branch="${BASE_BRANCH}" ;;
      ours) branch="${OUR_BRANCH}" ;;
      *) echo "Invalid comparison variant '${variant}'." >&2; return 2 ;;
    esac
    if ! branch_exists "${branch}"; then
      echo "Branch does not exist locally or at ${BRANCH_REMOTE}: ${branch}" >&2
      return 2
    fi
  done

  compare_dir="${COMPARE_DIR:-${LOG_DIR}/compare_${common_label}_${RUN_TS}}"
  compare_log="${compare_dir}/compare.log"
  status_file="${compare_dir}/status.tsv"
  mkdir -p "${compare_dir}"
  printf 'variant\tbranch\tcommit\texit_status\tsweep_dir\n' > "${status_file}"
  CURRENT_LOG="${compare_log}"
  ORIGINAL_BRANCH="$(git -C "${REPO_DIR}" symbolic-ref --quiet --short HEAD || true)"
  ORIGINAL_HEAD="$(git -C "${REPO_DIR}" rev-parse HEAD)"
  RESTORE_CHECKOUT=1
  trap restore_original_checkout EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  log_msg "[$(date '+%F %T')] ${BENCHMARK_LABEL} branch comparison started"
  log_msg "compare_dir=${compare_dir} variants=${variants[*]}"
  for variant in "${variants[@]}"; do
    if [[ "${variant}" == "base" ]]; then
      branch="${BASE_BRANCH}"
    else
      branch="${OUR_BRANCH}"
    fi
    stop_server
    CURRENT_LOG="${compare_log}"
    log_msg "===== variant=${variant} branch=${branch} ====="
    switch_branch "${branch}" 2>&1 | tee -a "${compare_log}"
    commit="$(git -C "${REPO_DIR}" rev-parse HEAD)"
    set +e
    (
      set -Eeuo pipefail
      run_sweep "${compare_dir}/${variant}"
    )
    variant_status=$?
    set -e
    CURRENT_LOG="${compare_log}"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "${variant}" "${branch}" "${commit}" "${variant_status}" "${compare_dir}/${variant}" >> "${status_file}"
    if [[ "${variant_status}" -ne 0 ]]; then
      overall_status=1
    fi
  done
  CURRENT_LOG="${compare_log}"
  log_msg "[$(date '+%F %T')] ${BENCHMARK_LABEL} branch comparison finished; status=${overall_status}"
  return "${overall_status}"
}

main() {
  local run_dir sweep_dir

  if [[ "${RUN_MODE}" == "help" ]]; then
    usage
    return 0
  fi
  validate_common_options
  mkdir -p "${LOG_DIR}"
  case "${RUN_MODE}" in
    single)
      run_dir="${RUN_DIR:-${LOG_DIR}/${RUN_PREFIX}_${RUN_TS}}"
      run_eval_case "${run_dir}" "${RESTART_SERVER:-0}"
      ;;
    sweep)
      sweep_dir="$(resolve_default_sweep_dir)"
      run_sweep "${sweep_dir}"
      ;;
    compare)
      run_compare
      ;;
    *)
      echo "Unknown mode '${RUN_MODE}'." >&2
      usage >&2
      return 2
      ;;
  esac
}

main
