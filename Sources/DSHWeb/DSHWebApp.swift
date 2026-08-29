import AppKit
import SwiftUI

/// 应用生命周期：手动创建窗口（NSWindow + NSHostingView），
/// 构建自定义菜单栏，退出前停止服务。
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 单实例锁，持锁到进程结束（delegate 与应用同寿）。
    private let instanceLock = InstanceLock()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 先抢锁：两个 Harness 同时跑会起两个 dsh 服务、抢同一份 ~/.dsh 状态、
        // 往同一个日志目录里交替写。抢不到就把已有实例叫到前台，自己退出。
        if case .heldByAnother(let pid) = instanceLock.acquire() {
            activateExistingInstance(pid: pid)
            // 直接 exit：此时还没建窗口、没起服务、没开日志文件，走 terminate 只会让
            // 这个多余的实例再去碰一遍共享状态。
            exit(0)
        }

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

    // MARK: - 单实例

    /// 把已在运行的那个实例叫到前台。
    ///
    /// 用户的动作是「打开 Harness」，得到的应该是一个 Harness 窗口——静悄悄地退出
    /// 会被当成「应用点了没反应」。找不到可激活的实例时（比如持锁者是 `swift run`
    /// 起的无 bundle 进程）才退回到弹窗说明，否则就真成了点了没反应。
    private func activateExistingInstance(pid: pid_t?) {
        if let running = runningSibling(pid: pid) {
            running.activate()
            return
        }
        let zh = MenuBuilder.current == .zh
        let alert = NSAlert()
        alert.messageText = zh ? "Harness 已在运行" : "Harness is already running"
        let holder = pid.map { zh ? "（进程 \($0)）" : " (process \($0))" } ?? ""
        alert.informativeText = zh
            ? "已有一个 Harness 实例\(holder)持有单实例锁，但无法切换到它的窗口。"
                + "请先退出那个实例，再重新打开。"
            : "Another Harness instance\(holder) holds the single-instance lock, "
                + "but its window could not be brought forward. Quit that instance first, then reopen."
        alert.alertStyle = .warning
        alert.addButton(withTitle: zh ? "好" : "OK")
        alert.runModal()
    }

    /// 找同 bundle 的另一个实例：先按锁文件里的 pid 精确定位，否则按 bundle id 找。
    private func runningSibling(pid: pid_t?) -> NSRunningApplication? {
        if let pid, let byPID = NSRunningApplication(processIdentifier: pid) {
            return byPID
        }
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .first { $0 != .current }
    }
}
