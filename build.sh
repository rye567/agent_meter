#!/bin/bash
# agent_meter — 一键构建 macOS 菜单栏用量监控 App
# 依赖：Xcode Command Line Tools（swiftc / codesign）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="agent_meter"
BUNDLE="AgentMeter.app"
BUILD_DIR=".build"

mkdir -p "$BUILD_DIR"

echo "▸ 编译 Swift 源码…"
SOURCES=$(find Sources -name '*.swift' | sort)
swiftc -swift-version 5 -O \
    -parse-as-library \
    -target arm64-apple-macos14.0 \
    -o "$BUILD_DIR/$APP_NAME" \
    $SOURCES

echo "▸ 组装 ${BUNDLE}…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/"
cp Resources/menubar.png Resources/menubar@2x.png "$BUNDLE/Contents/Resources/"
mkdir -p "$BUNDLE/Contents/Resources/ProviderIcons"
cp Resources/ProviderIcons/*.png "$BUNDLE/Contents/Resources/ProviderIcons/"

tools/sign.sh "$BUNDLE"

echo "✓ 构建完成：$(pwd)/$BUNDLE"
echo "  运行：open $BUNDLE"
