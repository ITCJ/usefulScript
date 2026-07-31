#!/usr/bin/env bash
IMAGE=quay.io/ascend/sglang:v0.5.16-cann9.0.0-a3

mkdir -p ./crane-cache

until crane pull \
  --platform linux/arm64 \
  --cache_path ./crane-cache \
  "$IMAGE" \
  sglang.tar
do
  echo "下载失败，10 秒后继续..."
  sleep 10
done