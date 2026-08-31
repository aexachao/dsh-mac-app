import AppKit
import Testing
@testable import DSHWeb

/// 关窗只收起界面：应用留在 Dock 里、dsh 服务继续跑，只有 ⌘Q 才真退出。
///
/// 这三件事任意一件回退，症状都是「正在跑的任务被关窗打断」——而那正是原生外壳
/// 相对网页端唯一说得出口的好处。编译器一句话都不会说，所以钉在这里。
@MainActor
struct BackgroundResidencyTests {

    @Test func closingTheWindowDoesNotQuitTheApp() {
        // 这个 false 就是整个特性：改回 true，关窗会走 applicationShouldTerminate → stop()
        #expect(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == false)
    }

    @Test func reopeningIsHandledEvenWhenOtherWindowsAreVisible() {
        // 日志/设置面板也是窗口，主窗口关着而它们开着时系统报的是 true；
        // 照 hasVisibleWindows 办事，点 Dock 图标就再也叫不回主窗口
        let delegate = AppDelegate()
        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
    }

    @Test func windowSurvivesBeingClosed() {
        // 漏掉 isReleasedWhenClosed = false 时编译期毫无征兆，
        // 只在「关窗再打开」那一步崩 —— 而那一步是这个特性的全部意义
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: MainWindow.styleMask,
            backing: .buffered,
            defer: true
        )
        MainWindow.configure(window)
        #expect(window.isReleasedWhenClosed == false)
        window.close()
        #expect(window.isReleasedWhenClosed == false)
    }

    // MARK: - 窗口菜单里的两个入口

    @Test func windowMenuOffersCloseAndReopen() throws {
        for (language, close, show) in [
            (AppLanguage.zh, "关闭窗口", "显示主窗口"),
            (AppLanguage.en, "Close Window", "Show Main Window"),
        ] {
            let windowMenu = MenuBuilder.buildMenu(language: language)
                .items.compactMap(\.submenu)
                .first { $0.title == (language == .zh ? "窗口" : "Window") }
            let items = try #require(windowMenu).items

            // ⌘W：关窗不再等于退出，所以它该有标准快捷键
            let closeItem = try #require(items.first { $0.title == close })
            #expect(closeItem.keyEquivalent == "w")
            #expect(closeItem.action == #selector(NSWindow.performClose(_:)))

            // 关过窗之后，除了点 Dock 图标，菜单里也得找得回来
            let showItem = try #require(items.first { $0.title == show })
            #expect(showItem.action == #selector(MenuActions.showMainWindow))
            #expect(showItem.target === MenuActions.shared)
        }
    }
}
