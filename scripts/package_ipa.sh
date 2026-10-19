#!/usr/bin/env bash
# 把 .app 打成未签名 IPA
#
# 未签名 IPA 两条路都能用：
#   - TrollStore 直接安装（免签）
#   - AltStore / Sideloadly 用个人证书重签
set -euo pipefail

APP_NAME="${APP_NAME:-LingFan}"
PRODUCTS="build/Build/Products/Debug-iphoneos"

echo "==> 查找 .app"
APP=$(find "$PRODUCTS" -maxdepth 1 -name "*.app" -type d | head -1)
if [[ -z "${APP}" ]]; then
  echo "::error::未找到 .app 产物，目录内容："
  ls -la "$PRODUCTS" || true
  exit 1
fi
echo "    $APP"

echo "==> 校验二进制架构"
BIN_NAME=$(basename "$APP" .app)
BIN_PATH="$APP/$BIN_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "::error::可执行文件不存在: $BIN_PATH"
  ls -la "$APP"
  exit 1
fi
lipo -info "$BIN_PATH" || true

echo "==> 校验 libadb 符号是否真的链进来"
if nm -gU "$BIN_PATH" 2>/dev/null | grep -q adb_commandline_porting; then
  echo "    adb_commandline_porting ✅ 已链接"
else
  echo "::warning::未在可执行文件中找到 adb_commandline_porting，可能被静态库剥离"
  nm -gU "$BIN_PATH" 2>/dev/null | grep -i adb | head -10 || true
fi

echo "==> 打包 Payload"
rm -rf Payload "$APP_NAME-unsigned.ipa"
mkdir -p Payload
cp -R "$APP" Payload/

zip -qry "$APP_NAME-unsigned.ipa" Payload

echo "==> 完成"
ls -lh "$APP_NAME-unsigned.ipa"
echo ""
echo "Payload 内容:"
ls -la Payload/*.app | head -20
