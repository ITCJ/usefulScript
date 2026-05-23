#!/bin/bash

# 检查是否为 Dry Run 模式
DRY_RUN=false
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
fi

echo "--- 📊 容器大小排行（从大到小） ---"
sudo docker ps -a -s --format '{{.ID}}\t{{.Names}}\t{{.Size}}' | sort -h -r -k3
echo ""

echo "--- 📋 状态包含 '2 months ago' 或 '3 months ago' 的已停止容器：---"

# 1. 筛选并显示 ID、状态、镜像和名称
# 使用 column 命令让输出更整齐（如果系统没安装 column 会自动降级显示）
CONTAINERS_TO_REMOVE_INFO=$(docker ps -a --format "{{.ID}}\t{{.Status}}\t{{.Image}}\t{{.Names}}" | grep -E "2 months ago|3 months ago")

# 检查是否找到容器
if [ -z "$CONTAINERS_TO_REMOVE_INFO" ]; then
    echo "✅ 未找到状态包含 '2 months ago' 或 '3 months ago' 的容器。"
    exit 0
fi

echo -e "ID\t\tSTATUS\t\t\tIMAGE\t\tNAME"
echo "--------------------------------------------------------------------------------"
echo "$CONTAINERS_TO_REMOVE_INFO" | column -t -s $'\t' 2>/dev/null || echo -e "$CONTAINERS_TO_REMOVE_INFO"
echo "--------------------------------------------------------------------------------"

# 2. 提取容器 ID 准备删除
CONTAINER_IDS_TO_REMOVE=$(echo "$CONTAINERS_TO_REMOVE_INFO" | awk '{print $1}')
COUNT=$(echo "$CONTAINER_IDS_TO_REMOVE" | wc -l)

echo "共计: $COUNT 个容器"

# --- 3. 执行删除逻辑 (仅在非 Dry Run 模式下) ---
if [ "$DRY_RUN" = true ]; then
    echo -e "\n💡 [Dry Run 模式] 扫描完成，未进行任何删除。"
    exit 0
fi

echo ""
read -r -p "❓ 确定要删除以上这些容器吗? [y/N] " response
case "$response" in
    [yY][eE][sS]|[yY])
        echo "--- 🗑️ 正在删除容器 ---"
        # 执行删除命令
        docker rm $CONTAINER_IDS_TO_REMOVE
        echo "✅ 容器删除完成。"
        ;;
    *)
        echo "❌ 操作已取消。"
        ;;
esac
