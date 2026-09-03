#!/bin/bash
# AgentMeter 分发打包：Universal .app → DMG 安装镜像
# 用法：./dist.sh   （产物：AgentMeter-<版本>.dmg）
set -euo pipefail
cd "$(dirname "$0")"

APP="AgentMeter.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
DMG="AgentMeter-$VERSION.dmg"
BUILD_DIR=".build_dist"
STAGING="$BUILD_DIR/dmg-staging"

rm -rf "$BUILD_DIR" "$APP" "$DMG"
mkdir -p "$BUILD_DIR"

echo "▸ 编译 Universal 二进制（arm64 + x86_64）…"
SOURCES=$(find Sources -name '*.swift' | sort)
mkdir -p "$BUILD_DIR/arm64" "$BUILD_DIR/x86_64"
swiftc -swift-version 5 -O -parse-as-library \
    -target arm64-apple-macos14.0 -o "$BUILD_DIR/arm64/agent_meter" $SOURCES
swiftc -swift-version 5 -O -parse-as-library \
    -target x86_64-apple-macos14.0 -o "$BUILD_DIR/x86_64/agent_meter" $SOURCES
lipo -create "$BUILD_DIR/arm64/agent_meter" "$BUILD_DIR/x86_64/agent_meter" \
    -output "$BUILD_DIR/agent_meter"
lipo -info "$BUILD_DIR/agent_meter"

echo "▸ 组装 ${APP}…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ProviderIcons"
cp "$BUILD_DIR/agent_meter" "$APP/Contents/MacOS/agent_meter"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/menubar.png Resources/menubar@2x.png "$APP/Contents/Resources/"
cp Resources/ProviderIcons/*.png "$APP/Contents/Resources/ProviderIcons/"

tools/sign.sh "$APP"

echo "▸ 安全门禁：扫描产物确保不含 API Key…"
python3 tools/check_no_secrets.py "$APP"

echo "▸ 组装 DMG 目录…"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
[ -f "安装说明.txt" ] && cp "安装说明.txt" "$STAGING/"

echo "▸ 生成 ${DMG}…"
hdiutil create -volname "AgentMeter $VERSION" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >/dev/null

echo "✓ 打包完成：$(pwd)/$DMG （Universal，含 arm64 + Intel）"
echo "  本机验证：open $DMG"
