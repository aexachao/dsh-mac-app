#!/bin/bash
# 公证并装订：预检签名 → 提交 Apple 公证 → 装订票据 → 校验。
#
# 用法：
#   ./scripts/notarize.sh dist/Harness.app                  # 应用本体
#   ./scripts/notarize.sh dist/Harness-0.3.5-….dmg          # 分发用的 dmg
#
# 两种目标走同一条凭据与提交逻辑，区别只在：.app 要先打成 zip 才能提交（notarytool
# 不吃目录）且预检项更多（加固运行时、时间戳）；.dmg 直接提交，预检只看签名权威。
#
# 凭据（二选一，都从环境变量读，脚本不落盘、不回显）：
#   A. App Store Connect API 密钥（CI 首选，可撤销、不绑账号密码）
#        AC_API_KEY_ID     密钥 ID
#        AC_API_ISSUER_ID  Issuer ID
#        AC_API_KEY_P8     .p8 内容的 base64（CI），或 AC_API_KEY_PATH 指向 .p8 文件（本地）
#   B. 专用密码（本地手动最省事）
#        AC_APPLE_ID       Apple ID 邮箱
#        AC_PASSWORD       App 专用密码（appleid.apple.com 生成，不是账号密码）
#        AC_TEAM_ID        团队 ID（十位字符，见 Developer 后台 Membership）
#
# 其它环境变量：
#   PRECHECK_ONLY=1  只跑签名预检，不联网、不需要凭据（本地验证脚本本身用）
#   NOTARY_TIMEOUT   等待公证结论的上限，默认 30m
set -euo pipefail

TARGET="${1:-dist/Harness.app}"
cd "$(dirname "$0")/.."

case "$TARGET" in
  *.dmg) MODE=dmg ;;
  *)     MODE=app ;;
esac

if [ "$MODE" = "app" ] && [ ! -d "$TARGET" ]; then
  echo "!! 找不到 ${TARGET}，先跑 ./scripts/build.sh" >&2
  exit 1
fi
if [ "$MODE" = "dmg" ] && [ ! -f "$TARGET" ]; then
  echo "!! 找不到 ${TARGET}，先跑 ./scripts/make-dmg.sh" >&2
  exit 1
fi

# ---------- 预检 ----------
# Apple 拒绝一次要几分钟，而这几件事在本地一秒就能查出来。
#   .app：Developer ID Application 签名 + 加固运行时 + 安全时间戳，三条都是硬性前提
#   .dmg：只看签名权威——dmg 不是可执行代码，没有加固运行时这回事
precheck() {
  local info
  info="$(codesign -dv --verbose=4 "$TARGET" 2>&1)"

  if ! grep -q "Authority=Developer ID Application" <<<"$info"; then
    echo "!! $TARGET 不是 Developer ID Application 签名，公证一定被拒。" >&2
    echo "   用发布身份重签：CODESIGN_IDENTITY=\"Developer ID Application: <名字> (<TeamID>)\" ./scripts/build.sh" >&2
    echo "   钥匙串里现有的签名身份：" >&2
    security find-identity -v -p codesigning | sed 's/^/     /' >&2
    return 1
  fi

  if [ "$MODE" = "dmg" ]; then
    codesign --verify --strict --verbose=1 "$TARGET"
    echo "==> 预检通过：dmg 已用 Developer ID 签名"
    return 0
  fi

  if ! grep -qE 'flags=.*runtime' <<<"$info"; then
    echo "!! $TARGET 没启用加固运行时（--options runtime），公证一定被拒。" >&2
    return 1
  fi

  if ! grep -q "Timestamp=" <<<"$info"; then
    echo "!! $TARGET 没有安全时间戳。build.sh 只对 Developer ID 身份开 --timestamp，" >&2
    echo "   出现这条说明签名身份不对或签名时断网。" >&2
    return 1
  fi

  # 嵌套的 Mach-O 也得各自满足同样条件；--deep --strict 会连带检查它们的签名有效性。
  codesign --verify --deep --strict --verbose=1 "$TARGET"
  echo "==> 预检通过：Developer ID + 加固运行时 + 安全时间戳"
}

precheck
if [ "${PRECHECK_ONLY:-}" = "1" ]; then
  echo "==> PRECHECK_ONLY=1，到此为止"
  exit 0
fi

# ---------- 凭据 ----------
# 密钥文件用 umask 077 落到临时目录并 trap 删除：notarytool 只认文件路径，
# 而 CI 里拿到的是 base64 字符串。
CREDS=()
CLEANUP=()
# rm -rf 而不是 -f：待公证的 zip 落在一个 mktemp -d 出来的目录里，只删文件会把空目录
# 留在 $TMPDIR 下攒着。数组用 ${a[@]+"${a[@]}"} 展开——bash 3.2 + set -u 把空数组的
# "${a[@]}" 当未绑定变量。
cleanup() { for f in ${CLEANUP[@]+"${CLEANUP[@]}"}; do rm -rf "$f"; done; }
trap cleanup EXIT

