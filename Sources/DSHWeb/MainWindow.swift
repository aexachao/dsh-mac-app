import AppKit
import SwiftUI

/// 主窗口的持有者：关窗只收起界面，不退出应用、不停服务。
///
/// agent 的任务跑在 dsh 服务端，窗口只是它的客户端。关窗顺手把服务一起停掉，
/// 正在跑的任务就断在半路 —— 那正是网页端关掉标签页的行为，也正是原生外壳
/// 本该避免的。所以：关窗后应用留在 Dock 里、服务继续跑，只有 ⌘Q（或菜单退出、
/// Dock 右键退出）才真的停服务，见 `AppDelegate`。
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()

    /// 强引用 + `isReleasedWhenClosed = false`，两者缺一不可：少了后者，AppKit 在关窗时
    /// 把窗口自己释放掉，下次显示就是访问已释放对象；少了前者，窗口在最后一次关闭后
    /// 被回收，重开只能重建内容视图。
    private var window: NSWindow?

    private override init() {
        super.init()
    }

    /// 主窗口的样式。非 private：`BackgroundResidencyTests` 用它构造同款窗口验证关闭后仍在。
    static let styleMask: NSWindow.StyleMask =
        [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    /// 显示主窗口（首次调用时创建）；已存在就把它叫回前台。
    func show() {
        let window = self.window ?? make()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: Self.styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "Harness"
        // 内容视图只建这一次。重建会让 `ContentView.onAppear` 再跑一遍（`start()`、
        // `beginUserActivity()`）；而且 WebView 活在 `AppState.shared`，重开窗口理应
        // 看到关掉时那一页 —— 包括滚动位置和输入框里还没发出去的字。
        //
        // 外面套一层 `ContentContainerView`：红绿灯右边那条拖拽条要落在 AppKit 层，
        // 用窗口坐标定位（原因见 `ContentContainerView` 的注释）。
        window.contentView = ContentContainerView(content: NSHostingView(rootView: ContentView()))
        window.setFrameAutosaveName("HarnessMainWindow")
        window.delegate = self
        Self.configure(window)
        WindowChrome.apply(window)
        window.center()
        return window
    }

    /// 关窗后仍要能再显示，所以窗口不能随关闭被释放。
    ///
    /// 单独拆成静态方法是为了能钉在测试里：漏掉这一行编译期毫无征兆，
    /// 只在「关窗再打开」这一步崩，而那一步恰好是这个特性的全部意义。
    static func configure(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
    }

    // MARK: - NSWindowDelegate

    /// 关窗时要写进日志的那行；退出路径上返回 nil。
    ///
    /// 不写的话，用户过后发现 node 还在跑，只会以为应用没退干净。但 ⌘Q 也会走到关窗，
    /// 而且是在 `stop()` 之后 —— 那时候日志里已经有「停止服务…」，紧跟一句
    /// 「服务继续在后台运行」是把真相说反了，比不写更糟。
    ///
    /// 拆成纯函数是为了能钉在测试里：两条路径的区别只体现在日志文本上，
    /// 编译期与界面上都看不出来。日志行按惯例不进 `Strings`（单语，便于和 dsh 自己的
    /// 输出一起贴进 issue 里比对）。
    static func closeLogLine(isQuitting: Bool) -> String? {
        guard !isQuitting else { return nil }
        return "[dsh-web] 窗口已关闭，服务继续在后台运行（⌘Q 退出应用并停止服务）。"
    }

    func windowWillClose(_ notification: Notification) {
        guard let line = Self.closeLogLine(isQuitting: ServerManager.shared.isQuitting) else { return }
        ServerManager.shared.log(line)
    }
}
