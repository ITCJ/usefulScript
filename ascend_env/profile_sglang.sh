#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-6699}"
OUTPUT_DIR="${OUTPUT_DIR:-/home/tcj/profile_result}"
PROFILE_SLEEP="${PROFILE_SLEEP:-1}"
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <profile_name>" >&2
  exit 1
fi
PROFILE_NAME="$1"
PROFILE_OUTPUT_DIR="${OUTPUT_DIR}/$(date +%Y%m%d_%H%M%S)_${PROFILE_NAME}"

curl -X POST "http://${HOST}:${PORT}/start_profile" \
  -H "Content-Type: application/json" \
  -d '{"output_dir":"'"${PROFILE_OUTPUT_DIR}"'","activities":["CPU","GPU"]}'

sleep "${PROFILE_SLEEP}"

curl -X POST "http://${HOST}:${PORT}/stop_profile"
