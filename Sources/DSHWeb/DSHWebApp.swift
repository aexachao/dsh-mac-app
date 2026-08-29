import AppKit
import SwiftUI

/// 应用生命周期：手动创建窗口（NSWindow + NSHostingView），
/// 构建自定义菜单栏，退出前停止服务。
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 自定义菜单（中英文按偏好；跟随系统为默认）
        MenuBuilder.rebuild()
        MenuBuilder.startGuard() // 兜底：意外覆盖时恢复

        // 主窗口（隐藏标题栏沉浸式）
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Harness"
        window.contentView = NSHostingView(rootView: ContentView())
        window.setFrameAutosaveName("HarnessMainWindow")
        WindowChrome.apply(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ServerManager.shared.stop()
        ServerManager.shared.closeLogFile()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 兜底（如系统关机），保证不留孤儿进程、且最后几行日志已落盘
        ServerManager.shared.stop()
        ServerManager.shared.closeLogFile()
    }
}
