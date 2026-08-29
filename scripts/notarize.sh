#!/bin/bash
# 公证并装订 Harness.app：预检签名 → 提交 Apple 公证 → 装订票据 → 校验。
#
# 用法：
#   ./scripts/notarize.sh dist/Harness.app
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

APP="${1:-dist/Harness.app}"
cd "$(dirname "$0")/.."

if [ ! -d "$APP" ]; then
  echo "!! 找不到 $APP，先跑 ./scripts/build.sh" >&2
  exit 1
fi

# ---------- 预检 ----------
# Apple 拒绝一次要几分钟，而这三件事在本地一秒就能查出来。三条都是公证的硬性前提：
#   1. Developer ID Application 签名（自签名/ad-hoc 一律拒绝）
#   2. 加固运行时（flags 里有 runtime）
#   3. 安全时间戳（本地构建默认关掉了，发布必须开）
precheck() {
  local info
  info="$(codesign -dv --verbose=4 "$APP" 2>&1)"

  if ! grep -q "Authority=Developer ID Application" <<<"$info"; then
    echo "!! $APP 不是 Developer ID Application 签名，公证一定被拒。" >&2
    echo "   用发布身份重签：CODESIGN_IDENTITY=\"Developer ID Application: <名字> (<TeamID>)\" ./scripts/build.sh" >&2
    echo "   钥匙串里现有的签名身份：" >&2
    security find-identity -v -p codesigning | sed 's/^/     /' >&2
    return 1
  fi

  if ! grep -qE 'flags=.*runtime' <<<"$info"; then
    echo "!! $APP 没启用加固运行时（--options runtime），公证一定被拒。" >&2
    return 1
  fi

  if ! grep -q "Timestamp=" <<<"$info"; then
    echo "!! $APP 没有安全时间戳。build.sh 只对 Developer ID 身份开 --timestamp，" >&2
    echo "   出现这条说明签名身份不对或签名时断网。" >&2
    return 1
  fi

  # 嵌套的 Mach-O 也得各自满足同样条件；--deep --strict 会连带检查它们的签名有效性。
  codesign --verify --deep --strict --verbose=1 "$APP"
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
cleanup() { for f in ${CLEANUP[@]+"${CLEANUP[@]}"}; do rm -f "$f"; done; }
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
# notarytool 只吃 zip/dmg/pkg，所以先打一个"提交用"的包。它与最终分发的包不是同一个：
# 票据是装订到 .app 上的，装订完必须重新打包（见下），否则用户下到的还是没票据的那份。
SUBMIT_ZIP="$(mktemp -d -t harness-notarize)/$(basename "$APP" .app).zip"
CLEANUP+=("$SUBMIT_ZIP")
echo "==> 打包待公证：$SUBMIT_ZIP"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

echo "==> 提交公证（等待结论，最长 ${NOTARY_TIMEOUT:-30m}）"
set +e
SUBMIT_LOG="$(xcrun notarytool submit "$SUBMIT_ZIP" "${CREDS[@]}" \
  --wait --timeout "${NOTARY_TIMEOUT:-30m}" 2>&1)"
SUBMIT_STATUS=$?
set -e
echo "$SUBMIT_LOG"

# 失败时把 Apple 的逐条问题拉下来——"Invalid"三个字对修问题没有任何帮助，
# 真正的原因（哪个文件没签、缺哪个 entitlement）只在这份日志里。
if [ $SUBMIT_STATUS -ne 0 ] || ! grep -q "status: Accepted" <<<"$SUBMIT_LOG"; then
  REQUEST_ID="$(sed -n 's/^ *id: \([0-9a-f-]*\)$/\1/p' <<<"$SUBMIT_LOG" | head -1)"
  if [ -n "$REQUEST_ID" ]; then
    echo "==> 公证未通过，拉取详细日志（$REQUEST_ID）" >&2
    xcrun notarytool log "$REQUEST_ID" "${CREDS[@]}" >&2 || true
  fi
  exit 1
fi

# ---------- 装订与校验 ----------
# 装订把票据写进 .app 自己：用户首次打开时无需联网，Gatekeeper 也能放行。
echo "==> 装订票据"
xcrun stapler staple "$APP"

echo "==> 校验"
xcrun stapler validate "$APP"
# spctl 是 Gatekeeper 自己的判断，与 codesign --verify 不是一回事：
# 后者只说签名完整，前者才说"这台机器会不会放它过"。
spctl --assess --type exec --verbose=4 "$APP"
echo "==> 公证完成：$APP"
