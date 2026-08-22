import SwiftUI
import AppKit

/// 在视图挂载后拿到真实的 NSWindow（比 applicationDidFinishLaunching 时机可靠）。
struct WindowAccessor: NSViewRepresentable {
    var onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.onWindow(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 把窗口配置成「网页全屏」模式：标题栏透明、内容延伸到顶部、
/// 窗口背景染成深色 — 红绿灯区域与网页背景融为一体。
enum WindowChrome {
    @MainActor
    static func apply(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        // 与 dsh web 深色主题接近的兜底背景色（内容未覆盖时也保持同色）
        window.backgroundColor = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1)
    }
}
