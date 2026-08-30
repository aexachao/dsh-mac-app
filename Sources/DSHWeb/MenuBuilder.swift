import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let menuLog = Logger(subsystem: "local.harness.app", category: "menu")

/// 菜单语言偏好（设置中切换；存储于 UserDefaults）。
/// 默认简体中文；同时同步到 dsh 服务的界面语言。
enum AppLanguage: String, CaseIterable {
    case zh = "zh"
    case en = "en"
}

/// 手动构建整个主菜单栏（中文/英文两套），
/// 完全控制菜单标题与文案（SwiftUI 无法改写系统菜单标题）。
enum MenuBuilder {

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .zh
    }

    @MainActor static func applyLanguage(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
        rebuild()
    }

    /// 把语言偏好写入 dsh 的 settings.yaml（locale.preference）。
    /// nodePath / settingsPath / yamlPath 可注入（测试用临时文件 + 真实 yaml 模块）。
    static func writeLocalePreference(nodePath: String, settingsPath: String, yamlPath: String, language: AppLanguage) {
        let script = "const fs=require('fs');const YAML=require('" + yamlPath + "');" +
            "const p='" + settingsPath + "';" +
            "const doc=YAML.parseDocument(fs.readFileSync(p,'utf8'));" +
            "doc.setIn(['locale','preference'],'" + language.rawValue + "');" +
            "fs.writeFileSync(p,doc.toString());"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: nodePath)
        task.arguments = ["-e", script]
        try? task.run()
        task.waitUntilExit()
    }

    /// 解析 node 路径（与服务一致：nvm 最新 → Homebrew → /usr/local）。
    static func resolveNodePath(home: String = NSHomeDirectory()) -> String {
        var nodePath = "/usr/local/bin/node"
        if let nvm = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: home + "/.nvm/versions/node"),
            includingPropertiesForKeys: nil
        ).sorted(by: { $0.path > $1.path }).first {
            nodePath = nvm.appendingPathComponent("bin/node").path
        } else if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/node") {
            nodePath = "/opt/homebrew/bin/node"
        }
        return nodePath
    }

    /// 当前构建的菜单（守护 Timer 用它判断是否被覆盖）。
    private nonisolated(unsafe) static var lastMenu: NSMenu?

    /// 诊断：把当前 mainMenu 结构记进日志（验证菜单是否被覆盖）。
    ///
    /// 去重与限长的策略都在 `MenuStateLog`：周期快照每 3 秒来一次，不去重会把日志
    /// 写到几十 MB，真正有用的那几行反而被埋掉。
    @MainActor static func dumpMenuState(_ event: MenuStateLog.Event) {
        let body = NSApp.mainMenu?.items.compactMap { item -> String? in
            let subs = item.submenu?.items.compactMap { $0.title.isEmpty ? nil : $0.title }.joined(separator: "|") ?? ""
            return "\(item.title): \(subs)"
        }.joined(separator: "\n") ?? "nil"
        MenuStateLog.record(event, body: body)
    }

    @MainActor static func rebuild() {

        // 立即设置 + 延迟再设一次：SwiftUI 可能在渲染周期/激活时
        // 重建默认菜单，双设置覆盖两种时序。
        let menu = buildMenu(language: current)
        lastMenu = menu
        NSApp.mainMenu = menu
        dumpMenuState(.rebuildSet)
        DispatchQueue.main.async { [self] in
            guard lastMenu !== NSApp.mainMenu else { return }
            let menu = buildMenu(language: current)
            lastMenu = menu
            NSApp.mainMenu = menu
            dumpMenuState(.rebuildDelayed)
        }
    }

    /// 守护：周期性检查菜单是否被 SwiftUI 覆盖，是则恢复。
    @MainActor static func startGuard() {
        menuLog.info("guard started")
        var tick = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let lastMenu, NSApp.mainMenu !== lastMenu {
                    menuLog.info("guard: menu overridden, rebuilding")
                    dumpMenuState(.guardOverride)
                    rebuild()
                }
                tick += 1
                if tick % 3 == 0 {
                    dumpMenuState(.tick)
                }
            }
        }
        timer.tolerance = 0.5
    }

    /// 创建带 SF Symbol 图标的菜单项（macOS 14+）。
    @MainActor private static func item(_ title: String, symbol: String? = nil,
                                        action: Selector?, key: String = "",
                                        target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    @MainActor static func buildMenu(language: AppLanguage) -> NSMenu {
        let lang = language
        let main = NSMenu()

        // ── 应用菜单（Harness）──
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: lang == .zh ? "关于 Harness" : "About Harness",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item(lang == .zh ? "设置…" : "Settings…", symbol: "gearshape",
                             action: #selector(MenuActions.openSettings), key: ",",
                             target: MenuActions.shared))
        appMenu.addItem(.separator())
        let logsItem = item(lang == .zh ? "日志" : "Logs", symbol: "terminal",
                             action: #selector(MenuActions.toggleLogs), key: "l",
                             target: MenuActions.shared)
        logsItem.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(logsItem)
        let restartItem = item(lang == .zh ? "重启服务" : "Restart Service", symbol: "arrow.clockwise",
                               action: #selector(MenuActions.restartService), key: "r",
                               target: MenuActions.shared)
        restartItem.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(restartItem)
        // 安全模式的菜单入口按当前状态二选一：同时给「进入」和「退出」两条会让用户
        // 无从判断现在到底在哪个模式里。
        let inSafeMode = ServerManager.shared.isSafeMode
        appMenu.addItem(item(
            inSafeMode
                ? (lang == .zh ? "退出安全模式并重启" : "Exit Safe Mode and Restart")
                : (lang == .zh ? "以安全模式重启" : "Restart in Safe Mode"),
            symbol: inSafeMode ? "shield.slash" : "shield.lefthalf.filled",
            action: #selector(MenuActions.toggleSafeMode),
            target: MenuActions.shared
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: lang == .zh ? "隐藏 Harness" : "Hide Harness",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: lang == .zh ? "退出 Harness" : "Quit Harness",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // ── 文件 ──
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: lang == .zh ? "文件" : "File")
        fileItem.submenu = fileMenu
        let openItem = item(lang == .zh ? "在浏览器中打开" : "Open in Browser", symbol: "safari",
                             action: #selector(MenuActions.openInBrowser), key: "o",
                             target: MenuActions.shared)
        openItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(item(lang == .zh ? "导出诊断信息…" : "Export Diagnostics…", symbol: "stethoscope",
                              action: #selector(MenuActions.exportDiagnostics),
                              target: MenuActions.shared))
        fileMenu.addItem(item(lang == .zh ? "打开日志目录" : "Open Log Folder", symbol: "folder",
                              action: #selector(MenuActions.openLogDirectory),
                              target: MenuActions.shared))

        // ── 编辑（WebView 需要剪贴板/撤销）──
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: lang == .zh ? "编辑" : "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: lang == .zh ? "撤销" : "Undo",
                         action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: lang == .zh ? "重做" : "Redo",
                         action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: lang == .zh ? "剪切" : "Cut",
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: lang == .zh ? "复制" : "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: lang == .zh ? "粘贴" : "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: lang == .zh ? "全选" : "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // ── 视图 ──
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: lang == .zh ? "视图" : "View")
        viewItem.submenu = viewMenu
        let reloadItem = item(lang == .zh ? "重新加载页面" : "Reload Page", symbol: "arrow.clockwise",
                               action: #selector(MenuActions.reloadPage), key: "r",
                               target: MenuActions.shared)
        viewMenu.addItem(reloadItem)

        // ── 窗口 ──
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: lang == .zh ? "窗口" : "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: lang == .zh ? "最小化" : "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: lang == .zh ? "缩放" : "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: lang == .zh ? "前置全部窗口" : "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        return main
    }
}

