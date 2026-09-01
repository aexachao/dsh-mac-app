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
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.topBandProbeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "openExternal")
        configuration.userContentController.add(self, name: Self.bandColorsMessageName)
        webView.navigationDelegate = self
        webView.wantsLayer = true
        webView.allowsMagnification = false
    }

    // MARK: - 顶部横带（红绿灯所在那一段）

    /// 页面回报横带两段颜色用的消息通道名。
    /// 注册处、脚本里的 `postMessage`、分发处三边共用，由测试钉住。
    static let bandColorsMessageName = "topBandColors"

    /// 实测函数挂在 window 上的名字（脚本定义处与调用处共用）。
    static let measureFunctionName = "__harnessMeasureTopBand"

    /// 调用实测的一行 JS（函数还没注入时静默跳过）。
    static let measureTopBandScript = "window.\(measureFunctionName) && window.\(measureFunctionName)();"

    /// 横带两段颜色变化时回调。
    ///
    /// 与 `onPageLoaded` 同理用回调而不是直接改窗口：横带画在 `NSWindow` 的
    /// contentView 上，让 WebView 层拿窗口引用只会把两层缠在一起，也没法单测。
    var onBandColors: ((TopBandColors) -> Void)?

    /// 让页面重新量一次横带颜色。
    ///
    /// 页面自己会在尺寸变化、过渡结束、点击之后补量，这里是原生侧的显式入口：
    /// 刚拿到窗口引用、进出全屏、导航结束这些时刻页面收不到任何事件。
    func measureTopBand() {
        webView.evaluateJavaScript(Self.measureTopBandScript)
    }

    /// 实测横带两段颜色的脚本。
    ///
    /// 不认任何 dsh 的选择器：从页面左右两点各取一次 `elementFromPoint`，
    /// 向上找到第一个背景不透明的祖先，用它的颜色和右边界。
    /// dsh-desktop 走的是另一条路（它自己就是插件，能按 `data-slot` 精确取到侧栏），
    /// 我们只加载官方页面，能依赖的最稳的东西就是「左上角那一栏此刻画的是什么色」——
    /// 换了主题、折叠了侧栏、改了类名，这个测法都还成立。
    ///
    /// 失败方向是安全的：取不到就什么都不报，横带留在窗口底色上，
    /// 跟没有这条横带之前一模一样。
    ///
    /// 不用 MutationObserver：dsh 流式输出时整棵 DOM 每秒变几十次，
    /// 挂一个 subtree observer 正好加重 `WebViewController` 注释里那个输入延迟问题。
    /// 改用几个便宜的触发点：窗口尺寸变化、过渡动画结束（侧栏折叠是动画）、
    /// 点击，页面加载后几个延时补测，以及原生侧的显式调用（`measureTopBand`）。
    static let topBandProbeScript = """
    (() => {
      // 取色点固定在 y=44：页面整体在标题栏下方，44 已经落在 dsh 自己的界面里，
      // 又浅得不会撞上居中的弹窗
      const Y = 44;
      const canvas = document.createElement('canvas');
      canvas.width = 1; canvas.height = 1;
      const ctx = canvas.getContext('2d', { willReadFrequently: true });
      // 颜色归一化交给浏览器：画一个像素再读回来，rgb()／rgba()／color(srgb …)／
      // oklch(…) 全都变成 sRGB 字节。在 Swift 里追 WebKit 的序列化格式迟早漏一种，
      // 漏掉的那一种就是一条颜色不对的横带。alpha 不足按「没量到」处理，继续往上找
      const solid = (color) => {
        if (!ctx || !color || color === 'transparent') return null;
        ctx.clearRect(0, 0, 1, 1);
        ctx.fillStyle = color;
        ctx.fillRect(0, 0, 1, 1);
        const d = ctx.getImageData(0, 0, 1, 1).data;
        return d[3] < 250 ? null : [d[0], d[1], d[2]];
      };
      const surfaceAt = (x, y) => {
        let el = document.elementFromPoint(x, y);
        while (el && el !== document.documentElement) {
          const color = solid(getComputedStyle(el).backgroundColor);
          if (color) return { color, right: el.getBoundingClientRect().right };
          el = el.parentElement;
        }
        return null;
      };
      const measure = () => {
        const width = Math.round(window.innerWidth);
        if (width <= 0) return;
        const left = surfaceAt(12, Y);
        const right = surfaceAt(Math.max(0, width - 12), Y);
        if (!left || !right) return;
        const handlers = window.webkit && window.webkit.messageHandlers;
        const sink = handlers && handlers.\(bandColorsMessageName);
        if (!sink) return;
        sink.postMessage({
          left: left.color,
          right: right.color,
          split: Math.max(0, Math.min(Math.round(left.right), width))
        });
      };
      window.\(measureFunctionName) = measure;
      addEventListener('resize', measure);
      addEventListener('transitionend', measure, true);
      addEventListener('click', measure, true);
      addEventListener('load', () => [0, 300, 1200].forEach((d) => setTimeout(measure, d)));
    })();
    """

    // MARK: - WKScriptMessageHandler（注入脚本 → 外链打开 / 横带颜色回报）

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "openExternal": openExternal(message.body)
        case Self.bandColorsMessageName:
            // 解析失败就什么都不做：横带留在窗口底色上，而不是照一个乱数画色
            if let colors = TopBandColors.parse(message.body) { onBandColors?(colors) }
        default: break
        }
    }

    private func openExternal(_ body: Any) {
        guard let urlString = body as? String,
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
        // 导航会把上一份页面连同它的监听一起丢掉，加载完成后重新量一次横带颜色
        measureTopBand()
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
