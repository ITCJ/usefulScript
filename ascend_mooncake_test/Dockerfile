ARG BASE_IMAGE=quay.io/ascend/sglang:v0.5.16-cann9.0.0-a3
FROM ${BASE_IMAGE}

ARG MOONCAKE_VERSION=0.3.11.post1
ARG APT_MIRROR=""
ARG APT_SECURITY_MIRROR=""
ARG APT_PORTS_MIRROR=""

# Mooncake's NPU wheel still links its common transfer-engine objects against
# libibverbs.so.1. Install the runtime loader dependencies even when SGLang
# selects Mooncake's ADXL-based "ascend" transport instead of generic RDMA.
RUN set -eu; \
    for source_file in \
      /etc/apt/sources.list \
      /etc/apt/sources.list.d/*.list \
      /etc/apt/sources.list.d/*.sources; do \
      [ -f "${source_file}" ] || continue; \
      if [ -n "${APT_MIRROR}" ]; then \
        archive_mirror=${APT_MIRROR%/}; \
        sed -E -i \
          "s#https?://archive\\.ubuntu\\.com/ubuntu/?#${archive_mirror}/#g" \
          "${source_file}"; \
      fi; \
      if [ -n "${APT_SECURITY_MIRROR}" ]; then \
        security_mirror=${APT_SECURITY_MIRROR%/}; \
        sed -E -i \
          "s#https?://security\\.ubuntu\\.com/ubuntu/?#${security_mirror}/#g" \
          "${source_file}"; \
      fi; \
      if [ -n "${APT_PORTS_MIRROR}" ]; then \
        ports_mirror=${APT_PORTS_MIRROR%/}; \
        sed -E -i \
          "s#https?://ports\\.ubuntu\\.com/ubuntu-ports/?#${ports_mirror}/#g" \
          "${source_file}"; \
      fi; \
    done; \
    echo 'Active APT sources:'; \
    grep -RhE '^(deb |URIs:)' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true; \
    apt-get update \
    && apt-get install -y --no-install-recommends \
      ibverbs-providers \
      libcurl4 \
      libibverbs1 \
      libnuma1 \
      rdma-core \
    && rm -rf /var/lib/apt/lists/*

# The upstream SGLang NPU image installs memfabric-hybrid, but v0.5.16's
# npu.Dockerfile does not install the Mooncake NPU wheel.
RUN python3 -m pip uninstall -y \
      mooncake-transfer-engine \
      mooncake-transfer-engine-cuda13 \
      mooncake-transfer-engine-npu >/dev/null 2>&1 || true \
    && python3 -m pip install --no-cache-dir \
      "mooncake-transfer-engine-npu==${MOONCAKE_VERSION}" \
    && ldconfig \
    && ldconfig -p | grep -F 'libibverbs.so.1'

LABEL org.opencontainers.image.title="SGLang Ascend with Mooncake NPU transfer engine" \
      org.opencontainers.image.version="sglang-v0.5.16-mooncake-0.3.11.post1"
