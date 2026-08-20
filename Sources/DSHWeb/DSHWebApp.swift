import SwiftUI

/// App 入口：关闭窗口即退出（同时终止服务进程）。
@main
struct DSHWebApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Harness") {
            ContentView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar) // 隐藏标题栏，网页内容延伸到窗口顶部
        .defaultSize(width: 1280, height: 800)
        .commands {
            // 应用菜单（点击左上角「Harness」）：日志 / 重启服务
            CommandGroup(after: .appSettings) {
                Button("日志") {
                    AppState.shared.showLogs.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("重启服务") {
                    ServerManager.shared.restart()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            // 视图菜单：重新加载页面 / 在浏览器中打开（agent 流式渲染时可切 Chrome）
            CommandGroup(after: .toolbar) {
                Button("重新加载页面") {
                    AppState.shared.webController.reload()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("在浏览器中打开") {
                    if let url = AppState.shared.server.webURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

/// 生命周期钩子：应用退出前确保服务进程被终止。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 窗口外观由 WindowAccessor 在视图挂载后配置（此时窗口才真正存在）
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ServerManager.shared.stop()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 兜底（如系统关机），保证不留孤儿进程
        ServerManager.shared.stop()
    }
}
