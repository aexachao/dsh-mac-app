import AppKit
import SwiftUI

/// 独立日志窗口（菜单「日志」打开；实时跟随 ServerManager 日志）。
@MainActor
final class LogPanel: NSWindow {
    static let shared = LogPanel()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // 语言切换要求重启应用，所以这里在 init 时定一次就够
        title = Strings.text(.logs, MenuBuilder.current)
        contentView = NSHostingView(rootView: LogListView())
        isReleasedWhenClosed = false
    }

    func toggle() {
        if isVisible {
            close()
        } else {
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// 独立窗口用的纯日志列表（实时追踪 ServerManager.logLines）。
struct LogListView: View {
    var body: some View {
        LogView(lines: ServerManager.shared.logLines) {
            LogPanel.shared.close()
        }
    }
}
