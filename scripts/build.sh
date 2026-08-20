#!/bin/bash
# 构建 DSH Web.app：编译 → 组装包结构 → 签名 → 安装到 ~/Applications
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Harness"
APP="dist/$NAME.app"
DEST="$HOME/Applications/$NAME.app"

echo "==> swift build (release)"
swift build -c release --product DSHWeb

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DSHWeb "$APP/Contents/MacOS/DSHWeb"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Harness</string>
	<key>CFBundleDisplayName</key>
	<string>Harness</string>
	<key>CFBundleIdentifier</key>
	<string>local.harness.app</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleExecutable</key>
	<string>DSHWeb</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
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

echo "==> codesign (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> installing to $DEST"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "==> done: $DEST"
