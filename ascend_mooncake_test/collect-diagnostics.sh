#!/usr/bin/env bash
set -Eeuo pipefail

ROLE=${1:-prefill}
case "${ROLE}" in
  prefill|decode|router) ;;
  *)
    echo "Usage: $0 [prefill|decode|router] [output-directory]" >&2
    exit 2
    ;;
esac

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUTPUT_DIR=${2:-${PWD}}
ENV_FILE=${ENV_FILE:-${SCRIPT_DIR}/deploy.env}

CONTAINER_PREFIX=sglang-mc
LOG_DIR=/var/log/sglang-mooncake
RUNTIME_IMAGE=
NPU_COUNT_PER_ROLE=16
DEPLOY_MODE=split
PREFILL_IP=
DECODE_IP=
PREFILL_HTTP_PORT=30000
DECODE_HTTP_PORT=30001
PREFILL_BOOTSTRAP_PORT=8998

if [[ -f "${ENV_FILE}" ]]; then
  # deploy.env is trusted local configuration. Do not copy the file into the
  # diagnostic archive because it may contain private paths or credentials.
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

command -v docker >/dev/null 2>&1 || {
  echo "docker is not available" >&2
  exit 1
}
mkdir -p "${OUTPUT_DIR}"

timestamp=$(date '+%Y%m%d-%H%M%S')
container_name="${CONTAINER_PREFIX}-${ROLE}"
tmp_dir=$(mktemp -d "/tmp/sglang-mc-diagnostics.${ROLE}.XXXXXX")
archive_path="${OUTPUT_DIR}/sglang-mc-${ROLE}-diagnostics-${timestamp}.tar.gz"

cleanup() {
  rm -rf -- "${tmp_dir}"
}
trap cleanup EXIT

capture() {
  local output_file=$1
  shift
  {
    echo "COMMAND: $*"
    echo "TIME: $(date --iso-8601=seconds 2>/dev/null || date)"
    echo
    "$@"
  } >"${tmp_dir}/${output_file}" 2>&1 || true
}

capture_shell() {
  local output_file=$1
  shift
  {
    echo "TIME: $(date --iso-8601=seconds 2>/dev/null || date)"
    echo
    "$@"
  } >"${tmp_dir}/${output_file}" 2>&1 || true
}

write_summary() {
  {
    echo "role=${ROLE}"
    echo "container=${container_name}"
    echo "collected_at=$(date --iso-8601=seconds 2>/dev/null || date)"
    echo "hostname=$(hostname)"
    echo "architecture=$(uname -m)"
    echo "kernel=$(uname -r)"
    echo "deploy_mode=${DEPLOY_MODE}"
    echo "npu_count_per_role=${NPU_COUNT_PER_ROLE}"
    echo "runtime_image=${RUNTIME_IMAGE}"
    echo "prefill_ip=${PREFILL_IP}"
    echo "decode_ip=${DECODE_IP}"
    echo "prefill_http_port=${PREFILL_HTTP_PORT}"
    echo "decode_http_port=${DECODE_HTTP_PORT}"
    echo "prefill_bootstrap_port=${PREFILL_BOOTSTRAP_PORT}"
  } >"${tmp_dir}/summary.txt"
}

container_state() {
  docker inspect --format \
    'status={{.State.Status}} running={{.State.Running}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} pid={{.State.Pid}} error={{.State.Error}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}' \
    "${container_name}"
}

container_command() {
  docker inspect --format \
    'path={{.Path}} args={{json .Args}} image_id={{.Image}} configured_image={{.Config.Image}}' \
    "${container_name}"
}

container_log_config() {
  docker inspect --format \
    'type={{.HostConfig.LogConfig.Type}} config={{json .HostConfig.LogConfig.Config}} log_path={{.LogPath}}' \
    "${container_name}"
}

container_mounts() {
  docker inspect --format \
    '{{range .Mounts}}{{println .Type .Source "->" .Destination "rw=" .RW}}{{end}}' \
    "${container_name}"
}

