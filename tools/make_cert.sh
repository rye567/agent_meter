#!/bin/bash
# 生成/复用本地自签名代码签名证书（身份名：AgentMeter Dev）
# 作用：签名身份跨构建稳定 → 钥匙串"始终允许"授权跨版本持久，不再每次更新弹密码框
# 幂等：已存在则跳过
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY="AgentMeter Dev"
WORKDIR="$ROOT/.cert"
mkdir -p "$WORKDIR"

# 已存在同身份的 codesigning 私钥身份则直接复用
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ 证书已存在：$IDENTITY"
    rm -f "$WORKDIR/key.pem" "$WORKDIR/cert.pem"
    exit 0
fi

# 清理上次可能残留的半套证书
security delete-certificate -c "$IDENTITY" >/dev/null 2>&1 || true

echo "▸ 生成自签名代码签名证书（10 年有效期）…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$IDENTITY/O=AgentMeter" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$WORKDIR/key.pem" \
    -out "$WORKDIR/cert.pem" 2>/dev/null

# 分别导入私钥与证书（p12 整包导入在新版 OpenSSL 与钥匙串间存在兼容问题）
security import "$WORKDIR/key.pem" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -T /usr/bin/codesign >/dev/null
security import "$WORKDIR/cert.pem" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -T /usr/bin/codesign >/dev/null

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ 证书已创建并导入：$IDENTITY"
else
    echo "✗ 证书导入失败（未形成有效身份），保留 $WORKDIR 供排查"
    exit 1
fi

rm -f "$WORKDIR/key.pem" "$WORKDIR/cert.pem"
