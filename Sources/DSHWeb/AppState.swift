import Foundation
import Observation

/// 跨 UI 位置共享的应用界面状态（菜单栏与主界面都要读写）。
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    /// 日志侧栏是否展开。
    var showLogs = false

    /// WebView 控制器（菜单里的「重新加载页面」需要引用）。
    let webController = WebViewController()

    /// 服务管理器（菜单里的「在浏览器中打开」需要 URL）。
    let server = ServerManager.shared

    /// 顶部横带的两段颜色（页面实测后报上来）。nil = 还没量到，横带不画。
    ///
    /// 放在这里而不是直接改窗口：颜色是异步从网页那边到的，而横带挂在
    /// `NSWindow` 的 contentView 上、窗口引用只有 `ContentView` 有。
    /// 走一层可观察状态，跟横带高度同一条路，两者也就不会各自跑偏。
    var topBand: TopBandColors?

    private init() {
        // 页面加载完成是启动健康判定的必要条件之一，转交给服务管理器。
        webController.onPageLoaded = { [server] in
            server.notePageLoaded()
        }
        webController.onBandColors = { [weak self] colors in
            self?.topBand = colors
        }
    }
}
