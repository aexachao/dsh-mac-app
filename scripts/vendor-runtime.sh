#!/bin/bash
# 把 pin 住的 node 与 dsh 依赖树备到 <dest>/runtime 下，供 .app 直接使用。
#
# 用法：scripts/vendor-runtime.sh <arm64|x86_64> <dest-dir>
#   dest-dir 下会生成 runtime/{node,dsh,manifest.json}
#
# 为什么只允许本机架构：
#   dsh 依赖树里有三个按平台挑选的原生包（@img/sharp-darwin-*、@koromix/koffi-darwin-*、
#   node-addon-require-builtin-darwin-*），npm 按运行环境选 optionalDependencies。跨架构装
#   出来的树带的是宿主架构的 .node，换台机器直接崩，而且崩在 dlopen 里没有任何可读报错。
#   所以两个架构各自在对应机器上 vendor（CI 用 macos-15 与 macos-15-intel），不做交叉。
#
# 版本只从 runtime-pins.json 读，不接受 latest：捆绑的意义就是把「用户机器上碰巧缓存了什么」
# 换成一个我们验证过的确定版本。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

ARCH="${1:?用法: vendor-runtime.sh <arm64|x86_64> <dest-dir>}"
DEST_ARG="${2:?用法: vendor-runtime.sh <arm64|x86_64> <dest-dir>}"
PINS="runtime-pins.json"
CACHE="${RUNTIME_CACHE:-.runtime-cache}"

case "$ARCH" in
  arm64)  NODE_ARCH="arm64" ;;
  x86_64) NODE_ARCH="x64" ;;
  *) echo "!! 不支持的架构: ${ARCH}（只接受 arm64 / x86_64）" >&2; exit 1 ;;
esac

HOST="$(uname -m)"
if [ "$ARCH" != "$HOST" ]; then
  echo "!! 拒绝交叉 vendor：请求 ${ARCH}，本机是 $HOST" >&2
  echo "   dsh 树含按平台选择的原生模块，跨架构装出来的是坏的。请在对应架构的机器上运行。" >&2
  exit 1
fi

mkdir -p "$DEST_ARG"
DEST="$(cd "$DEST_ARG" && pwd)"

NODE_VERSION="$(plutil -extract node.version raw -o - "$PINS")"
NODE_SHA="$(plutil -extract "node.sha256.$NODE_ARCH" raw -o - "$PINS")"
DSH_VERSION="$(plutil -extract dsh.version raw -o - "$PINS")"
echo "==> pin: node v$NODE_VERSION ($NODE_ARCH) + @deepseek-ai/dsh@$DSH_VERSION"

# ---------- node ----------
NODE_CACHE="$CACHE/node-v$NODE_VERSION-darwin-$NODE_ARCH"
mkdir -p "$CACHE"
if [ ! -x "$NODE_CACHE/bin/node" ]; then
  TARBALL="node-v$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"
  echo "==> 下载 $TARBALL"
  curl -fL --retry 3 --retry-delay 2 -o "$CACHE/$TARBALL" \
    "https://nodejs.org/dist/v$NODE_VERSION/$TARBALL"

  # 供应链校验：这份二进制会带着我们的签名分发给用户，对不上就必须中止，不存在「先凑合用」
  ACTUAL="$(shasum -a 256 "$CACHE/$TARBALL" | awk '{print $1}')"
  if [ "$ACTUAL" != "$NODE_SHA" ]; then
    rm -f "$CACHE/$TARBALL"
    echo "!! node 压缩包 SHA256 不匹配，已删除并中止" >&2
    echo "   期望 $NODE_SHA" >&2
    echo "   实际 $ACTUAL" >&2
    exit 1
  fi
  echo "==> SHA256 校验通过"

  rm -rf "$NODE_CACHE"
  mkdir -p "$NODE_CACHE"
  tar -xzf "$CACHE/$TARBALL" -C "$NODE_CACHE" --strip-components=1
  rm -f "$CACHE/$TARBALL"
  # include/ 是编译原生模块用的头文件、share/ 是 man 与文档，运行 dsh 都不需要
  rm -rf "$NODE_CACHE/include" "$NODE_CACHE/share"
fi
NODE_BIN="$ROOT/$NODE_CACHE/bin/node"
echo "==> node 就绪: $("$NODE_BIN" --version)"

# ---------- dsh 依赖树 ----------
DSH_CACHE="$CACHE/dsh-$DSH_VERSION-darwin-$NODE_ARCH"
DSH_ENTRY="node_modules/@deepseek-ai/dsh/lib/bin.js"
if [ ! -f "$DSH_CACHE/$DSH_ENTRY" ]; then
  echo "==> 安装 @deepseek-ai/dsh@${DSH_VERSION}（约 280 MB，首次要几分钟到十几分钟）"
  rm -rf "$DSH_CACHE"
  mkdir -p "$DSH_CACHE"
  # 用刚下下来的 pin 版 node 装，让原生模块的 N-API ABI 与我们捆绑的 node 是同一个
  ( cd "$DSH_CACHE" \
    && NODE_OPTIONS="--max-old-space-size=4096" PATH="$ROOT/$NODE_CACHE/bin:$PATH" npm install \
         --omit=dev --no-audit --no-fund --loglevel=error \
         "@deepseek-ai/dsh@$DSH_VERSION" )

  # node-pty 一个包里带了全部平台的 prebuild（win32/linux 各两三个 .node），macOS 上永远
  # 用不到。只删别的操作系统的目录，darwin-* 一个不动。
  if [ -d "$DSH_CACHE/node_modules/node-pty/prebuilds" ]; then
    find "$DSH_CACHE/node_modules/node-pty/prebuilds" -mindepth 1 -maxdepth 1 -type d \
      ! -name 'darwin-*' -exec rm -rf {} +
  fi
fi
INSTALLED_DSH="$("$NODE_BIN" -p \
  "require('$ROOT/$DSH_CACHE/node_modules/@deepseek-ai/dsh/package.json').version")"
if [ "$INSTALLED_DSH" != "$DSH_VERSION" ]; then
  echo "!! 缓存里的 dsh 是 ${INSTALLED_DSH}，pin 的是 ${DSH_VERSION}。删掉 $DSH_CACHE 重跑。" >&2
  exit 1
fi
echo "==> dsh 就绪: $INSTALLED_DSH"

# ---------- 组装 ----------
echo "==> 组装 $DEST/runtime"
rm -rf "$DEST/runtime"
mkdir -p "$DEST/runtime"
cp -R "$NODE_CACHE" "$DEST/runtime/node"
cp -R "$DSH_CACHE" "$DEST/runtime/dsh"

# manifest 给应用自己读：诊断报告要显示捆绑了什么版本，版本错位的判断也要用它
cat > "$DEST/runtime/manifest.json" <<MANIFEST
{
  "node": "$NODE_VERSION",
  "dsh": "$DSH_VERSION",
  "arch": "$ARCH"
}
MANIFEST

# ---------- 自检 ----------
# 用捆绑的 node 跑捆绑的 dsh，确认这一份真的能启动。装出来但跑不起来的树是最坏的情况：
# 构建通过、发布出去、用户第一次打开才炸。
echo "==> 自检：用捆绑运行时执行 dsh --version"
BUNDLED_NODE="$DEST/runtime/node/bin/node"
BUNDLED_DSH="$DEST/runtime/dsh/$DSH_ENTRY"
"$BUNDLED_NODE" "$BUNDLED_DSH" --version
echo "==> 体积: $(du -sh "$DEST/runtime" | awk '{print $1}')"
echo "==> done"
