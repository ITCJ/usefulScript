#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE=${ENV_FILE:-${DEPLOY_DIR}/deploy.env}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "[$(date '+%F %T')] $*"
}

load_env() {
  [[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE}; copy deploy.env.example to deploy.env first"
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a

  : "${RUNTIME_IMAGE:?RUNTIME_IMAGE is required}"
  : "${MODEL_HOST_PATH:?MODEL_HOST_PATH is required}"
  : "${MODEL_CONTAINER_PATH:?MODEL_CONTAINER_PATH is required}"
  : "${DEPLOY_MODE:?DEPLOY_MODE is required}"
  : "${TP_SIZE:?TP_SIZE is required}"
  : "${NPU_COUNT_PER_ROLE:?NPU_COUNT_PER_ROLE is required}"
  : "${PREFILL_IP:?PREFILL_IP is required}"
  : "${DECODE_IP:?DECODE_IP is required}"

  [[ "${DEPLOY_MODE}" == "single" || "${DEPLOY_MODE}" == "split" ]] || \
    die "DEPLOY_MODE must be single or split"
  [[ "${TP_SIZE}" -le "${NPU_COUNT_PER_ROLE}" ]] || \
    die "TP_SIZE cannot exceed NPU_COUNT_PER_ROLE"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

find_npu_smi() {
  local candidate
  candidate=$(command -v npu-smi 2>/dev/null || true)
  if [[ -n "${candidate}" && -x "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  for candidate in /usr/local/bin/npu-smi /usr/local/sbin/npu-smi; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

required_home_mounts() {
  local raw=${REQUIRED_HOME_MOUNTS:-} path
  [[ -n "${raw}" ]] || return 0
  IFS=',' read -r -a paths <<< "${raw}"
  for path in "${paths[@]}"; do
    path=${path#"${path%%[![:space:]]*}"}
    path=${path%"${path##*[![:space:]]}"}
    [[ -n "${path}" ]] && printf '%s\n' "${path}"
  done
}

validate_required_home_mounts() {
  local path
  while IFS= read -r path; do
    [[ -d "${path}" ]] || die "Required home mount does not exist: ${path}"
  done < <(required_home_mounts)
}

role_base_npu() {
  local role=$1
  if [[ "${DEPLOY_MODE}" == "single" && "${role}" == "decode" ]]; then
    echo "${NPU_COUNT_PER_ROLE}"
  else
    echo 0
  fi
}

role_npu_ids() {
  local role=$1 base i ids=()
  base=$(role_base_npu "${role}")
  for ((i = 0; i < NPU_COUNT_PER_ROLE; i++)); do
    ids+=("$((base + i))")
  done
  printf '%s\n' "${ids[@]}"
}

role_name() {
  echo "${CONTAINER_PREFIX}-${1}"
}

append_existing_device() {
  local path=$1
  if [[ -e "${path}" ]]; then
    DOCKER_ARGS+=(--device "${path}")
  fi
}

build_docker_args() {
  local role=$1 id npu_smi_path
  DOCKER_ARGS=(
    --detach
    --init
    --user 0:0
    --name "$(role_name "${role}")"
    --network host
    --ipc host
    --shm-size "${SHM_SIZE}"
    --ulimit memlock=-1:-1
    --ulimit stack=67108864:67108864
    --cap-add IPC_LOCK
    --security-opt seccomp=unconfined
  )

  if [[ "${USE_PRIVILEGED}" == "1" ]]; then
    DOCKER_ARGS+=(--privileged)
  fi

  append_existing_device /dev/davinci_manager
  append_existing_device /dev/devmm_svm
  append_existing_device /dev/hisi_hdc
  while IFS= read -r id; do
    [[ -e "/dev/davinci${id}" ]] || die "Missing /dev/davinci${id} for role ${role}"
    DOCKER_ARGS+=(--device "/dev/davinci${id}")
  done < <(role_npu_ids "${role}")

  [[ -d /usr/local/Ascend/driver ]] && \
    DOCKER_ARGS+=(--volume /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro)
  [[ -d /usr/local/Ascend/firmware ]] && \
    DOCKER_ARGS+=(--volume /usr/local/Ascend/firmware:/usr/local/Ascend/firmware:ro)
  [[ -d /usr/local/Ascend/add-ons ]] && \
    DOCKER_ARGS+=(--volume /usr/local/Ascend/add-ons:/usr/local/Ascend/add-ons:ro)
  [[ -d /usr/local/dcmi ]] && \
    DOCKER_ARGS+=(--volume /usr/local/dcmi:/usr/local/dcmi:ro)
  [[ -d /usr/local/sbin ]] && \
    DOCKER_ARGS+=(--volume /usr/local/sbin:/usr/local/sbin:ro)
  npu_smi_path=$(find_npu_smi || true)
  if [[ -n "${npu_smi_path}" && "${npu_smi_path}" != /usr/local/sbin/* ]]; then
    DOCKER_ARGS+=(--volume "${npu_smi_path}:${npu_smi_path}:ro")
  fi
  [[ -f /etc/localtime ]] && \
    DOCKER_ARGS+=(--volume /etc/localtime:/etc/localtime:ro)
  [[ -f /etc/ascend_install.info ]] && \
    DOCKER_ARGS+=(--volume /etc/ascend_install.info:/etc/ascend_install.info:ro)
  [[ -f /etc/hccn.conf ]] && \
    DOCKER_ARGS+=(--volume /etc/hccn.conf:/etc/hccn.conf:ro)
  [[ -d /var/queue_schedule ]] && \
    DOCKER_ARGS+=(--volume /var/queue_schedule:/var/queue_schedule)

  validate_required_home_mounts
  while IFS= read -r path; do
    DOCKER_ARGS+=(--volume "${path}:${path}:rw")
  done < <(required_home_mounts)

  if [[ "${ENABLE_NPU_DIAGNOSTIC_MOUNTS:-0}" == "1" ]]; then
    [[ -f /var/log/npu/conf/slog/slog.conf ]] && \
      DOCKER_ARGS+=(--volume /var/log/npu/conf/slog/slog.conf:/var/log/npu/conf/slog/slog.conf:ro)
    [[ -d /var/log/npu/slog ]] && \
      DOCKER_ARGS+=(--volume /var/log/npu/slog:/var/log/npu/slog:rw)
    [[ -d /var/log/npu/profiling ]] && \
      DOCKER_ARGS+=(--volume /var/log/npu/profiling:/var/log/npu/profiling:rw)
    [[ -d /var/log/npu/dump ]] && \
      DOCKER_ARGS+=(--volume /var/log/npu/dump:/var/log/npu/dump:rw)
  fi

  DOCKER_ARGS+=(
    --volume "${MODEL_HOST_PATH}:${MODEL_CONTAINER_PATH}:ro"
    --volume "${LOG_DIR}:/logs"
    --volume "${DEPLOY_DIR}:/opt/sglang-mooncake-deploy:ro"
  )
  if [[ -n "${TOKENIZER_HOST_PATH:-}" ]]; then
    DOCKER_ARGS+=(--volume "${TOKENIZER_HOST_PATH}:${TOKENIZER_CONTAINER_PATH}:ro")
  fi
  if [[ -n "${HF_CACHE_HOST_PATH:-}" ]]; then
    mkdir -p "${HF_CACHE_HOST_PATH}"
    DOCKER_ARGS+=(--volume "${HF_CACHE_HOST_PATH}:/root/.cache/huggingface")
  fi
}
