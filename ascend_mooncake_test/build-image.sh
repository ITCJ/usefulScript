#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env
require_command docker

PROXY_BUILD_ARGS=()
PROXY_NAMES=()
for proxy_name in \
  HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY \
  http_proxy https_proxy no_proxy all_proxy; do
  proxy_value=${!proxy_name:-}
  if [[ -n "${proxy_value}" ]]; then
    # Passing only the variable name makes Docker read its value from the
    # current shell without placing the credential-bearing URL in argv/logs.
    PROXY_BUILD_ARGS+=(--build-arg "${proxy_name}")
    PROXY_NAMES+=("${proxy_name}")
  fi
done

if ((${#PROXY_NAMES[@]} > 0)); then
  log "Using build proxy variables: ${PROXY_NAMES[*]} (values hidden)"
else
  log "No build proxy variables detected"
fi

if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  log "Base image is not local; pulling ${BASE_IMAGE}"
  if ! docker pull "${BASE_IMAGE}"; then
    die "Failed to pull the base image. Configure the Docker daemon proxy, or load the base image locally, then retry"
  fi
fi

log "Building ${RUNTIME_IMAGE} from ${BASE_IMAGE}"
docker build \
  "${PROXY_BUILD_ARGS[@]}" \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "MOONCAKE_VERSION=${MOONCAKE_VERSION}" \
  --tag "${RUNTIME_IMAGE}" \
  "${SCRIPT_DIR}"

log "Image built: ${RUNTIME_IMAGE}"
