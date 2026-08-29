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

    private init() {
        // 页面加载完成是启动健康判定的必要条件之一，转交给服务管理器。
        webController.onPageLoaded = { [server] in
            server.notePageLoaded()
        }
    }
}
