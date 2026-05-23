#!/bin/bash

# --- 配置部分 ---
# gpu_burn 的启动命令
BURN_CMD="/gemini/space/tcj/gpu-burn-utl-control/gpu_burn -m 57% -u 93 -d 36000"
# 检测间隔 (秒)
INTERVAL=2

# 用于存储后台进程 PID 的变量
BURN_PID=""

# --- 退出清理函数 ---
# 当你按下 Ctrl+C 停止这个脚本时，确保把后台跑的 gpu_burn 也关掉
cleanup() {
    if [ -n "$BURN_PID" ]; then
        echo ""
        echo "正在停止脚本..."
        kill $BURN_PID 2>/dev/null
        echo "已停止后台 gpu_burn 进程。"
    fi
    exit 0
}
# 捕获 SIGINT (Ctrl+C) 和 SIGTERM 信号
trap cleanup SIGINT SIGTERM

echo "开始监控 GPU..."
echo "策略: 发现其他进程 -> 停止压测 | 无其他进程 -> 开始压测"

while true; do
    # 1. 获取当前所有计算进程的名称
    # 2. grep -v -i "gpu_burn": 排除掉包含 "gpu_burn" (忽略大小写) 的行
    # 3. sed '/^$/d': 去除空行
    other_procs=$(nvidia-smi --query-compute-apps=process_name --format=csv,noheader | grep -v -i "gpu_burn" | sed '/^$/d')

    if [ -n "$other_procs" ]; then
        # === 场景 A: 发现了 gpu_burn 以外的进程 ===
        
        # 获取当前时间用于日志
        now=$(date +"%H:%M:%S")
        echo "[$now] 检测到其他进程占用: $other_procs"

        # 如果我们要管理的 BURN_PID 正在运行，把它杀掉
        if [ -n "$BURN_PID" ]; then
            echo "   -> 停止正在运行的 gpu_burn (PID: $BURN_PID)..."
            kill $BURN_PID 2>/dev/null
            wait $BURN_PID 2>/dev/null # 等待进程完全退出
            BURN_PID=""
            echo "   -> gpu_burn 已停止。"
        fi

    else
        # === 场景 B: 没有发现其他进程 (或者是空的，或者是只有 gpu_burn) ===

        # 检查我们的 gpu_burn 是否正在运行
        # ps -p $PID > /dev/null 用于检查 PID 是否存在
        if [ -z "$BURN_PID" ] || ! ps -p $BURN_PID > /dev/null; then
            now=$(date +"%H:%M:%S")
            echo "[$now] GPU 空闲，启动 gpu_burn..."
            
            # 在后台运行 (&)，并将输出重定向到 /dev/null 防止刷屏 (根据需要去掉 > /dev/null)
            $BURN_CMD > /dev/null 2>&1 &
            
            # 获取刚刚启动的进程 PID
            BURN_PID=$!
            echo "   -> gpu_burn 已启动，PID: $BURN_PID"
        fi
    fi

    # 等待 2 秒
    sleep $INTERVAL
done