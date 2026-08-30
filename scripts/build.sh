#!/bin/bash
# 构建 Harness.app：编译（默认 universal 双架构）→ 组装包结构 → 签名 → 安装
#
# 环境变量：
#   VERSION  版本号（默认 0.2.0；Release 构建时由 CI 从 tag 注入）
#   BUILD    构建号（默认 1；CI 传入 git 计数）
#   ARCHS    架构列表（默认 "arm64 x86_64"，单架构可传 ARCHS=arm64）
#   NO_INSTALL=1  跳过安装到 ~/Applications（CI 用）
#   BUNDLE_RUNTIME=1  把 pin 住的 node + dsh 备进 .app（只能单架构，见 vendor-runtime.sh）
#   CODESIGN_IDENTITY 签名身份（默认本地自签名；分发用 "Developer ID Application: …"）
#   NOTARIZE=1  签完后送 Apple 公证并装订票据（需要凭据，见 scripts/notarize.sh）
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Harness"
# 版本：优先 VERSION 环境变量；未指定时从 git 自动推导——
#   有 tag（vX.Y.Z）→ X.Y.Z；无 tag → 0.0.0-<git提交计数>
# BUILD 同理：优先环境变量，否则用 git 提交计数。
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
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
	<string>com.chrisli.dsh-desktop</string>
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

# ---------- 捆绑运行时 ----------
# 默认不备：日常 swift build / 本地迭代不需要多等一次 400 MB 的拷贝，`RuntimeLocator`
# 找不到 runtime/ 时自动退回本机 node + npx 缓存。发布构建才开。
if [ "${BUNDLE_RUNTIME:-}" = "1" ]; then
  ARCH_LIST=($ARCHS)
  if [ "${#ARCH_LIST[@]}" -gt 1 ]; then
    echo "!! BUNDLE_RUNTIME=1 只能配单架构，当前 ARCHS=\"$ARCHS\"" >&2
    echo "   dsh 树里的原生模块是按架构装的，universal 包装不进两份互斥的 node_modules。" >&2
    echo "   发布按架构分开出包（见 .github/workflows/release.yml）。" >&2
    exit 1
  fi
  echo "==> vendoring runtime (${ARCH_LIST[0]})"
  ./scripts/vendor-runtime.sh "${ARCH_LIST[0]}" "$APP/Contents/Resources"
fi

# ---------- 签名 ----------
# 默认用稳定的自签名证书，保证 TCC 授权持久（ad-hoc 每次构建签名都变，
# 导致文件夹权限每次重新请求）。分发时传 Developer ID 身份。
IDENTITY="${CODESIGN_IDENTITY:-Harness Local Signing}"
if [ "$IDENTITY" != "-" ] && ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  echo "==> 钥匙串里没有「${IDENTITY}」，退回 ad-hoc 签名（仅本机可用，不能分发）"
  IDENTITY="-"
fi

# 安全时间戳要联网（Apple 的时间戳服务），且只对可分发签名有意义。本地签名一律关掉，
# 免得离线构建卡在网络超时上。
case "$IDENTITY" in
  "Developer ID"*) TIMESTAMP=(--timestamp) ;;
  *)               TIMESTAMP=(--timestamp=none) ;;
esac

# 加固运行时（--options runtime）是公证的前置条件，本地签名时一起开着，
# 免得「本地能跑、公证版起不来」这种只在发布后才暴露的差异。
sign() { # sign <entitlements|""> <path…>
  local entitlements="$1"; shift
  if [ -n "$entitlements" ]; then
    codesign --force --sign "$IDENTITY" --options runtime "${TIMESTAMP[@]}" \
      --entitlements "$entitlements" "$@"
  else
    codesign --force --sign "$IDENTITY" --options runtime "${TIMESTAMP[@]}" "$@"
  fi
}

# 由内向外签：嵌套的 Mach-O 必须先各自签好，外层再封装。`--deep` 做的是同一件事，
# 但它给所有嵌套代码套上同一份 entitlements，node 需要的 JIT 豁免会漏给应用本体，
# 而且 Apple 已经明确不建议用它签名。
RUNTIME_DIR="$APP/Contents/Resources/runtime"
if [ -d "$RUNTIME_DIR" ]; then
  echo "==> codesign 捆绑运行时里的 Mach-O"
  SIGNED=0
  # 候选：原生模块与带可执行位的文件。node_modules 里大量带可执行位的其实是 JS/shell
  # 脚本，codesign 会直接报错，所以逐个用 file 判一次是不是 Mach-O。
  while IFS= read -r -d '' candidate; do
    case "$(/usr/bin/file -b "$candidate")" in
      Mach-O*)
        sign assets/runtime.entitlements "$candidate"
        SIGNED=$((SIGNED + 1))
        ;;
    esac
  done < <(find "$RUNTIME_DIR" -type f \
             \( -name '*.node' -o -name '*.dylib' -o -name '*.so' -o -perm -u+x \) -print0)
  echo "   - 已签名 $SIGNED 个 Mach-O"
fi

echo "==> codesign $APP ($IDENTITY)"
sign "" "$APP"

echo "==> 校验签名"
codesign --verify --deep --strict --verbose=1 "$APP"

# ---------- 公证 ----------
# 显式开关而不是"有 Developer ID 就自动公证"：公证要联网、要几分钟，本地用
# 发布身份签一次只为验证签名链的场合不该被它拖住。装订在安装之前，
# 这样 ~/Applications 里那份也带票据。
if [ "${NOTARIZE:-}" = "1" ]; then
  ./scripts/notarize.sh "$APP"
fi

if [ "${NO_INSTALL:-}" != "1" ]; then
  DEST="$HOME/Applications/$NAME.app"
  echo "==> installing to $DEST"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "==> done: $DEST"
else
  echo "==> done (no install): $APP"
fi
