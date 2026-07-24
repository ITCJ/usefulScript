#!/usr/bin/env bash
set -Eeuo pipefail

# Sequentially evaluate baseline and ours from the same clean git worktree.
# The server is stopped before every branch switch, and the original branch is
# restored when this script exits.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

REPO_DIR="${REPO_DIR:-/home/tcj/sglang-ascend}"
BASE_BRANCH="${BASE_BRANCH:-pr/ascend-sparse-kv-clean-v2-base}"
OUR_BRANCH="${OUR_BRANCH:-tcj-debug/print_our_tensor}"
BRANCH_REMOTE="${BRANCH_REMOTE:-origin}"
SWEEP_SCRIPT="${SWEEP_SCRIPT:-${SCRIPT_DIR}/run_gsm8k_eval_config_sweep.sh}"
LOG_DIR="${LOG_DIR:-${REPO_DIR}/gsm8k_eval_config_sweep_logs}"
RUN_TS="$(date +%Y%m%d_%H%M%S)"

COMMON_LABEL="${COMPARE_LABEL:-${SWEEP_LABEL:-branch_compare}}"
COMMON_LABEL="${COMMON_LABEL#base_}"
COMMON_LABEL="${COMMON_LABEL#our_}"
BASE_SWEEP_LABEL="${BASE_SWEEP_LABEL:-base_${COMMON_LABEL}}"
OUR_SWEEP_LABEL="${OUR_SWEEP_LABEL:-our_${COMMON_LABEL}}"
COMPARE_DIR="${COMPARE_DIR:-${LOG_DIR}/compare_${COMMON_LABEL}_${RUN_TS}}"
COMPARE_LOG="${COMPARE_DIR}/compare.log"
STATUS_FILE="${COMPARE_DIR}/status.tsv"
SERVER_STOP_TIMEOUT_SEC="${SERVER_STOP_TIMEOUT_SEC:-120}"

if [[ ! "${COMMON_LABEL}" =~ ^[[:alnum:]_.-]+$ ]]; then
  echo "Invalid comparison label '${COMMON_LABEL}'." >&2
  exit 2
fi

if [[ ! -d "${REPO_DIR}/.git" && ! -f "${REPO_DIR}/.git" ]]; then
  echo "REPO_DIR is not a git worktree: ${REPO_DIR}" >&2
  exit 2
fi

if [[ ! -x "${SWEEP_SCRIPT}" ]]; then
  echo "Sweep script is not executable: ${SWEEP_SCRIPT}" >&2
  exit 2
fi

if ! git -C "${REPO_DIR}" diff --quiet ||
  ! git -C "${REPO_DIR}" diff --cached --quiet; then
  echo "Tracked changes exist in ${REPO_DIR}; commit or stash them first." >&2
  exit 2
fi

for branch in "${BASE_BRANCH}" "${OUR_BRANCH}"; do
  if ! git -C "${REPO_DIR}" show-ref --verify --quiet "refs/heads/${branch}" &&
    ! git -C "${REPO_DIR}" show-ref --verify --quiet \
      "refs/remotes/${BRANCH_REMOTE}/${branch}"; then
    echo "Branch does not exist locally or at ${BRANCH_REMOTE}/${branch}." >&2
    echo "Run: git -C '${REPO_DIR}' fetch '${BRANCH_REMOTE}'" >&2
    exit 2
  fi
done

mkdir -p "${COMPARE_DIR}"
printf 'variant\tbranch\tcommit\texit_status\tsweep_dir\n' > "${STATUS_FILE}"

log_msg() {
  echo "$*" | tee -a "${COMPARE_LOG}"
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
      pgrep -af "sglang.*launch_server" | tee -a "${COMPARE_LOG}" || true
      pgrep -af "sglang::" | tee -a "${COMPARE_LOG}" || true
      return 1
    fi
    sleep 1
  done
}

switch_branch() {
  local branch="$1"

  if git -C "${REPO_DIR}" show-ref --verify --quiet "refs/heads/${branch}"; then
    git -C "${REPO_DIR}" switch "${branch}"
  else
    git -C "${REPO_DIR}" switch --track -c "${branch}" \
      "${BRANCH_REMOTE}/${branch}"
  fi
}

ORIGINAL_BRANCH="$(git -C "${REPO_DIR}" symbolic-ref --quiet --short HEAD || true)"
ORIGINAL_HEAD="$(git -C "${REPO_DIR}" rev-parse HEAD)"
RESTORED=0

restore_original_checkout() {
  local status=$?
  set +e

  stop_server
  if [[ "${RESTORED}" == "0" ]]; then
    if [[ -n "${ORIGINAL_BRANCH}" ]]; then
      git -C "${REPO_DIR}" switch "${ORIGINAL_BRANCH}" >> "${COMPARE_LOG}" 2>&1
    else
      git -C "${REPO_DIR}" switch --detach "${ORIGINAL_HEAD}" \
        >> "${COMPARE_LOG}" 2>&1
    fi
    RESTORED=1
  fi

  return "${status}"
}
trap restore_original_checkout EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_variant() {
  local variant="$1"
  local branch="$2"
  local sweep_label="$3"
  local sweep_dir="${COMPARE_DIR}/${variant}"
  local commit
  local status
  shift 3

  stop_server
  log_msg ""
  log_msg "===== $(date '+%F %T') variant=${variant} branch=${branch} ====="
  switch_branch "${branch}" 2>&1 | tee -a "${COMPARE_LOG}"
  commit="$(git -C "${REPO_DIR}" rev-parse HEAD)"
  log_msg "commit=${commit}"
  log_msg "sweep_dir=${sweep_dir}"

  set +e
  REPO_DIR="${REPO_DIR}" \
    LOG_DIR="${LOG_DIR}" \
    SWEEP_DIR="${sweep_dir}" \
    SWEEP_LABEL="${sweep_label}" \
    "${SWEEP_SCRIPT}" "$@"
  status=$?
  set -e

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${variant}" "${branch}" "${commit}" "${status}" "${sweep_dir}" \
    >> "${STATUS_FILE}"
  log_msg "variant=${variant} exit_status=${status}"
  stop_server || status=1
  return "${status}"
}

log_msg "[$(date '+%F %T')] GSM8K branch comparison started"
log_msg "repo_dir=${REPO_DIR}"
log_msg "base_branch=${BASE_BRANCH}"
log_msg "our_branch=${OUR_BRANCH}"
log_msg "compare_dir=${COMPARE_DIR}"

overall_status=0
run_variant "base" "${BASE_BRANCH}" "${BASE_SWEEP_LABEL}" "$@" ||
  overall_status=1
run_variant "ours" "${OUR_BRANCH}" "${OUR_SWEEP_LABEL}" "$@" ||
  overall_status=1

log_msg ""
log_msg "[$(date '+%F %T')] GSM8K branch comparison finished"
log_msg "compare_dir=${COMPARE_DIR}"
log_msg "status_file=${STATUS_FILE}"
exit "${overall_status}"
