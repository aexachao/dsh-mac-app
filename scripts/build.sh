#!/bin/bash
# 构建 Harness.app：编译（默认 universal 双架构）→ 组装包结构 → 签名 → 安装
#
# 环境变量：
#   VERSION  版本号（默认 0.2.0；Release 构建时由 CI 从 tag 注入）
#   BUILD    构建号（默认 1；CI 传入 git 计数）
#   ARCHS    架构列表（默认 "arm64 x86_64"，单架构可传 ARCHS=arm64）
#   NO_INSTALL=1  跳过安装到 ~/Applications（CI 用）
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Harness"
VERSION="${VERSION:-0.2.0}"
BUILD="${BUILD:-1}"
ARCHS="${ARCHS:-arm64 x86_64}"
APP="dist/$NAME.app"

echo "==> swift build (release, archs: $ARCHS)"
BINS=()
for arch in $ARCHS; do
  echo "   - building $arch (scratch: .build-$arch)"
  swift build -c release --product DSHWeb --scratch-path ".build-$arch" --arch "$arch"
  BINS+=(.build-$arch/release/DSHWeb)
done

echo "==> merging architectures"
if [ "${#BINS[@]}" -gt 1 ]; then
  mkdir -p .build/release
  lipo -create "${BINS[@]}" -output .build/release/DSHWeb-universal
  BIN=".build/release/DSHWeb-universal"
else
  BIN="${BINS[0]}"
fi
lipo -info "$BIN"

echo "==> assembling $APP (v$VERSION build $BUILD)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DSHWeb"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$NAME</string>
	<key>CFBundleIdentifier</key>
	<string>local.harness.app</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleExecutable</key>
	<string>DSHWeb</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
</dict>
</plist>
PLIST

# 签名：优先用稳定自签名证书（CODESIGN_IDENTITY），保证 TCC 授权持久
#（ad-hoc 每次构建签名变化，导致文件夹权限每次重新请求）
IDENTITY="${CODESIGN_IDENTITY:-Harness Local Signing}"
echo "==> codesign ($IDENTITY)"
codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null \
  || codesign --force --deep --sign - "$APP"

if [ "${NO_INSTALL:-}" != "1" ]; then
  DEST="$HOME/Applications/$NAME.app"
  echo "==> installing to $DEST"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "==> done: $DEST"
else
  echo "==> done (no install): $APP"
fi
