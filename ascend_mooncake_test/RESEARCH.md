# SGLang Ascend + Mooncake deployment research

Research date: 2026-09-02

Target stack:

- SGLang `v0.5.16`
- CANN `9.0.0`
- Atlas 800I A3 image `quay.io/ascend/sglang:v0.5.16-cann9.0.0-a3`
- Mooncake Transfer Engine `0.3.11.post1`

## Conclusion

The requested deployment is technically implementable through SGLang's
Mooncake PD transfer backend plus Mooncake's Ascend Direct transport:

```text
--disaggregation-transfer-backend mooncake
ENABLE_ASCEND_TRANSFER_WITH_MOONCAKE=true
mooncake-transfer-engine-npu==0.3.11.post1
```

However, it has to be acceptance-tested on the target A3 cluster. The v0.5.16
tag contains conflicting signals:

1. `docs_new/docs/advanced_features/pd_disaggregation.mdx` explicitly documents
   `ENABLE_ASCEND_TRANSFER_WITH_MOONCAKE=true` for Ascend.
2. `python/sglang/srt/distributed/device_communicators/mooncake_transfer_engine.py`
   implements this switch and initializes Mooncake with protocol `ascend`.
3. `docs_new/docs/hardware-platforms/ascend-npus/ascend_npu_support_features.mdx`
   says the NPU-supported PD transfer backend is `ascend`, and that the default
   `mooncake` backend is not supported on NPU.

Therefore this package treats Ascend+Mooncake as a source-implemented but not
support-matrix-certified path. Do not skip the provided preflight, worker health,
end-to-end request, and sustained-load tests.

## Two different backends named around Ascend

| SGLang CLI backend | Python implementation | Runtime dependency | Metadata/control service |
| --- | --- | --- | --- |
| `mooncake` + Ascend switch | `MooncakeTransferEngine` | `mooncake-transfer-engine-npu` | Mooncake `P2PHANDSHAKE`; no master |
| `ascend` | `AscendTransferEngine` derived from Mooncake interfaces | `memfabric-hybrid` | `ASCEND_MF_STORE_URL` service |

This deployment uses the first row. Replacing the CLI backend with `ascend`
changes the transfer implementation to memfabric and is not an equivalent
Mooncake configuration.

## Image dependency analysis

In tag v0.5.16:

- `docker/npu.Dockerfile` installs `memfabric-hybrid==1.0.8` and
  `sglang-router`, but does not install a Mooncake wheel.
- The generic SGLang Dockerfile pins `MOONCAKE_VERSION=0.3.11.post1`.
- Mooncake publishes `mooncake-transfer-engine-npu==0.3.11.post1` wheels for
  Python 3.11 and both x86_64/aarch64, matching the base image's Python 3.11
  packaging model.
- Mooncake's NPU release build enables `USE_ASCEND_DIRECT=ON`, which installs
  the `ascend` transport used by the SGLang switch.

The supplied derived Dockerfile only adds that NPU wheel; it preserves the base
image's SGLang, PyTorch, torch_npu, CANN, Triton-Ascend, and custom kernels.

## PD request and KV path

```text
OpenAI/native request
        |
        v
SGLang Router (:8000)
        |
        +----> Prefill server (:30000)
        |          |
        |          +-- bootstrap metadata (:8998)
        |          +-- register KV buffers in Mooncake TE
        |
        +----> Decode server (:30001)
                   |
                   +-- receive KV through Mooncake Ascend Direct
                   +-- generate remaining tokens
```

Mooncake PD transfer does not write KV data into Mooncake Store. Enabling
HiCache with `--hicache-storage-backend mooncake` is a separate L3 cache design
with its own memory sizing, metadata server, and master service.

## Network behavior

SGLang v0.5.16 builds each Ascend Mooncake endpoint as:

```text
<SGLANG_HOST_IP>:<dynamically-selected-free-port>:npu_<physical-id>
```

