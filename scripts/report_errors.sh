#!/usr/bin/env bash
# 从构建日志里提取可定位的错误
set -uo pipefail
LOG=/tmp/build.log

echo "===== 编译 error 行 ====="
grep -nE "error:|fatal error|Undefined symbol|ld: " "$LOG" | head -40 || echo "无 error"

echo ""
echo "===== 末尾 80 行 ====="
tail -80 "$LOG"
