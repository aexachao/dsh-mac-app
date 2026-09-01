#!/bin/bash
# 把已签名（并已装订票据）的 .app 打成 dmg，需要时再对 dmg 本身签名、公证、装订。
#
# 用法：
#   ./scripts/make-dmg.sh dist/Harness.app dist/Harness-0.3.5-macos-apple-silicon.dmg
#
# 环境变量：
#   CODESIGN_IDENTITY  给 dmg 签名的身份；为空则不签（zip 时代的 ad-hoc 等价物）
#   NOTARIZE=1         对 dmg 走一遍公证 + 装订（凭据要求见 notarize.sh）
#   VOLNAME            挂载后的卷名，默认 Harness
#
# 为什么 dmg 里放一个指向 /Applications 的符号链接：解压即运行会触发 macOS 的
# App Translocation——应用被搬到 /var/folders 下的只读临时挂载点执行，路径每次都变。
# dmg 里摆上「Applications」让用户先拖过去，这一类问题从源头消失。
#
# 刻意不用 AppleScript 摆图标位置/背景图：那需要 Finder 自动化授权，在 CI runner 上
# 要么失败要么挂住。朴素的 UDZO dmg 一样能看到「App + Applications」两个图标。
#
# 卷图标（挂载后 Finder 里显示的那个磁盘）用我们自己的图标：`.VolumeIcon.icns` 加上
# 卷根目录的 kHasCustomIcon 标志位。注意 dmg **文件本身**的图标改不了——文件级自定义
# 图标存在资源分支/扩展属性里，HTTP 下载只搬字节，那份元数据到不了用户机器上，所以
# 下载下来的 .dmg 一定是系统的通用磁盘映像图标；能带过去的品牌化只有卷这一层。
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:?用法: make-dmg.sh <path/to/App.app> <out.dmg>}"
OUT="${2:?用法: make-dmg.sh <path/to/App.app> <out.dmg>}"
VOLNAME="${VOLNAME:-Harness}"

if [ ! -d "$APP" ]; then
  echo "!! 找不到 ${APP}，先跑 ./scripts/build.sh" >&2
  exit 1
fi

STAGE="$(mktemp -d -t harness-dmg)"
RW="$(mktemp -u -t harness-dmg-rw).dmg"
MOUNT="$(mktemp -d -t harness-dmg-mnt)"
# 挂载中途失败也要卸掉：没卸的临时卷会一直占着 /Volumes，下一次构建的卷名会被加后缀。
cleanup() {
  hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true
  rm -rf "$STAGE" "$MOUNT" "$RW"
}
trap cleanup EXIT

# ditto 而不是 cp -R：要保留符号链接、扩展属性与签名结构。内置运行时里全是链接，
# cp 展开链接会让签名失效，dmg 里的应用当场打不开。
echo "==> 准备 dmg 内容：${STAGE}"
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"
cp assets/AppIcon.icns "$STAGE/.VolumeIcon.icns"

# 先出可写映像，改完卷属性再压成 UDZO：自定义图标标志位在卷根目录上，而卷根目录只有
# 挂载之后才存在——`hdiutil create` 阶段无处可写。
echo "==> 生成 ${OUT}（卷名 ${VOLNAME}）"
rm -f "$OUT"
# HFS+ 而不是 APFS：APFS 格式的 dmg 在旧系统上挂不上，而 dmg 的意义就是谁都能打开。
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -quiet "$RW"
hdiutil attach "$RW" -mountpoint "$MOUNT" -nobrowse -quiet

# 32 字节 FinderInfo，第 9 个字节起的 0x0400 就是 kHasCustomIcon：置上它，Finder 才会
# 去读 `.VolumeIcon.icns`。用 xattr 而不是 SetFile —— SetFile 来自 Xcode 命令行工具，
# 不是系统自带，而 xattr 一定在。
xattr -wx com.apple.FinderInfo \
  "0000000000000000 0400 00000000000000000000000000000000000000000000" "$MOUNT"
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$RW" -format UDZO -quiet -o "$OUT"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  # --timestamp 只给 Developer ID 身份：安全时间戳要联网，本地自签名身份会一直挂着。
  # 与 build.sh 中同一条判断保持一致。
  TIMESTAMP=(--timestamp=none)
  case "$CODESIGN_IDENTITY" in
    "Developer ID"*) TIMESTAMP=(--timestamp) ;;
  esac
  echo "==> 给 dmg 签名：${CODESIGN_IDENTITY}"
  codesign --force --sign "$CODESIGN_IDENTITY" "${TIMESTAMP[@]}" "$OUT"
else
  echo "::warning::没有 CODESIGN_IDENTITY，dmg 不签名" >&2
fi

if [ "${NOTARIZE:-}" = "1" ]; then
  # dmg 里的 .app 已经装订过票据；再公证 dmg 本身，用户下载的容器就不带隔离警告。
  ./scripts/notarize.sh "$OUT"
fi

echo "==> dmg 完成：${OUT}（$(du -h "$OUT" | cut -f1)）"
