#!/usr/bin/env bash
set -euo pipefail

# Verify that a downloaded ModelScope model directory matches the Git LFS
# SHA256 OIDs recorded by the ModelScope repository.
#
# Default repository:
#   https://www.modelscope.cn/taoxiaoxin/DeepSeek-V3.2-Exp-w8a8.git
#
# Examples:
#   ./verify_modelscope_lfs_hash.sh /data/models/DeepSeek-V3.2-Exp-w8a8
#   ./verify_modelscope_lfs_hash.sh --model-dir /data/models/DeepSeek-V3.2-Exp-w8a8
#   ./verify_modelscope_lfs_hash.sh --repo taoxiaoxin/DeepSeek-V3.2-Exp-w8a8 --model-dir /data/models/DeepSeek-V3.2-Exp-w8a8
#   ./verify_modelscope_lfs_hash.sh --check-small-files --model-dir /data/models/DeepSeek-V3.2-Exp-w8a8

DEFAULT_REPO="taoxiaoxin/DeepSeek-V3.2-Exp-w8a8"
MODEL_DIR=""
REPO="${DEFAULT_REPO}"
REVISION="HEAD"
REF_DIR=""
KEEP_REF=0
CHECK_SMALL_FILES=0

usage() {
  cat <<'EOF'
Usage:
  verify_modelscope_lfs_hash.sh MODEL_DIR
  verify_modelscope_lfs_hash.sh --model-dir MODEL_DIR [options]

Options:
  --repo REPO              ModelScope repo, e.g. taoxiaoxin/DeepSeek-V3.2-Exp-w8a8
                           or a full git URL. Default: taoxiaoxin/DeepSeek-V3.2-Exp-w8a8
  --revision REV           Git revision/tag/branch to verify against. Default: HEAD
  --ref-dir DIR            Directory for the pointer-only reference clone.
                           Default: a temporary directory under /tmp
  --keep-ref               Keep the reference clone after verification.
  --check-small-files      Also compare non-LFS files against the reference clone.
                           This requires fetching regular git files, but not LFS blobs.
  -h, --help               Show this help.

The script verifies Git LFS files by comparing each local file's sha256sum with
the LFS OID recorded in the ModelScope repository.
EOF
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

repo_to_url() {
  local repo_value="$1"
  if [[ "${repo_value}" == http://* || "${repo_value}" == https://* || "${repo_value}" == git@* ]]; then
    echo "${repo_value}"
  else
    echo "https://www.modelscope.cn/${repo_value}.git"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model-dir)
        [[ $# -ge 2 ]] || die "--model-dir requires a value"
        MODEL_DIR="$2"
        shift 2
        ;;
      --repo)
        [[ $# -ge 2 ]] || die "--repo requires a value"
        REPO="$2"
        shift 2
        ;;
      --revision)
        [[ $# -ge 2 ]] || die "--revision requires a value"
        REVISION="$2"
        shift 2
        ;;
      --ref-dir)
        [[ $# -ge 2 ]] || die "--ref-dir requires a value"
        REF_DIR="$2"
        shift 2
        ;;
      --keep-ref)
        KEEP_REF=1
        shift
        ;;
      --check-small-files)
        CHECK_SMALL_FILES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        if [[ -z "${MODEL_DIR}" ]]; then
          MODEL_DIR="$1"
          shift
        else
          die "unexpected argument: $1"
        fi
        ;;
    esac
  done
}

cleanup() {
  if [[ "${KEEP_REF}" -eq 0 && -n "${REF_DIR}" && -d "${REF_DIR}" && "${REF_DIR}" == /tmp/* ]]; then
    rm -rf "${REF_DIR}"
  fi
}

parse_args "$@"

[[ -n "${MODEL_DIR}" ]] || die "MODEL_DIR is required"
[[ -d "${MODEL_DIR}" ]] || die "MODEL_DIR does not exist: ${MODEL_DIR}"

need_cmd git
need_cmd git-lfs
need_cmd sha256sum

REPO_URL="$(repo_to_url "${REPO}")"

if [[ -z "${REF_DIR}" ]]; then
  REF_DIR="$(mktemp -d /tmp/modelscope-lfs-ref.XXXXXX)"
fi

trap cleanup EXIT

log "model dir: ${MODEL_DIR}"
log "repo url:  ${REPO_URL}"
log "revision:  ${REVISION}"
log "ref dir:   ${REF_DIR}"

if [[ ! -d "${REF_DIR}/.git" ]]; then
  log "cloning pointer-only reference repo"
  GIT_LFS_SKIP_SMUDGE=1 git clone "${REPO_URL}" "${REF_DIR}"
else
  log "using existing reference repo"
fi

cd "${REF_DIR}"
git lfs install --local >/dev/null
git fetch --all --tags --prune
GIT_LFS_SKIP_SMUDGE=1 git checkout "${REVISION}" >/dev/null

log "verifying LFS file sha256"

checked_count=0
missing_count=0
mismatch_count=0
lfs_list_file="$(mktemp /tmp/modelscope-lfs-list.XXXXXX)"
lfs_exclude_file="$(mktemp /tmp/modelscope-lfs-exclude.XXXXXX)"
git lfs ls-files -l > "${lfs_list_file}"
git lfs ls-files -n > "${lfs_exclude_file}"

while read -r oid marker path; do
  [[ -n "${oid}" && -n "${path}" ]] || continue

  local_file="${MODEL_DIR}/${path}"
  if [[ ! -f "${local_file}" ]]; then
    echo "MISSING ${path}"
    missing_count=$((missing_count + 1))
    continue
  fi

  actual="$(sha256sum "${local_file}" | awk '{print $1}')"
  if [[ "${actual}" != "${oid}" ]]; then
    echo "MISMATCH ${path}"
    echo "  expected: ${oid}"
    echo "  actual:   ${actual}"
    mismatch_count=$((mismatch_count + 1))
    continue
  fi

  echo "OK ${path}"
  checked_count=$((checked_count + 1))
done < "${lfs_list_file}"

rm -f "${lfs_list_file}"

if [[ "${missing_count}" -ne 0 || "${mismatch_count}" -ne 0 ]]; then
  echo
  echo "LFS verification failed: checked=${checked_count}, missing=${missing_count}, mismatch=${mismatch_count}" >&2
  exit 1
fi

echo
echo "LFS verification passed: checked=${checked_count}"

if [[ "${CHECK_SMALL_FILES}" -eq 1 ]]; then
  need_cmd rsync
  log "checking non-LFS files by rsync checksum dry-run"
  rsync -rcn --delete \
    --exclude='.git' \
    --exclude-from="${lfs_exclude_file}" \
    "${REF_DIR}/" "${MODEL_DIR}/"
  echo "Small-file rsync dry-run completed. No output above means regular files match."
fi

rm -f "${lfs_exclude_file}"
