<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="Harness — DeepSeek dsh web 的 macOS 原生应用：打开即启动服务，退出即停止">
</p>

<p align="center">
  <img src="./assets/readme/harness-main.png" width="100%" alt="Harness 应用运行界面：深色 DeepSeek Harness 会话工作台">
</p>

**Harness** 把 [DeepSeek Harness](https://github.com/deepseek-ai/dsh)（dsh）的 Web 工作台包装成原生 macOS 应用。打开应用就是打开工作台，⌘Q 退出时服务随之停止 —— Node.js 与 dsh 已捆绑在包里，下载即用。

| 动作 | 发生的事 |
|---|---|
| **打开应用** | 挑一个可用端口、启动 dsh 服务、加载工作台（约 2 秒出界面） |
| **关闭窗口**（⌘W） | 只收起界面。应用留在 Dock 里、服务继续跑，任务不会被打断；点 Dock 图标或「窗口 → 显示主窗口」回来，回来时还是关掉时那一页 |
| **退出应用**（⌘Q） | 服务连插件派生的子孙进程一并终止，不留残留、不占端口 |

在浏览器里用 dsh 要自己记着「先 `dsh web`，再开页面，用完杀进程」。这两行就是 Harness 做的全部事情，剩下的篇幅都在讲它出错时怎么办。

## 下载安装

到 [Releases](https://github.com/aexachao/dsh-mac-app/releases/latest) 下载**对应你 Mac 架构**的 dmg：

| 你的 Mac | 下载 |
|---|---|
| Apple Silicon（M1/M2/M3/M4） | `Harness-<版本>-macos-apple-silicon.dmg` |
| Intel | `Harness-<版本>-macos-intel.dmg` |

不确定是哪种：左上角  → 「关于本机」，「芯片」写 Apple M 系列就是 Apple Silicon。**装错架构起不来**（[为什么没有 universal 包](#为什么这样做)）。

1. 打开 dmg
2. 把 **Harness** 拖到「应用程序」
3. 从「应用程序」（或启动台）里打开

第 2 步的措辞是认真的：**不要直接在 dmg 窗口里双击运行**。macOS 会把还带隔离标记的应用搬到一个只读临时挂载点里执行（App Translocation），路径每次启动都不一样，于是单实例锁认不出自己、文件夹访问授权反复弹窗。

发布包经 Apple 公证并装订票据，双击即可打开，不需要右键或去「隐私与安全性」里放行。想校验完整性：Release 里的 `SHA256SUMS.txt` 对应 `shasum -a 256 <下载的 dmg>`。

## 能用到什么

- **开箱即用** — 定版的 Node.js 与 dsh 随应用分发，不依赖本机环境，首次启动不下载任何东西
- **一次生效的重启** — `⌘⇧R` 停服务、等端口真的释放、再拉起，插件与配置的改动不用重开应用
- **实时日志** — `⌘⇧L` 独立日志窗口；启动失败时主界面自动展开报错。密钥、Cookie、OAuth 回调参数在写入前脱敏，日志可以直接贴进 issue
- **导出诊断** — 「文件 → 导出诊断信息…」一次性给出版本、系统、解析到的运行时、服务状态与最近日志（导出前整份再脱敏一遍）
- **单实例** — 重复打开（包括 `open -n` 和放在两个路径的两份拷贝）只把已有窗口叫到前台，不会起第二个服务去抢同一份 `~/.dsh`
- **沉浸式窗口** — 隐藏标题栏，红绿灯所在那条横带露出与 dsh 深色主题同源的窗口底色，右边那段补了一条透明拖拽条（拖动、双击、窗口不在前台时的第一下都跟真标题栏一致）；`⌘⇧O` 可以把同一个界面丢到默认浏览器里（流式渲染卡顿时的兜底）
- **中英双语** — 默认简体中文，设置里可切 English；菜单栏、状态提示、失败说明、安全模式横幅一起切换，重启后 dsh 界面语言同步跟上

## 起不来的时候

启动失败不会只给你一句英文报错。失败被分成十类，每一类都带「是什么 / 为什么 / 下一步」，并把最有用的那个动作做成主按钮：

| 遇到的情况 | 主按钮 |
|---|---|
| 配置文件格式不符 | 在 Finder 中定位到出错的那个文件 |
| 内置的 dsh 读不懂被更新版 dsh 迁移过的 `~/.dsh` | 一键改用本机安装的 dsh（此时「重试」注定再失败一次） |
| 端口耗尽 / 异常退出 | 附上日志里最后一条报错，导出诊断 |

**插件把 dsh 弄得起不来**是单独一条路径：连续 3 次启动异常后自动进入安全模式，只停用第三方插件（`@deepseek-ai/` 的第一方插件保留），界面常驻横幅说明现在少了什么、可以查看停用清单并一键退出；菜单里也能手动进入。停用只通过应用自己目录下的配置 overlay 叠加，**绝不写入 `~/.dsh`** —— 删掉那个 overlay 就完全恢复原状。

## 为什么这样做

**为什么按架构出包。** dsh 的依赖树里有平台专属的原生模块（`@img/sharp-darwin-*`、`@koromix/koffi-darwin-*`、`node-pty` 预构建），一份 `node_modules` 只能属于一个架构，universal 包装不进两份互斥的树。所以这不是「还没做」，而是做不到：`BUNDLE_RUNTIME=1` 直接拒绝多架构，Release 按 `apple-silicon` / `intel` 分别出包。

**为什么捆绑运行时。** 靠 `npx` 现取的话，全新机器的第一次启动要拉 283 MB 依赖树（实测约 14 分钟，网络稍差直接失败），而且装到的版本取决于那天 npm 上是什么。现在版本锁在 `runtime-pins.json`，node 压缩包按 SHA256 校验后才打进包；`follow-upstream.yml` 每天检查上游、有变化就开 PR，node 只在锁定的大版本内跟随（跨大版本会换掉 `NODE_MODULE_VERSION`，树里每个预构建 `.node` 都要重来，那是移植而不是升级）。逃生开关「改用本机安装的 dsh」在设置里，默认关闭。

**为什么只发 dmg。** zip 解压出来的应用仍带隔离标记，原地双击就会触发上面说的 App Translocation。dmg 里放一个指向「应用程序」的符号链接，用户先拖过去再打开，这一类问题从源头消失。dmg 本身也单独签名、公证、装订 —— 应用里的票据不解除容器的隔离标记。

**为什么关窗不等于退出。** agent 的任务跑在 dsh 服务端，窗口只是它的客户端。关窗顺手把服务停掉，正在跑的任务就断在半路 —— 那正是网页端关掉标签页的下场，也正是原生外壳该避免的。所以关窗只收起界面，⌘Q 才真退出。

**为什么退出要收整棵进程树。** 只终止那个直接子进程（node）的话，dsh 插件自己 spawn 的常驻进程（实测 dsh-doctor 的 supervisor 连 SIGTERM 都不理）会在 node 死后被 launchd 收养，活过应用退出，继续占着端口和应用所在的挂载点。所以退出前先抓下整棵子孙树再动手 —— 父进程一退出，子孙的 PPID 全变成 1，那棵树就再也认不出来了。

## 开发

```bash
ARCHS=arm64 ./scripts/build.sh   # 本地迭代：单架构、不捆绑运行时（退回本机 node）
swift test                        # 单元测试
```

完整命令（捆绑运行时、签名、公证、打 dmg）与开发规范见 [CONTRIBUTING.md](CONTRIBUTING.md)；架构与各处设计取舍的完整说明在 [CLAUDE.md](CLAUDE.md)。

<details>
<summary>代码地图</summary>

| 区域 | 文件 |
|---|---|
| 服务与运行时 | `ServerManager` `ServerArguments` `RuntimeLocator` `PortStrategy` `DSHProcessIdentity` `ProcessTree` |
| 失败与恢复 | `FailureCause` `StartupHealth` `SafeMode` `PluginInventory` |
| 日志与诊断 | `SecretMasker` `LogFileSink` `LogRotation` `DiagnosticsReport` `MenuStateLog` |
| 界面与外壳 | `main` `DSHWebApp` `MainWindow` `ContentView` `AppState` `WebViewController` `WindowAccessor` `LogPanel` `SettingsView` `MenuBuilder` `Strings` `InstanceLock` `AppRelaunch` `AppDirectories` |
| `scripts/` | `build.sh` `vendor-runtime.sh` `notarize.sh` `make-dmg.sh` `import-signing-cert.sh` `check-upstream.sh` |

</details>

## 限制与依赖

- **macOS 14+**，Apple Silicon 与 Intel 各一个包，装错架构起不来
- 其他都不用装。当前锁定 Node.js 24.20.0 与 dsh 0.1.1-rc.2（见 `runtime-pins.json`）；只有打开「改用本机安装的 dsh」时才需要本机 Node.js（自动探测 nvm / Homebrew / 系统路径）
- 代价是包大：捆绑的运行时未压缩约 384 MB（node 134 MB + dsh 依赖树 250 MB），压缩进 dmg 后约 110 MB
- `~/.dsh` 是你和其它 dsh 版本共用的状态目录，Harness 只读不写（唯一例外是切换界面语言时写 `settings.yaml` 的 `locale.preference`，走 dsh 自己的 yaml 解析器）。会话、API key 这些数据都在 `~/.dsh` 里，卸载应用不会带走它们

## 开源协议与贡献

- 本仓库采用 [GNU AGPL-3.0](LICENSE)。
- 贡献指南见 [CONTRIBUTING.md](CONTRIBUTING.md)（开发环境、代码规范、测试要求、提交流程）。
