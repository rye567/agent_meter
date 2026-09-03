#!/bin/bash
# 为 .app 选择可用的签名身份：
# 优先 "AgentMeter Dev"（tools/make_cert.sh 创建的自签名证书），
# 其次任何可用的 codesigning 身份，都没有则 ad-hoc（更新时会重新弹钥匙串授权）。
APP="${1:?用法: sign.sh <App路径>}"

NAME=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "AgentMeter Dev"; then
    NAME="AgentMeter Dev"
else
    NAME=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/^[[:space:]]*[0-9][0-9]*) [A-F0-9]* "\(.*\)"$/\1/p' | head -1)
fi

if [ -n "$NAME" ]; then
    echo "▸ 签名身份：$NAME（稳定身份，钥匙串授权跨版本持久）"
    codesign --force --deep --sign "$NAME" "$APP"
else
    echo "▸ 签名身份：ad-hoc（提示：运行 tools/make_cert.sh 创建稳定身份，避免每次更新弹钥匙串授权）"
    codesign --force --deep --sign - "$APP"
fi
