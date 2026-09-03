#!/bin/bash
# 生成/复用本地自签名代码签名证书（身份名：AgentMeter Dev）
# 关键点：
#   1) 证书导入后必须标记为「代码签名受信任」，否则 find-identity -p codesigning 不显示
#   2) 幂等：重复运行自动清理旧残留
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY="AgentMeter Dev"
WORKDIR="$ROOT/.cert"
mkdir -p "$WORKDIR"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ 证书已存在：$IDENTITY"
    rm -f "$WORKDIR/key.pem" "$WORKDIR/cert.pem"
    exit 0
fi

echo "▸ 清理旧残留…"
security delete-identity -c "$IDENTITY" >/dev/null 2>&1 || true
security delete-certificate -c "$IDENTITY" >/dev/null 2>&1 || true

echo "▸ 生成自签名代码签名证书（10 年有效期）…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$IDENTITY/O=AgentMeter" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$WORKDIR/key.pem" \
    -out "$WORKDIR/cert.pem" 2>/dev/null

echo "▸ 导入 p12（证书+私钥）…"
openssl pkcs12 -export \
    -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
    -out "$WORKDIR/cert.p12" -passout pass:agentmeter 2>/dev/null
security import "$WORKDIR/cert.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P agentmeter \
    -T /usr/bin/codesign

echo "▸ 标记证书为「代码签名受信任」…"
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    "$WORKDIR/cert.pem"

echo "▸ 验证身份…"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ 证书就绪：$IDENTITY"
    rm -f "$WORKDIR/key.pem" "$WORKDIR/cert.pem" "$WORKDIR/cert.p12"
else
    echo "✗ 未形成有效身份，当前钥匙串状态："
    security find-identity -v 2>/dev/null || true
    echo "（保留 $WORKDIR 供排查）"
    exit 1
fi