if [ -n "${AC_API_KEY_ID:-}" ] && [ -n "${AC_API_ISSUER_ID:-}" ]; then
  KEY_PATH="${AC_API_KEY_PATH:-}"
  if [ -z "$KEY_PATH" ]; then
    if [ -z "${AC_API_KEY_P8:-}" ]; then
      echo "!! 给了 AC_API_KEY_ID 但没给 AC_API_KEY_P8 / AC_API_KEY_PATH" >&2
      exit 1
    fi
    KEY_PATH="$(umask 077 && mktemp -t harness-ac-key)"
    CLEANUP+=("$KEY_PATH")
    printf '%s' "$AC_API_KEY_P8" | base64 --decode > "$KEY_PATH"
  fi
  CREDS=(--key "$KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID")
  echo "==> 凭据：App Store Connect API 密钥（key id ${AC_API_KEY_ID}）"
elif [ -n "${AC_APPLE_ID:-}" ] && [ -n "${AC_PASSWORD:-}" ] && [ -n "${AC_TEAM_ID:-}" ]; then
  CREDS=(--apple-id "$AC_APPLE_ID" --password "$AC_PASSWORD" --team-id "$AC_TEAM_ID")
  echo "==> 凭据：Apple ID + 专用密码（team ${AC_TEAM_ID}）"
else
  echo "!! 没有可用凭据。要么给 AC_API_KEY_ID + AC_API_ISSUER_ID + AC_API_KEY_P8，" >&2
  echo "   要么给 AC_APPLE_ID + AC_PASSWORD + AC_TEAM_ID（见本脚本头部注释）。" >&2
  exit 1
fi

# ---------- 提交 ----------
# notarytool 只吃 zip/dmg/pkg。dmg 可以直接提交；.app 是目录，得先打一个"提交用"的包。
# 那个包与最终分发的不是同一个：票据装订到 .app 上，装订完必须重新打包（见下），
# 否则用户下到的还是没票据的那份。
if [ "$MODE" = "dmg" ]; then
  SUBMIT_FILE="$TARGET"
else
  SUBMIT_DIR="$(mktemp -d -t harness-notarize)"
  CLEANUP+=("$SUBMIT_DIR")
  SUBMIT_FILE="$SUBMIT_DIR/$(basename "$TARGET" .app).zip"
  echo "==> 打包待公证：${SUBMIT_FILE}"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT_FILE"
fi

echo "==> 提交公证（等待结论，最长 ${NOTARY_TIMEOUT:-30m}）"
set +e
SUBMIT_LOG="$(xcrun notarytool submit "$SUBMIT_FILE" "${CREDS[@]}" \
  --wait --timeout "${NOTARY_TIMEOUT:-30m}" 2>&1)"
SUBMIT_STATUS=$?
set -e
echo "$SUBMIT_LOG"

# 失败时把 Apple 的逐条问题拉下来——"Invalid"三个字对修问题没有任何帮助，
# 真正的原因（哪个文件没签、缺哪个 entitlement）只在这份日志里。
if [ $SUBMIT_STATUS -ne 0 ] || ! grep -q "status: Accepted" <<<"$SUBMIT_LOG"; then
  REQUEST_ID="$(sed -n 's/^ *id: \([0-9a-f-]*\)$/\1/p' <<<"$SUBMIT_LOG" | head -1)"
  if [ -n "$REQUEST_ID" ]; then
    # ${} 不能省：bash 3.2 会把紧跟的全角括号并进变量名，set -u 下整个脚本在这一行
    # 就以 `REQUEST_ID）: unbound variable` 中止，下面那条日志再也拉不到——
    # 偏偏这是最需要它的时候。
    echo "==> 公证未通过，拉取详细日志（${REQUEST_ID}）" >&2
    xcrun notarytool log "$REQUEST_ID" "${CREDS[@]}" >&2 || true
  fi
  exit 1
fi

# ---------- 装订与校验 ----------
# 装订把票据写进目标自己：用户首次打开时无需联网，Gatekeeper 也能放行。
# .app 与 .dmg 都要各自装订——dmg 里那份 .app 的票据不覆盖 dmg 本身的隔离标记。
echo "==> 装订票据"
xcrun stapler staple "$TARGET"

echo "==> 校验"
xcrun stapler validate "$TARGET"
# spctl 是 Gatekeeper 自己的判断，与 codesign --verify 不是一回事：
# 后者只说签名完整，前者才说"这台机器会不会放它过"。
# dmg 不是可执行代码，要按"打开这个文件"来评估（--type open），用 --type exec 会直接
# 报 rejected，看着像公证失败其实是问错了问题。
ASSESS=(--assess --type exec)
if [ "$MODE" = "dmg" ]; then
  ASSESS=(--assess --type open --context context:primary-signature)
fi
if spctl --status 2>&1 | grep -q "assessments disabled"; then
  echo "!! 本机 Gatekeeper 评估已关闭，spctl 不能提供有效结论，跳过这一步。" >&2
  echo "   公证票据仍已通过 stapler 校验；请在启用 Gatekeeper 的 Mac 上复核安装包。" >&2
else
  spctl "${ASSESS[@]}" --verbose=4 "$TARGET"
fi
echo "==> 公证完成：${TARGET}"
