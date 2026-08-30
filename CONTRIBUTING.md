# 贡献指南

欢迎贡献！无论是修复 Bug、改进功能、优化界面还是补充文档，都请先阅读本指南。

## 开发环境

- macOS 14+
- Xcode 16+（Swift 6 工具链）
- Node.js（仅本地开发需要：`swift run` 与不带 `BUNDLE_RUNTIME` 的构建没有内置运行时，会退回本机的 node + npx 缓存里的 dsh；发布包自带运行时，用户不需要装）

## 本地开发

```bash
# 本地迭代：单架构、不捆绑运行时（最快）
ARCHS=arm64 ./scripts/build.sh

# 运行单元测试
swift test

# 仅构建（不安装到 ~/Applications）
NO_INSTALL=1 ARCHS=arm64 ./scripts/build.sh

# 发布形态：把 runtime-pins.json 锁定的 node + dsh 备进 .app
# 只能单架构，且只能在对应架构的机器上跑（dsh 依赖树含平台专属原生模块，不做交叉）
BUNDLE_RUNTIME=1 ARCHS=arm64 NO_INSTALL=1 ./scripts/build.sh

# 检查签名是否满足公证要求（只做本地预检，不上传）
PRECHECK_ONLY=1 ./scripts/notarize.sh dist/Harness.app
```

> 首次带 `BUNDLE_RUNTIME=1` 构建要下载 node 并安装 dsh 的完整依赖树（约 250 MB），耗时以十分钟计；结果缓存在 `.runtime-cache/`。日常改代码不需要它。

## 代码规范

- Swift 6 严格并发（MainActor 隔离、`nonisolated(unsafe)` 仅用于明确场景）
- 遵循现有文件组织：功能模块一个文件，不超过 800 行
- 不可变优先：不修改已有对象，返回新副本
- 所有用户可见文案中英双语：新增文案写进 `Strings.swift`（`Key` + 穷尽 `switch`，漏一种语言编译不过；`StringsTests` 会拒绝空文案、英文位里的中文、两边占位符对不上）。菜单树与 `FailureCause` 自带完整双语表，日志行故意保持单语
- 所有颜色使用 SF Symbol / AppKit 标准控件，不引入硬编码主题色

## 测试要求

- 新增/修改行为必须补充单元测试（`Tests/DSHWebTests/`）
- 提交前运行 `swift test`，确保全部通过
- 视觉/交互改动附截图证据

## 提交流程

1. Fork 仓库并创建功能分支（`feat/xxx` 或 `fix/xxx`）
2. 遵循 Conventional Commits：`feat:` / `fix:` / `refactor:` / `docs:` / `test:` / `chore:` / `perf:` / `ci:`
3. 提交前：
   - `swift test` 全部通过
   - `ARCHS=arm64 ./scripts/build.sh` 构建成功
4. 提交 PR 到 `main` 分支，描述包含：
   - 改动摘要与原因
   - 测试结果
   - 截图（视觉改动）
5. 等待 review；按反馈修改（`git push --force` 更新分支）

## 版本管理

- **版本来源**：`git tag`（`vX.Y.Z`）是唯一事实来源。构建时：
  - `VERSION`/`BUILD` 环境变量可覆盖（CI 用 tag 注入）；
  - 未指定时自动推导：`git describe --tags`（有 tag → `X.Y.Z`）+ git 提交计数（BUILD）。
- **应用内查看**：菜单「关于 Harness」显示版本与构建号（读 Info.plist）。
- **规则**：每次发版前更新 `CHANGELOG.md` → 打 tag → 推送（CI 自动构建发布）。

## 发布流程（维护者）

打 tag 即触发 GitHub Actions 自动发布（按架构构建 + 签名公证 + Release + 变更日志）：

```bash
# 1. 更新 CHANGELOG.md（新增 [x.y.z] 条目）
# 2. 打 tag 并推送
git tag vX.Y.Z && git push origin vX.Y.Z
```

CI 会自动：跑测试 → 在 `macos-15` 与 `macos-15-intel` 上各自捆绑运行时并构建 → 签名 + 公证 + 装订票据 → 打成 dmg（dmg 本身再签名、公证、装订一次）与 SHA256 → 从 CHANGELOG 提取条目 + 生成提交列表 → 创建 GitHub Release。产物是两个 dmg（`apple-silicon` / `intel`），不出 universal——dsh 依赖树含平台专属原生模块，一份 `node_modules` 只能属于一个架构。

完整签名与公证需要以下仓库 secrets；缺失时会降级而不是失败（缺证书 → ad-hoc 签名，缺 API 密钥 → 只签名不公证），并在日志里给出 warning：

| Secret | 内容 |
|---|---|
| `MACOS_CERT_P12` | Developer ID Application 证书 + 私钥的 `.p12`，base64 |
| `MACOS_CERT_PASSWORD` | 导出 `.p12` 时设的密码 |
| `AC_API_KEY_ID` | App Store Connect API 密钥 ID |
| `AC_API_ISSUER_ID` | App Store Connect Issuer ID |
| `AC_API_KEY_P8` | `.p8` 私钥文件，base64 |

另有 `follow-upstream.yml` 每天检查上游版本，`runtime-pins.json` 有变化就开 PR。**合并前必须人工验证**——锁文件一变就等于换运行时，PR 描述里带了验证清单。

## 开源协议

本仓库采用 GNU AGPL-3.0（Affero 通用公共许可证第 3 版）。修改后的版本若通过网络提供服务，须向用户提供对应源码。详见 [LICENSE](LICENSE)。

## 安全

- 不提交任何密钥/令牌（.gitignore 已覆盖常见敏感文件）
- 发现安全问题时，请直接联系维护者而非公开 issue

## 反馈与 Issue

- Bug 报告：说明复现步骤、环境（macOS 版本、芯片架构）、期望行为
- 功能建议：说明使用场景与预期效果
