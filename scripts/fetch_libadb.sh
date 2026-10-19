#!/usr/bin/env bash
# 从 JK-GL/libadb-ios 的 Actions artifact 中取回 libadb-full.a 与头文件
# 用法: GH_TOKEN=xxx ./scripts/fetch_libadb.sh
set -euo pipefail

REPO="JK-GL/libadb-ios"
ARTIFACT="libadb-ios-arm64"
DEST_LIB="Vendor/lib"
DEST_INC="Vendor/include"

mkdir -p "$DEST_LIB" "$DEST_INC"

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "::error::缺少 GH_TOKEN，无法访问 artifact（私有/过期产物需要认证）"
  exit 1
fi

echo "==> 查询 artifact 列表"
ARTIFACT_ID=$(curl -sL \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/actions/artifacts?per_page=30" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('artifacts', []):
    if a.get('name') == '${ARTIFACT}' and not a.get('expired'):
        print(a['id'])
        break
")

if [[ -z "${ARTIFACT_ID}" ]]; then
  echo "::error::找不到有效的 ${ARTIFACT} 产物"
  exit 1
fi
echo "    artifact id = ${ARTIFACT_ID}"

echo "==> 下载"
# 注意：请求 artifact zip 会 302 到 Azure Blob，
# 重定向后的 URL 自带签名，不能带 Authorization 头，否则 403。
curl -sL \
  -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/repos/${REPO}/actions/artifacts/${ARTIFACT_ID}/zip" \
  -o /tmp/libadb.zip

echo "==> 解包"
rm -rf /tmp/libadb && mkdir -p /tmp/libadb
unzip -q -o /tmp/libadb.zip -d /tmp/libadb

echo "==> 校验产物"
if [[ ! -f /tmp/libadb/libadb-full.a ]]; then
  echo "::error::压缩包内没有 libadb-full.a"
  ls -laR /tmp/libadb
  exit 1
fi

cp -v /tmp/libadb/libadb-full.a "$DEST_LIB/"
if [[ -d /tmp/libadb/include ]]; then
  cp -Rv /tmp/libadb/include/. "$DEST_INC/"
fi

echo "==> 完成"
ls -la "$DEST_LIB"
find "$DEST_INC" -type f | head -20