Mooncake metadata mode is `P2PHANDSHAKE`. Ascend Direct also chooses a port in a
per-physical-device 100-port window based on `ASCEND_BASE_PORT`. Consequently,
split-node deployments must allow:

- Prefill/decode HTTP and prefill bootstrap ports.
- The configured Ascend Direct per-device ranges.
- The host ephemeral TCP range used by SGLang's dynamically selected Mooncake
  RPC ports.

Host networking is used so endpoint addresses embedded in bootstrap metadata
are reachable without Docker port translation.

Mooncake Ascend Direct requires `/etc/hccn.conf` inside every worker container
to resolve the local NPU network information. The deployment mounts this file
read-only and `preflight.sh` queries `hccn_tool` when it is available. The ADXL
`ascend` transport does not use Mooncake's generic mlx5 `/dev/infiniband` path;
those device and sysfs mounts belong to the separate generic `rdma` transport.

## NPU ID rules

The SGLang switch accepts one optional `ASCEND_NPU_PHY_ID`, but one fixed value
cannot represent multiple TP ranks. Leaving it at `-1` makes each Mooncake
engine use the rank's `gpu_id` suffix.

For that reason:

- Single server: Prefill uses base ID 0 and Decode uses base ID 16 by default;
  this requires 32 physical NPU devices.
- Split servers: both roles use base ID 0 on their respective hosts.
- Avoid `ASCEND_RT_VISIBLE_DEVICES` remapping during initial acceptance because
  it can make logical IDs diverge from endpoint physical IDs.

## Acceptance gates

1. `preflight.sh` imports SGLang, torch_npu, and Mooncake NPU wheel in the
   derived image.
2. Both workers become healthy after model loading.
3. Logs show Mooncake Transfer Engine and Ascend transport initialization.
4. A request through the router completes and returns generated text.
5. Repeated long-prompt traffic completes without bootstrap/waiting timeout.
6. NPU memory on Prefill and Decode roles matches the intended placement.
7. Cross-node test shows no firewall drops in ephemeral or Ascend Direct ranges.

Suggested load test after the smoke test:

```bash
python3 -m sglang.bench_serving \
  --backend sglang \
  --base-url http://127.0.0.1:8000 \
  --dataset-name random \
  --random-input-len 4096 \
  --random-output-len 256 \
  --num-prompts 100 \
  --request-rate 2
```

Tune concurrency only after this baseline passes. Model-specific MoE,
quantization, DP attention, graph mode, and speculative decoding flags are
deliberately excluded from the baseline scripts.

## Fallback

If the target image/wheel/driver combination cannot initialize Mooncake Ascend
Direct, the officially documented Ascend feature-matrix path is SGLang backend
`ascend`, using the image's `memfabric-hybrid` dependency and a valid
`ASCEND_MF_STORE_URL`. That is a backend change, not a one-line Mooncake repair,
and should be deployed as a separately validated configuration.

## Primary sources

- SGLang v0.5.16 PD documentation:
  https://github.com/sgl-project/sglang/blob/v0.5.16/docs_new/docs/advanced_features/pd_disaggregation.mdx
- SGLang v0.5.16 Ascend feature matrix:
  https://github.com/sgl-project/sglang/blob/v0.5.16/docs_new/docs/hardware-platforms/ascend-npus/ascend_npu_support_features.mdx
- SGLang v0.5.16 Mooncake Transfer Engine integration:
  https://github.com/sgl-project/sglang/blob/v0.5.16/python/sglang/srt/distributed/device_communicators/mooncake_transfer_engine.py
- SGLang v0.5.16 NPU Dockerfile:
  https://github.com/sgl-project/sglang/blob/v0.5.16/docker/npu.Dockerfile
- Mooncake build guide and NPU package:
  https://kvcache-ai.github.io/Mooncake/getting_started/build.html
  https://pypi.org/project/mooncake-transfer-engine-npu/0.3.11.post1/
- Mooncake Ascend Direct design:
  https://github.com/kvcache-ai/Mooncake/blob/v0.3.11.post1/docs/source/design/transfer-engine/ascend_direct_transport.md
