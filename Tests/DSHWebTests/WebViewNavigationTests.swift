import Foundation
import Testing
@testable import DSHWeb

@MainActor
struct WebViewNavigationTests {

    @Test func externalLinkOpensInBrowser() {
        // 用户点击跨域链接 → 外部打开（不在 WebView）
        let url = URL(string: "https://github.com/deepseek-ai/dsh")!
        let stay = WebViewController.shouldStayInWebView(
            url: url, isUserInitiated: true, opensNewWindow: false, appHost: "127.0.0.1")
        #expect(stay == false)
    }

    @Test func sameHostLinkStaysInWebView() {
        // 用户点击 dsh 自身链接（同域）→ 留在 WebView
        let url = URL(string: "http://127.0.0.1:3080/some/internal/route")!
        let stay = WebViewController.shouldStayInWebView(
            url: url, isUserInitiated: true, opensNewWindow: false, appHost: "127.0.0.1")
        #expect(stay == true)
    }

    @Test func newWindowLinkOpensInBrowser() {
        // target=_blank（新窗口）→ 外部打开，即使同域
        let url = URL(string: "http://127.0.0.1:3080/docs")!
        let stay = WebViewController.shouldStayInWebView(
            url: url, isUserInitiated: true, opensNewWindow: true, appHost: "127.0.0.1")
        #expect(stay == false)
    }

    @Test func programmaticNavigationStaysInWebView() {
        // 页面初始化/JS 内部路由（非用户点击）→ 留在 WebView
        let url = URL(string: "http://127.0.0.1:3080/")!
        let stay = WebViewController.shouldStayInWebView(
            url: url, isUserInitiated: false, opensNewWindow: false, appHost: "127.0.0.1")
        #expect(stay == true)
    }

    @Test func nilUrlStaysInWebView() {
        // 无 URL（about:blank 等）→ 留在 WebView
        let stay = WebViewController.shouldStayInWebView(
            url: nil, isUserInitiated: true, opensNewWindow: false, appHost: "127.0.0.1")
        #expect(stay == true)
    }

    @Test func externalProgrammaticRedirectStaysInWebView() {
        // 程序化跳转到外域（如 OAuth 回调由 JS 触发）→ 留在 WebView（避免拦截脚本跳转）
        let url = URL(string: "https://example.com/callback")!
        let stay = WebViewController.shouldStayInWebView(
            url: url, isUserInitiated: false, opensNewWindow: false, appHost: "127.0.0.1")
        #expect(stay == true)
    }

    /// 上面六个测试全过、导航策略却完全没生效过——因为它们只测纯函数，
    /// 谁都没验证过 WebKit 真的会来调那个委托方法。
    ///
    /// `WKNavigationDelegate` 的方法是 optional 的，WebKit 通过 `respondsToSelector:`
    /// 探测。Swift 只把**签名完全一致**的方法暴露给 Objective-C；decisionHandler
    /// 少了 `@MainActor @Sendable` 就变成另一个方法，selector 不存在，WebKit 探测失败
    /// 后走默认放行——外链在 WebView 内打开，`shouldStayInWebView` 一次也不会被调用。
    /// 编译器只给一句 "nearly matches optional requirement" 的警告。
    @Test func navigationDelegateSelectorIsActuallyExposedToWebKit() {
        let controller = WebViewController()
        for name in [
            "webView:decidePolicyForNavigationAction:decisionHandler:",
            "webView:didFinishNavigation:",
        ] {
            #expect(controller.responds(to: NSSelectorFromString(name)),
                    "WebKit 探测不到 \(name)，该委托方法永远不会被调用")
        }
    }

    @Test func scriptMessageHandlerSelectorIsActuallyExposed() {
        // 注入脚本靠这个 selector 把外链送回原生；签名不匹配就静默失效。
        let controller = WebViewController()
        #expect(controller.responds(
            to: NSSelectorFromString("userContentController:didReceiveScriptMessage:")))
    }
}
