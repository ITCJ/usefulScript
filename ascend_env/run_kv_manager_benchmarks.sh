#!/usr/bin/env bash
set -euo pipefail

# Keep the benchmark entrypoint in ascend_env while running it from its source
# directory, because benchmark_unidex_copy.py loads local build artifacts.
REPO_ROOT="${REPO_ROOT:-/Users/tcj/Sync/prj_hw}"
UNINDEXCOPY_DIR="${UNINDEXCOPY_DIR:-${REPO_ROOT}/sparse_kv_operator_gitcode/unindexcopykernel}"

cd "${UNINDEXCOPY_DIR}"
exec ./run_kv_manager_benchmarks.sh "$@"
