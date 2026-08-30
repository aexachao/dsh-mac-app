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
trap 'rm -rf "$STAGE"' EXIT

# ditto 而不是 cp -R：要保留符号链接、扩展属性与签名结构。内置运行时里全是链接，
# cp 展开链接会让签名失效，dmg 里的应用当场打不开。
echo "==> 准备 dmg 内容：${STAGE}"
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

echo "==> 生成 ${OUT}（卷名 ${VOLNAME}）"
rm -f "$OUT"
# HFS+ 而不是 APFS：APFS 格式的 dmg 在旧系统上挂不上，而 dmg 的意义就是谁都能打开。
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet "$OUT"

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
