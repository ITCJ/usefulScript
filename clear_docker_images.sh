#!/bin/bash

# 检查是否为 Dry Run 模式
DRY_RUN=false
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
fi

echo "========================================================"
echo "🔍 正在扫描: [无容器引用] 且 [创建超过2个月] 的镜像..."
echo "========================================================"

# --- 1. 计算 2个月前 的时间戳 ---
TWO_MONTHS_AGO_TIMESTAMP=$(date -d "2 months ago" +%s)
echo "📅 删除截止时间点: $(date -d @$TWO_MONTHS_AGO_TIMESTAMP "+%Y-%m-%d %H:%M:%S")"
echo "--------------------------------------------------------"

IMAGES_TO_DELETE_IDS=()
IMAGES_TO_DELETE_INFOS=()

# --- 2. 遍历所有镜像 ---
while IFS='#' read -r IMAGE_ID REPO TAG SIZE CREATED_AT_RAW; do
    CLEAN_TIME="${CREATED_AT_RAW%% +*}"
    IMAGE_TIMESTAMP=$(date -d "$CLEAN_TIME" +%s 2>/dev/null)
    
    if [ -z "$IMAGE_TIMESTAMP" ]; then
        IMAGE_TIMESTAMP=$(date -d "$CREATED_AT_RAW" +%s 2>/dev/null)
    fi

    if [ -z "$IMAGE_TIMESTAMP" ]; then
        continue
    fi

    # --- 4. 检查条件 ---
    if [ "$IMAGE_TIMESTAMP" -lt "$TWO_MONTHS_AGO_TIMESTAMP" ]; then
        CONTAINER_COUNT=$(docker ps -a -q --filter ancestor="$IMAGE_ID" | wc -l)
        if [ "$CONTAINER_COUNT" -eq 0 ]; then
            IMAGES_TO_DELETE_IDS+=("$IMAGE_ID")
            IMAGES_TO_DELETE_INFOS+=("ID: $IMAGE_ID | $REPO:$TAG | 大小: $SIZE | 创建于: $CLEAN_TIME")
        fi
    fi
done < <(docker images --format "{{.ID}}#{{.Repository}}#{{.Tag}}#{{.Size}}#{{.CreatedAt}}")

# --- 6. 检查结果 ---
if [ ${#IMAGES_TO_DELETE_IDS[@]} -eq 0 ]; then
    echo "✅ 未发现符合条件的镜像。"
    exit 0
fi

# --- 7. 打印列表 ---
echo -e "\n📋 以下镜像将被清理 (无容器引用 且 >2个月)："
echo "--------------------------------------------------------"
for info in "${IMAGES_TO_DELETE_INFOS[@]}"; do
    echo "$info"
done
echo "--------------------------------------------------------"
echo "共计: ${#IMAGES_TO_DELETE_IDS[@]} 个镜像"

# --- 8. 执行删除逻辑 (仅在非 Dry Run 模式下) ---
if [ "$DRY_RUN" = true ]; then
    echo -e "\n💡 [Dry Run 模式] 扫描完成，未进行任何删除。"
    exit 0
fi

echo ""
read -r -p "❓ 确定要删除以上这些镜像吗? [y/N] " response

case "$response" in
    [yY][eE][sS]|[yY])
        echo -e "\n🗑️  开始删除..."
        # ... (此处省略原有删除循环代码，保持不变) ...
        for ID in "${IMAGES_TO_DELETE_IDS[@]}"; do
            echo -n "正在删除 $ID ... "
            OUTPUT=$(docker rmi "$ID" 2>&1)
            if [ $? -eq 0 ]; then echo "✅ 成功"; else echo "❌ 失败: $OUTPUT"; fi
        done
        echo "--------------------------------------------------------"
        docker system df
        ;;
    *)
        echo "❌ 操作已取消。"
        ;;
esac