container_devices() {
  docker inspect --format \
    'privileged={{.HostConfig.Privileged}} devices={{json .HostConfig.Devices}} caps={{json .HostConfig.CapAdd}} ipc={{.HostConfig.IpcMode}} network={{.HostConfig.NetworkMode}} shm={{.HostConfig.ShmSize}}' \
    "${container_name}"
}

host_npu_info() {
  local npu_smi_bin
  npu_smi_bin=$(command -v npu-smi 2>/dev/null || true)
  [[ -n "${npu_smi_bin}" ]] || npu_smi_bin=/usr/local/bin/npu-smi
  [[ -x "${npu_smi_bin}" ]] || npu_smi_bin=/usr/local/sbin/npu-smi
  if [[ -x "${npu_smi_bin}" ]]; then
    "${npu_smi_bin}" info -l
    echo
    "${npu_smi_bin}" info
  else
    echo "npu-smi not found"
  fi
}

host_hccn_info() {
  local hccn_tool_bin i
  hccn_tool_bin=$(command -v hccn_tool 2>/dev/null || true)
  if [[ -z "${hccn_tool_bin}" && -x /usr/local/Ascend/driver/tools/hccn_tool ]]; then
    hccn_tool_bin=/usr/local/Ascend/driver/tools/hccn_tool
  fi
  if [[ -z "${hccn_tool_bin}" ]]; then
    echo "hccn_tool not found"
    return 0
  fi
  for ((i = 0; i < NPU_COUNT_PER_ROLE; i++)); do
    echo "===== NPU ${i} ====="
    "${hccn_tool_bin}" -i "${i}" -ip -g || true
  done
}

host_log() {
  local log_file="${LOG_DIR}/${ROLE}.log"
  if [[ -f "${log_file}" ]]; then
    ls -l "${log_file}"
    tail -n 1000 "${log_file}"
  else
    echo "Host log does not exist: ${log_file}"
  fi
}

image_info() {
  [[ -n "${RUNTIME_IMAGE}" ]] || {
    echo "RUNTIME_IMAGE is not configured"
    return 0
  }
  docker image inspect --format \
    'id={{.Id}} created={{.Created}} architecture={{.Architecture}} os={{.Os}} size={{.Size}}' \
    "${RUNTIME_IMAGE}"
}

image_dependencies() {
  [[ -n "${RUNTIME_IMAGE}" ]] || return 0
  timeout 30 docker run --rm --entrypoint bash "${RUNTIME_IMAGE}" -lc '
set -u
uname -m
python3 --version
ldconfig -p | grep -E "libibverbs\.so\.1|libjemalloc\.so\.2|librdmacm\.so\.1|liburing\.so\.2" || true
python3 -m pip show sglang mooncake-transfer-engine-npu 2>/dev/null || true
' || true
}

write_summary
capture docker-version.txt docker version
capture docker-info.txt docker info
capture disk-memory.txt sh -c 'df -h; echo; free -h 2>/dev/null || true; echo; ulimit -a'
capture host-npu.txt host_npu_info
capture host-hccn.txt host_hccn_info
capture hccn-conf-metadata.txt stat /etc/hccn.conf
capture image-info.txt image_info
capture image-dependencies.txt image_dependencies

if docker inspect "${container_name}" >/dev/null 2>&1; then
  capture container-state.txt container_state
  capture container-command.txt container_command
  capture container-log-config.txt container_log_config
  capture container-mounts.txt container_mounts
  capture container-devices.txt container_devices
  capture container-top.txt docker top "${container_name}" -eo pid,ppid,user,stat,etime,args
  capture container-logs.txt docker logs --timestamps --tail 1000 "${container_name}"
else
  echo "Container not found: ${container_name}" >"${tmp_dir}/container-state.txt"
fi

capture_shell host-log.txt host_log

tar -C "${tmp_dir}" -czf "${archive_path}" .
echo "Diagnostic archive created: ${archive_path}"
echo "Review before sharing; logs may contain model paths and internal IP addresses."
