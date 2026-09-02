ARG BASE_IMAGE=quay.io/ascend/sglang:v0.5.16-cann9.0.0-a3
FROM ${BASE_IMAGE}

ARG MOONCAKE_VERSION=0.3.11.post1

# The upstream SGLang NPU image installs memfabric-hybrid, but v0.5.16's
# npu.Dockerfile does not install the Mooncake NPU wheel.
RUN python3 -m pip uninstall -y \
      mooncake-transfer-engine \
      mooncake-transfer-engine-cuda13 \
      mooncake-transfer-engine-npu >/dev/null 2>&1 || true \
    && python3 -m pip install --no-cache-dir \
      "mooncake-transfer-engine-npu==${MOONCAKE_VERSION}"

LABEL org.opencontainers.image.title="SGLang Ascend with Mooncake NPU transfer engine" \
      org.opencontainers.image.version="sglang-v0.5.16-mooncake-0.3.11.post1"
