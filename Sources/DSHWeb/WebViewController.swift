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
            WKUserScript(source: Self.topInsetStyleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.topBandProbeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "openExternal")
        webView.navigationDelegate = self
        webView.wantsLayer = true
        webView.allowsMagnification = false
    }

    // MARK: - 顶部让位（红绿灯下方那一段）

    /// 网页顶部给红绿灯让出的高度（点）。由 `ContentView` 按标题栏实际高度设置。
    private(set) var topInset: CGFloat = 0

    /// 让位高度写在这个 CSS 变量上，样式规则和赋值脚本共用它。
    static let topInsetVariable = "--harness-top-inset"

    /// 让位出来的那条横带，左右两段各自的颜色与分界位置。
    ///
    /// dsh 的界面是分栏的（侧栏一种底色、会话区另一种），而 `body` 只有一种。
    /// 只靠 `#root` 的 padding 让位，露出来的是 `body` 的底色 —— 侧栏上方那一段
    /// 因此比侧栏自己深一号，看着仍像我们自己的一条导航栏。这三个变量把横带
    /// 画成「左段用侧栏的色、右段用会话区的色」，分界线由脚本实测。
    static let topBandLeftVariable = "--harness-band-left"
    static let topBandRightVariable = "--harness-band-right"
    static let topBandSplitVariable = "--harness-band-split"

    /// 顶部让位样式。
    ///
    /// 页面铺到 y=0 之后，dsh 自己的顶栏（`deepseek HARNESS` 字样）会压在红绿灯下面，
    /// 所以由我们给它加一段 `padding-top`；那一段的填色是 `#root` 自己的
    /// `background-image`（`background-origin` 默认就是 padding box，所以渐变正好
    /// 从 y=0 开始，高度等于让位高度）。三个颜色变量未赋值时取 `transparent`，
    /// 于是退化成「露出 body 底色」，也就是实测脚本没跑起来时的旧行为。
    ///
    /// 用 `#root` 自己的背景而不是叠一个固定定位的条：那样的条要么被 dsh 的
    /// 弹窗盖住、要么反过来把弹窗顶部切掉，取决于双方的 z-index —— 而背景永远
    /// 在自己的子元素下面，没有这个问题。`!important` 只加在三条
    /// `background-*` 上，`background-color` 留给 dsh，两者本就叠在一起。
    ///
    /// 选 `#root`：那是 dsh 前端 `index.html` 里写死的挂载点 id，
    /// 不是构建生成的 hash 类名，跨版本稳定。`border-box` 保证 `height:100%`
    /// 仍是视口高度（padding 计入其中），不会多出一条滚动。
    ///
    /// 非 private：几个变量名在样式与赋值脚本两边各出现一次，
    /// 由 `WebViewTopInsetTests` 钉住两处一致（改一边而漏另一边不会报编译错误，
    /// 只是让位失效、页面重新钻到红绿灯下面）。
    static let topInsetStyleScript = """
    (() => {
      const style = document.createElement('style');
      style.id = 'harness-top-inset';
      style.textContent = '#root{box-sizing:border-box;padding-top:var(\(topInsetVariable),0px);'
        + 'background-image:linear-gradient(to right,'
        + 'var(\(topBandLeftVariable),transparent) 0 var(\(topBandSplitVariable),0px),'
        + 'var(\(topBandRightVariable),transparent) var(\(topBandSplitVariable),0px))!important;'
        + 'background-repeat:no-repeat!important;'
        + 'background-size:100% var(\(topInsetVariable),0px)!important}';
      (document.head || document.documentElement).appendChild(style);
    })();
    """

    /// 实测横带两段颜色的脚本。
    ///
    /// 不认任何 dsh 的选择器：从让位高度**下方**的左右两点各取一次
    /// `elementFromPoint`，向上找到第一个背景不透明的祖先，用它的颜色和右边界。
    /// dsh-desktop 走的是另一条路（它自己就是插件，能按 `data-slot` 精确取到侧栏），
    /// 我们只加载官方页面，能依赖的最稳的东西就是「左上角那一栏此刻画的是什么色」——
    /// 换了主题、折叠了侧栏、改了类名，这个测法都还成立。
    ///
    /// 失败方向是安全的：取不到就不赋值，横带退回单色，跟改动之前一模一样。
    ///
    /// 不用 MutationObserver：dsh 流式输出时整棵 DOM 每秒变几十次，
    /// 挂一个 subtree observer 正好加重 `WebViewController` 注释里那个输入延迟问题。
    /// 改用几个便宜的触发点：窗口尺寸变化、过渡动画结束（侧栏折叠是动画）、
    /// 页面加载后几个延时补测，以及原生侧改让位高度时的显式调用。
    static let topBandProbeScript = """
    (() => {
      const LEFT = '\(topBandLeftVariable)', RIGHT = '\(topBandRightVariable)', SPLIT = '\(topBandSplitVariable)';
      const opaque = (color) => color && color !== 'transparent' && !/,\\s*0\\s*\\)$/.test(color);
      const surfaceAt = (x, y) => {
        let el = document.elementFromPoint(x, y);
        while (el && el !== document.documentElement) {
          const color = getComputedStyle(el).backgroundColor;
          if (opaque(color)) return { color, right: el.getBoundingClientRect().right };
          el = el.parentElement;
        }
        return null;
      };
      const measure = () => {
        const root = document.getElementById('root');
        const style = document.documentElement.style;
        const inset = root ? parseFloat(getComputedStyle(root).paddingTop) || 0 : 0;
        if (inset <= 0) {
          style.removeProperty(LEFT); style.removeProperty(RIGHT); style.removeProperty(SPLIT);
          return;
        }
        const y = inset + 12;
        const left = surfaceAt(12, y);
        const right = surfaceAt(Math.max(0, window.innerWidth - 12), y);
        if (!left || !right) return;
        style.setProperty(LEFT, left.color);
        style.setProperty(RIGHT, right.color);
        style.setProperty(SPLIT, Math.max(0, Math.round(Math.min(left.right, window.innerWidth))) + 'px');
      };
      window.\(measureFunctionName) = measure;
      addEventListener('resize', measure);
      addEventListener('transitionend', measure, true);
      addEventListener('load', () => [0, 300, 1200].forEach((d) => setTimeout(measure, d)));
    })();
    """

    /// 实测函数挂在 window 上的名字（脚本定义处与调用处共用）。
    static let measureFunctionName = "__harnessMeasureTopBand"

    /// 调用实测的一行 JS（函数还没注入时静默跳过）。
    static let measureTopBandScript = "window.\(measureFunctionName) && window.\(measureFunctionName)();"

    /// 生成写入让位高度的 JS。纯函数，便于把「变量名两处一致」钉在测试里。
    static func topInsetScript(points: CGFloat) -> String {
        let px = max(0, Int(points.rounded()))
        return "document.documentElement.style.setProperty('\(topInsetVariable)', '\(px)px');"
    }

    /// 设置让位高度；页面可能还没加载完，值存下来在 `didFinish` 里再补一次。
    func setTopInset(_ points: CGFloat) {
        topInset = points
        applyTopInset()
    }

    private func applyTopInset() {
        // 顺序不能反：横带的高度取自 `#root` 的 padding，先写让位高度，再去实测
        webView.evaluateJavaScript(Self.topInsetScript(points: topInset) + Self.measureTopBandScript)
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
        // 让位高度写在 documentElement 的 inline style 上，导航会把它清掉，每次加载后补回来
        applyTopInset()
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
