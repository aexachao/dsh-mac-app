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
}