/// 菜单动作的目标（AppKit 菜单的 action 需要 NSObject 目标）。
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()
    /// 打开独立日志窗口（正常运行时）。
    @objc func toggleLogs() {
        LogPanel.shared.toggle()
    }

    @objc func restartService() {
        ServerManager.shared.restart()
    }

    /// 在安全模式与正常模式之间切换（两者都会重启服务）。
    ///
    /// 菜单每秒由 `startGuard` 重建，标题因此能跟上状态；这里只按当前状态取反。
    @objc func toggleSafeMode() {
        let server = ServerManager.shared
        if server.isSafeMode {
            server.exitSafeMode()
        } else {
            server.enterSafeMode()
        }
    }

    @objc func reloadPage() {
        AppState.shared.webController.reload()
    }

    @objc func openInBrowser() {
        if let url = AppState.shared.server.webURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// 导出诊断报告到用户选定的文件。
    ///
    /// 用保存对话框而不是直接写到桌面：报告含本机路径，去哪儿应该由用户决定。
    /// 内容已由 `DiagnosticsReport` 脱敏——它是整份内容离开本机前的最后一道关口。
    @objc func exportDiagnostics() {
        let language = MenuBuilder.current
        let report = ServerManager.shared.diagnosticsReport()
        let panel = NSSavePanel()
        panel.title = language == .zh ? "导出诊断信息" : "Export Diagnostics"
        panel.nameFieldStringValue = DiagnosticsReport.suggestedFileName(at: Date())
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = language == .zh ? "导出失败" : "Export failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// 在 Finder 中显示落盘日志目录（还没写过日志时目录可能不存在，先建出来）。
    @objc func openLogDirectory() {
        let directory = ServerManager.shared.logDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
    }

    /// 设置窗口（AppKit NSPanel 托管 SwiftUI 视图 —— 比 SwiftUI Settings
    /// 场景更可控：菜单 action 可直接触发，关闭后可重复打开）。
    @objc func openSettings() {
        let panel = SettingsPanel.shared
        if !panel.isVisible {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 单例设置面板。
@MainActor
final class SettingsPanel: NSPanel {
    static let shared = SettingsPanel()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = Strings.text(.settingsTitle, MenuBuilder.current)
        contentView = NSHostingView(rootView: SettingsView())
        isReleasedWhenClosed = false
    }
}
