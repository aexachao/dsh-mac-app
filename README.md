<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="Harness — DeepSeek dsh web 的 macOS 原生应用：打开即启动服务，退出即停止">
</p>

<p align="center">
  <img src="./assets/readme/harness-main.png" width="100%" alt="Harness 应用运行界面：深色 DeepSeek Harness 会话工作台">
</p>

**Harness** 把 [DeepSeek Harness](https://github.com/deepseek-ai/dsh)（dsh）的 Web 工作台包装成原生 macOS 应用 —— 打开即启动服务、退出即停止，内置实时日志与中文菜单栏。

## 它解决什么

在浏览器里用 dsh 需要自己记着「先 `dsh web` 再打开页面，用完后杀掉进程」。Harness 把这一整段变成两个动作：

| 动作 | 发生的事 |
|---|---|
| **打开应用** | 自动找到 Node、启动 dsh 服务（2 秒就绪）、加载工作台 |
| **关闭窗口** | 服务随之停止，不留孤儿进程 |

## 功能

- **服务生命周期** — 打开启动 / 退出停止；`⌘⇧R` 彻底重启（自动清理残留进程），插件或配置变更一次生效
- **快速启动** — 缓存存在时跳过网络检查，2 秒内就绪；端口可连即显示界面
- **日志面板** — 菜单 `⌘⇧L` 打开独立日志窗口；启动失败时主界面自动展开错误日志；密钥、Cookie、OAuth 回调参数在写入前自动脱敏，日志可直接贴到 issue
- **沉浸式界面** — 隐藏标题栏、深色窗口背景，网页内容铺满窗口
- **浏览器兜底** — `⌘⇧O` 在 Chrome 打开同一界面（WebView 流式渲染卡顿时）
- **中文菜单栏** — 简体中文默认；设置中可切换 English，重启后应用与 dsh 界面语言同步

## 构建

```bash
# 构建 universal 双架构并安装到 ~/Applications
./scripts/build.sh

# 仅构建不安装（CI 用）
NO_INSTALL=1 ./scripts/build.sh

# 运行单元测试
swift test
```

> 应用使用自签名证书（`Harness Local Signing`）签名，仅限本机使用；签名身份可用 `CODESIGN_IDENTITY` 覆盖。

## 技术说明

- 原生 SwiftUI + WKWebView（无 Electron），AppKit 手动入口掌控菜单与窗口
- 服务以 `node <dsh boot> web` 直接子进程运行，退出时干净终止
- `ServerManager` 状态机：`starting / running / external / failed`；显式指定端口、冲突时退让、只清理可确认的 dsh 残留进程
- 日志脱敏后同时进内存缓冲区与 `~/Library/Logs/Harness/`（分段轮转、目录总量封顶、只清理自己写的文件）；「文件 → 导出诊断信息…」可一键导出环境与最近日志
- 菜单栏中英文两套，语言偏好同步写入 dsh 的 `~/.dsh/settings.yaml`（`locale.preference`）

## 目录结构

```
Sources/DSHWeb/
├── main.swift               # AppKit 入口（菜单不被 SwiftUI 覆盖）
├── DSHWebApp.swift          # 应用生命周期与窗口创建
├── ServerManager.swift      # 服务进程：启动/停止/重启/日志/状态机
├── PortStrategy.swift       # 端口选择策略 + 本地端口占用判定
├── DSHProcessIdentity.swift # 核对进程确实是 dsh（接管或清理前）
├── SecretMasker.swift       # 日志脱敏（密钥 / Cookie / OAuth 参数）
├── LogRotation.swift        # 落盘日志命名/时序/清理策略（纯函数）
├── LogFileSink.swift        # 日志落盘与轮转（~/Library/Logs/Harness）
├── DiagnosticsReport.swift  # 诊断报告渲染（导出前整份脱敏）
├── MenuBuilder.swift        # 中英文菜单栏 + 语言偏好 + dsh 语言同步
├── ContentView.swift        # 主界面：三态内容区 + 日志面板
├── LogPanel.swift           # 独立日志窗口
├── SettingsView.swift       # 设置（语言切换）
├── WebViewController.swift  # WKWebView 封装（性能优化）
└── WindowAccessor.swift     # 窗口外观（隐藏标题栏、深色背景）
scripts/build.sh             # SwiftPM 编译 → .app 组装 → 签名 → 安装
```

## 依赖

- macOS 14+
- Node.js（自动探测 nvm / Homebrew / 系统路径）
- DeepSeek Harness（首次启动自动通过 npx 安装）

## 开源协议与贡献

- 本仓库采用 [GNU AGPL-3.0](LICENSE)。
- 贡献指南见 [CONTRIBUTING.md](CONTRIBUTING.md)（开发环境、代码规范、测试要求、提交流程）。
