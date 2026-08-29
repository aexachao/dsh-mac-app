#!/bin/bash
# 把 Developer ID 证书导入一个临时钥匙串，供 codesign 使用（CI 专用）。
#
# 环境变量：
#   MACOS_CERT_P12       .p12（证书 + 私钥）的 base64
#   MACOS_CERT_PASSWORD  导出 .p12 时设的密码
#   KEYCHAIN_PASSWORD    临时钥匙串的密码（可不给，默认随机）
#
# 输出：把找到的签名身份名字打印到 stdout（供 workflow 塞给 CODESIGN_IDENTITY）。
#
# 为什么用临时钥匙串而不是 login.keychain：runner 上的 login 钥匙串是锁着的，
# 而解锁它需要 runner 用户的密码；临时钥匙串我们自己建、自己定密码，用完随 runner 销毁。
set -euo pipefail

: "${MACOS_CERT_P12:?需要 MACOS_CERT_P12（.p12 的 base64）}"
: "${MACOS_CERT_PASSWORD:?需要 MACOS_CERT_PASSWORD}"

KEYCHAIN="${RUNNER_TEMP:-/tmp}/harness-signing.keychain-db"
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-$(openssl rand -hex 24)}"
P12="$(umask 077 && mktemp -t harness-cert)"
trap 'rm -f "$P12"' EXIT

printf '%s' "$MACOS_CERT_P12" | base64 --decode > "$P12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# 关掉自动上锁：签名可能在几十分钟后（公证之后）才结束，默认 5 分钟空闲上锁会中途失效。
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

security import "$P12" -k "$KEYCHAIN" -P "$MACOS_CERT_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# 少了这一步，codesign 用私钥时会弹 UI 授权框——在 runner 上就是无限挂住。
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

# 加入搜索列表而不是替换：替换掉会连系统根证书链一起丢，签名随后校验不过。
EXISTING="$(security list-keychains -d user | tr -d '"' | tr -d ' ')"
security list-keychains -d user -s "$KEYCHAIN" ${EXISTING}

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"

if [ -z "$IDENTITY" ]; then
  echo "!! 导入成功但钥匙串里没有 Developer ID Application 身份。" >&2
  echo "   .p12 里大概只有 Apple Development / Apple Distribution 证书——公证要的是前者之外那一张。" >&2
  security find-identity -v -p codesigning "$KEYCHAIN" >&2
  exit 1
fi

echo "$IDENTITY"
