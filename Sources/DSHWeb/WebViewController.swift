import WebKit
import SwiftUI

/// 持有 WKWebView 并暴露加载/刷新操作（跨 SwiftUI 刷新周期保持实例）。
///
/// 性能说明：agent 流式输出时 WKWebView 的主线程被 DOM 更新占满，键盘事件
/// 排队导致输入延迟（Chrome 无此问题——WebKit 的合成器独立度不如 Chromium）。
/// 缓解：layer-backed 视图 + 防 App Nap 降频。
///
/// 导航策略：WKWebView 默认不处理链接——外链（跨域点击 / 新窗口）在系统
/// 浏览器打开，dsh 内部导航留在 WebView 内。
@MainActor
final class WebViewController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView

    /// 页面加载完成回调。
    ///
    /// 用回调而不是直接调 `ServerManager`：健康判定的依赖方向应当是「服务管理器观察
    /// WebView」，反过来会让 WebView 层依赖服务状态机，测试里也就没法单独构造它。
    var onPageLoaded: (() -> Void)?

    private var activityToken: NSObjectProtocol?

    /// 全局链接拦截脚本：捕获被前端 JS preventDefault 吞掉的外链点击
    ///（target=_blank 或跨域 <a>），转发原生打开系统浏览器。
    private static let linkBridgeScript = """
    (() => {
      const post = (url) => window.webkit.messageHandlers.openExternal.postMessage(String(url));
      const origOpen = window.open;
      window.open = (url, ...rest) => { if (url) post(url); return null; };
      document.addEventListener('click', (e) => {
        const a = e.target && e.target.closest ? e.target.closest('a') : null;
        if (a && a.href) {
          const href = a.href;
          const external = !href.startsWith(window.location.origin);
          if (a.target === '_blank' || external) {
            e.preventDefault();
            e.stopPropagation();
            post(href);
          }
        }
      }, true);
    })();
    """

    override init() {
        let configuration = WKWebViewConfiguration()
        // 注意：threadedScrollingEnabled 这类 private preference 在 macOS 26
        // 会抛 NSInvalidArgumentException 导致启动崩溃，不能使用。
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.linkBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "openExternal")
        webView.navigationDelegate = self
        webView.wantsLayer = true
        webView.allowsMagnification = false
    }

    // MARK: - WKScriptMessageHandler（注入脚本 → 外链打开）

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "openExternal",
              let urlString = message.body as? String,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        NSLog("[dsh-web] 打开外链: %@", urlString)
        NSWorkspace.shared.open(url)
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

    // MARK: - 导航策略

    /// 决定一次导航的去向。返回 true 表示留在 WebView 内。
    /// 纯函数便于单元测试。
    static func shouldStayInWebView(url: URL?, isUserInitiated: Bool, opensNewWindow: Bool, appHost: String) -> Bool {
        guard let url else { return true }
        // 新窗口（target=_blank）→ 外部打开
        if opensNewWindow { return false }
        // 用户点击的链接（非页面初始化/脚本导航）
        if isUserInitiated {
            // 同域（dsh 自身）→ WebView 内；跨域外链 → 系统浏览器
            return url.host == appHost
        }
        // 程序化导航（页面加载、表单提交、JS 内部路由）→ 留在 WebView
        return true
    }

    /// `decisionHandler` 的 `@MainActor @Sendable` 不能省。
    ///
    /// `WKNavigationDelegate` 全是 optional 方法，WebKit 用 `respondsToSelector:` 探测；
    /// Swift 只把签名与 SDK **完全一致**的方法暴露给 Objective-C。少了这两个属性，它就是
    /// 一个同名的普通 Swift 方法，selector 不存在，WebKit 探测失败后按默认策略放行——
    /// 外链于是在 WebView 里打开，`shouldStayInWebView` 一次也不会被调用。编译器对此
    /// 只给一句 "nearly matches optional requirement" 警告。
    /// 由 `navigationDelegateSelectorIsActuallyExposedToWebKit` 钉住。
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let stay = Self.shouldStayInWebView(
            url: navigationAction.request.url,
            isUserInitiated: navigationAction.navigationType == .linkActivated,
            opensNewWindow: navigationAction.targetFrame == nil,
            appHost: webView.url?.host ?? "127.0.0.1"
        )
        if !stay, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(stay ? .allow : .cancel)
    }

    /// 页面加载完成 —— 健康判定的两个必要条件之一（另一个是最短存活时长）。
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onPageLoaded?()
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
