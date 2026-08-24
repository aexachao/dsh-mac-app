# Harness — DeepSeek dsh web 的 macOS 原生应用

把 [DeepSeek Harness](https://github.com/deepseek-ai/dsh)（dsh）的 Web 界面包装成原生 macOS 应用：打开即启动服务、退出即停止、内置日志面板。

## 功能

- **服务生命周期**：打开应用自动启动 dsh 服务（直接子进程，退出无孤儿进程）；关闭窗口即退出并停止服务
- **快速启动**：缓存存在时跳过 npx 检查，2 秒内就绪；端口可连即加载界面（不等完整初始化）
- **彻底重启**：`⌘⇧R` 自动清理残留进程后重启，插件/配置变更一次生效
- **日志面板**：启动/运行日志实时查看（含关闭按钮，`⌘⇧L` 开关），失败自动展开
- **沉浸式界面**：隐藏标题栏、网页内容延伸至顶部、深色窗口背景
- **浏览器兜底**：`⌘⇧O` 在 Chrome 打开同一界面（WebView 流式渲染卡顿时使用）
- **中文菜单**：日志 / 重启服务 / 重新加载 / 在浏览器中打开

## 构建

```bash
./scripts/build.sh
```

输出 `dist/Harness.app` 并安装到 `~/Applications/Harness.app`（ad-hoc 签名，仅本机使用）。

## 技术说明

- 原生 SwiftUI + WKWebView，无 Electron 等运行时依赖
- 服务以 `node <dsh boot> web` 直接子进程运行（不经过 npx 包装，便于退出清理）
- `ServerManager` 管理进程生命周期：启动探测端口（已有实例则直接连接）、就绪状态机（starting/running/external/failed）、彻底重启（lsof 清理残留进程）

## 目录结构

```
Sources/DSHWeb/
├── DSHWebApp.swift       # App 入口、菜单、生命周期（退出时停止服务）
├── ServerManager.swift   # 服务进程管理：启动/停止/重启/日志/状态机
├── ContentView.swift     # 主界面：三态内容区 + 日志面板
├── WebViewController.swift # WKWebView 封装（性能优化）
├── AppState.swift        # 跨 UI 共享状态（菜单与主界面）
└── WindowAccessor.swift  # 窗口外观（隐藏标题栏、深色背景）
scripts/build.sh          # SwiftPM 编译 → .app 组装 → 签名 → 安装
```

## 开源协议与贡献

- 本仓库采用 [GNU AGPL-3.0](LICENSE)（Affero General Public License v3）。
- 贡献指南见 [CONTRIBUTING.md](CONTRIBUTING.md)（开发环境、代码规范、测试要求、提交流程）。

## 依赖

- macOS 14+
- Node.js（自动探测 nvm / Homebrew / 系统路径）
- DeepSeek Harness（首次启动自动通过 npx 安装）
