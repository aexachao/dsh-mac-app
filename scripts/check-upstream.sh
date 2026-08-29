#!/bin/bash
# 检查上游版本，把 runtime-pins.json 更新到"我们愿意跟随的最新版"，并打印变更摘要。
#
# 跟随策略（有意保守，两条线不同）：
#   dsh  —— 跟 npm 的 latest tag。捆绑的意义是定版，但定在哪一版应该跟着上游走。
#   node —— 只在锁定的大版本内跟（24.x → 24.y），不跨大版本。跨大版本会换掉
#           ABI（node-pty / sharp / koffi 都是按 NODE_MODULE_VERSION 编译的预构建），
#           那不是升级而是移植，必须人来决定。
#
# 只改文件、不提交。是否值得发一版由 CI（follow-upstream.yml）或人来判断。
# 改完必须重新跑一次端到端启动验证——见 runtime-pins.json 里的说明。
set -euo pipefail
cd "$(dirname "$0")/.."

PINS="runtime-pins.json"

python3 - "$PINS" <<'PY'
import json, re, sys, urllib.request

pins_path = sys.argv[1]
with open(pins_path, encoding="utf-8") as f:
    pins = json.load(f)

def fetch(url, binary=False):
    with urllib.request.urlopen(url, timeout=30) as r:
        raw = r.read()
    return raw if binary else raw.decode("utf-8")

changes = []

# ---------- dsh：跟 npm latest ----------
meta = json.loads(fetch("https://registry.npmjs.org/@deepseek-ai/dsh"))
latest_dsh = meta["dist-tags"]["latest"]
if latest_dsh != pins["dsh"]["version"]:
    changes.append(f'dsh: {pins["dsh"]["version"]} → {latest_dsh}')
    pins["dsh"]["version"] = latest_dsh

# ---------- node：只在同一大版本内跟 ----------
pinned_node = pins["node"]["version"]
major = pinned_node.split(".")[0]
index = json.loads(fetch("https://nodejs.org/dist/index.json"))

def as_tuple(v):
    return tuple(int(p) for p in v.lstrip("v").split("."))

same_major = [e["version"] for e in index if e["version"].lstrip("v").split(".")[0] == major]
if not same_major:
    print(f"!! nodejs.org 上找不到 {major}.x，跳过 node 检查", file=sys.stderr)
else:
    newest = max(same_major, key=as_tuple).lstrip("v")
    if as_tuple(newest) > as_tuple(pinned_node):
        # SHA256 必须与版本同时更新：供应链校验是 vendor-runtime.sh 唯一的把关点，
        # 版本变了而校验和没变，脚本会在下载后中止（这是对的，但把问题推迟了）。
        #
        # 格式必须与 vendor-runtime.sh 下载的那个一致——SHASUMS256.txt 里 .tar.gz 和
        # .tar.xz 是两行不同的校验和，取错了要等到下一次真的升级 node 才会暴露成
        # "校验和对不上"。那边用 tar.gz（`tar -xzf`），这里也只认 tar.gz。
        sums = fetch(f"https://nodejs.org/dist/v{newest}/SHASUMS256.txt")
        wanted = {
            "arm64": f"node-v{newest}-darwin-arm64.tar.gz",
            "x64": f"node-v{newest}-darwin-x64.tar.gz",
        }
        found = {}
        for line in sums.splitlines():
            m = re.match(r"^([0-9a-f]{64})\s+(\S+)$", line.strip())
            if not m:
                continue
            for arch, name in wanted.items():
                if m.group(2) == name:
                    found[arch] = m.group(1)
        missing = set(wanted) - set(found)
        if missing:
            print(f"!! v{newest} 的 SHASUMS256.txt 里缺 {sorted(missing)}，跳过 node 升级", file=sys.stderr)
        else:
            changes.append(f"node: {pinned_node} → {newest}")
            pins["node"]["version"] = newest
            pins["node"]["sha256"] = found

if not changes:
    print("==> 已是我们愿意跟随的最新版，无需改动")
    sys.exit(0)

with open(pins_path, "w", encoding="utf-8") as f:
    json.dump(pins, f, ensure_ascii=False, indent=2)
    f.write("\n")

print("==> 更新 " + pins_path)
for c in changes:
    print("   - " + c)
PY
