# 贡献指南

欢迎贡献！无论是修复 Bug、改进功能、优化界面还是补充文档，都请先阅读本指南。

## 开发环境

- macOS 14+
- Xcode 16+（Swift 6 工具链）
- Node.js（运行时依赖，自动探测 nvm / Homebrew / 系统路径）

## 本地开发

```bash
# 构建（默认 universal 双架构）
./scripts/build.sh

# 单架构快速构建（本地迭代更快）
ARCHS=arm64 ./scripts/build.sh

# 运行单元测试
swift test

# 仅构建（不安装到 ~/Applications）
NO_INSTALL=1 ./scripts/build.sh
```

## 代码规范

- Swift 6 严格并发（MainActor 隔离、`nonisolated(unsafe)` 仅用于明确场景）
- 遵循现有文件组织：功能模块一个文件，不超过 800 行
- 不可变优先：不修改已有对象，返回新副本
- 所有用户可见文案中英双语（`MenuBuilder` 中通过 `AppLanguage` 切换）
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
   - `./scripts/build.sh` 构建成功
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

打 tag 即触发 GitHub Actions 自动发布（universal 构建 + Release + 变更日志）：

```bash
# 1. 更新 CHANGELOG.md（新增 [x.y.z] 条目）
# 2. 打 tag 并推送
git tag vX.Y.Z && git push origin vX.Y.Z
```

CI 会自动：双架构编译 → 打包 zip → 从 CHANGELOG 提取条目 + 生成提交列表 → 创建 GitHub Release。

## 开源协议

本仓库采用 GNU AGPL-3.0（Affero 通用公共许可证第 3 版）。修改后的版本若通过网络提供服务，须向用户提供对应源码。详见 [LICENSE](LICENSE)。

## 安全

- 不提交任何密钥/令牌（.gitignore 已覆盖常见敏感文件）
- 发现安全问题时，请直接联系维护者而非公开 issue

## 反馈与 Issue

- Bug 报告：说明复现步骤、环境（macOS 版本、芯片架构）、期望行为
- 功能建议：说明使用场景与预期效果
