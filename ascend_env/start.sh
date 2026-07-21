#!/usr/bin/env bash
# cpu performance and numa setup
echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
sysctl -w vm.swappiness=0
sysctl -w kernel.numa_balancing=0
sysctl -w kernel.sched_migration_cost_ns=50000


#proxy 
unset https_proxy
unset http_proxy
unset HTTPS_PROXY
unset HTTP_PROXY


#ascend env
ASCEND_TOOLKIT_ENV=${ASCEND_TOOLKIT_ENV:-/usr/local/Ascend/ascend-toolkit/set_env.sh}
source "${ASCEND_TOOLKIT_ENV}"
source /usr/local/Ascend/nnal/atb/set_env.sh

unset ASCEND_LAUNCH_BLOCKING


#sglang set
cd /home/tcj/sglang-ascend
export PYTHONPATH="${PWD}/python${PYTHONPATH:+:${PYTHONPATH}}"
export SGLANG_SET_CPU_AFFINITY=1

MODEL_PATH="${MODEL_PATH:-/home/tcj/DeepSeek-V3.2-Exp-w8a8}"
MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-1}"
CUDA_GRAPH_MODE="${CUDA_GRAPH_MODE:-eager}"
CUDA_GRAPH_BS="${CUDA_GRAPH_BS:-${MAX_RUNNING_REQUESTS}}"
export PATH="/usr/local/Ascend/8.5.0/compiler/bishengir/bin:${PATH}"

# 内存碎片
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export STREAMS_PER_DEVICE=32
export SGLANG_SCHEDULER_DECREASE_PREFILL_IDLE=1
export SGLANG_PREFILL_DELAYER_MAX_DELAY_PASSED=200

# 网卡
export HCCL_SOCKET_IFNAME=enp196s0f0
export GLOO_SOCKET_IFNAME=enp196s0f0

# 通信buffer
export SGLANG_DEEPEP_NUM_MAX_DISPATCH_TOKENS_PER_RANK=16
export HCCL_BUFFSIZE=800


export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export DEEP_NORMAL_MODE_USE_INT8_QUANT=1
export SGLANG_ENABLE_SPEC_V2=1
export SGLANG_ENABLE_OVERLAP_PLAN_STREAM=1

export SGLANG_NPU_PROFILING=1

export SGLANG_USE_FIA_NZ=1
export DISABLE_SGLANG_DEVICEPAGEKV=True
export SGLANG_ENABLE_STRICT_MEM_CHECK_DURING_IDLE=0

cmd=(
    python3 -m sglang.launch_server
    --model-path "${MODEL_PATH}"
    --tp 16
    --trust-remote-code
    --attention-backend ascend
    --device npu
    --quantization modelslim
    --watchdog-timeout 9000
    --host 127.0.0.1 --port 6699
    --mem-fraction-static 0.80
    --max-running-requests "${MAX_RUNNING_REQUESTS}"
    --context-length 40000
    --disable-radix-cache
    --chunked-prefill-size -1
    --enable-dp-attention --dp-size 1 --enable-dp-lm-head
    --reasoning-parser deepseek-v3
    --dtype bfloat16
)

case "${CUDA_GRAPH_MODE}" in
    eager)
        cmd+=(--disable-cuda-graph)
        ;;
    graph)
        cmd+=(--cuda-graph-bs "${CUDA_GRAPH_BS}")
        ;;
    *)
        echo "Unsupported CUDA_GRAPH_MODE=${CUDA_GRAPH_MODE}; expected eager or graph" >&2
        exit 2
        ;;
esac

printf 'Starting server with CUDA_GRAPH_MODE=%s MAX_RUNNING_REQUESTS=%s CUDA_GRAPH_BS=%s\n' \
    "${CUDA_GRAPH_MODE}" "${MAX_RUNNING_REQUESTS}" "${CUDA_GRAPH_BS}"
printf 'Running: '
printf '%q ' "${cmd[@]}"
printf '\n'

"${cmd[@]}"

# python3 -m sglang.launch_server --model-path ${MODEL_PATH} \
#     --tp 16 \
#     --trust-remote-code \
#     --attention-backend ascend \
#     --device npu \
#     --quantization modelslim \
#     --watchdog-timeout 9000 \
#     --host 127.0.0.1 --port 6699 \
#     --mem-fraction-static 0.80 \
#     --max-running-requests 32 \
#     --context-length 40000 \
#     --disable-radix-cache \
#     --chunked-prefill-size 8192 \
#     --enable-dp-attention --dp-size 1 --enable-dp-lm-head \
#     --cuda-graph-bs 32 \
#     --reasoning-parser deepseek-v3 \
#     --dtype bfloat16
