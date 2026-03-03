#!/bin/bash
# OpenClaw 截图工具
# 用法:
#   screenshot.sh                    → 截全屏，保存到 /screenshots/latest.png
#   screenshot.sh /path/to/file.png  → 截全屏，保存到指定路径
#   screenshot.sh --base64            → 截全屏，输出 base64 编码（方便 API 传输）

set -e

export DISPLAY=:1
OUTPUT="${1:-/screenshots/latest.png}"

if [ "$1" = "--base64" ]; then
    scrot -o /tmp/_screenshot.png
    base64 -w 0 /tmp/_screenshot.png
    rm -f /tmp/_screenshot.png
else
    mkdir -p "$(dirname "$OUTPUT")"
    scrot -o "$OUTPUT"
    echo "$OUTPUT"
fi
