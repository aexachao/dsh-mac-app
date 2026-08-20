import WebKit
import SwiftUI

/// 持有 WKWebView 并暴露加载/刷新操作（跨 SwiftUI 刷新周期保持实例）。
///
/// 性能说明：agent 流式输出时 WKWebView 的主线程被 DOM 更新占满，键盘事件
/// 排队导致输入延迟（Chrome 无此问题——WebKit 的合成器独立度不如 Chromium）。
/// 这里做三件事缓解：
/// 1. layer-backed 视图（独立的 Core Animation 合成路径）；
/// 2. 线程化滚动偏好（把滚动/合成从主线程挪开，private preference）；
/// 3. 声明 userInitiated 活动，防止 App Nap 在窗口活跃时降频。
@MainActor
final class WebViewController {
    let webView: WKWebView

    private var activityToken: NSObjectProtocol?

    init() {
        let configuration = WKWebViewConfiguration()
        // 注意：threadedScrollingEnabled 这类 private preference 在 macOS 26
        // 会抛 NSInvalidArgumentException 导致启动崩溃，不能使用。
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.wantsLayer = true
        webView.allowsMagnification = false
    }

    /// 防 App Nap 降频（输入/交互期间保持满频）。
    func beginUserActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "dsh web 交互（输入/滚动）"
        )
    }

    func endUserActivity() {
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func reload() {
        webView.reload()
    }
}

/// WKWebView 的 SwiftUI 包装。
struct WebView: NSViewRepresentable {
    let controller: WebViewController

    func makeNSView(context: Context) -> WKWebView {
        controller.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
