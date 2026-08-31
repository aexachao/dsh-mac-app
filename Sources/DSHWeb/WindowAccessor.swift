import SwiftUI
import AppKit

/// 在视图挂载后拿到真实的 NSWindow（比 applicationDidFinishLaunching 时机可靠）。
struct WindowAccessor: NSViewRepresentable {
    var onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.onWindow(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 把窗口配置成「网页全屏」模式：标题栏透明、内容延伸到顶部、
/// 窗口背景染成深色 — 红绿灯区域与网页背景融为一体。
enum WindowChrome {
    @MainActor
    static func apply(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        // 兜底背景色取 dsh 深色主题的 body 基色（--dsw-static-neutral-bluish-950 = #151517）：
        // 网页铺满顶部后这块只在首帧、以及日志栏上方那一小段露出来，
        // 用它自己的颜色比用一个更偏蓝的近似色少一条可见接缝。
        window.backgroundColor = NSColor(srgbRed: 0x15 / 255, green: 0x15 / 255, blue: 0x17 / 255, alpha: 1)
        // 网页直接顶到 y=0，标题栏那条分隔线会横穿页面内容
        window.titlebarSeparatorStyle = .none
    }

    /// 标题栏占掉的高度（点）。这也正是 `NSHostingView` 给内容加的 safeArea 顶部内边距，
    /// 所以网页让位多少、拖拽条多高，都以它为准，不写死常量（实测 32pt，但由系统决定）。
    @MainActor
    static func titlebarHeight(of window: NSWindow?) -> CGFloat {
        guard let window else { return 0 }
        return max(0, window.frame.height - window.contentLayoutRect.height)
    }

    /// 设置红绿灯右边那条透明拖拽条的高度（0 = 不需要）。
    /// 找不到容器（理论上只有窗口被换过 contentView 才会）时什么都不做：
    /// 拖不动是可修的，崩掉不是。
    @MainActor
    static func setDragStripHeight(_ height: CGFloat, on window: NSWindow?) {
        (window?.contentView as? ContentContainerView)?.dragStripHeight = height
    }
}

/// 覆盖在网页顶部的透明拖拽条。
///
/// 网页铺满到 y=0 之后，那一段不再属于标题栏，鼠标事件全归 `WKWebView`：
/// 不补这一层，窗口就只剩边框可以拖动了。条子本身不画任何东西，
/// 下面透出的仍是 dsh 自己的页面背景。红绿灯按钮在窗口的标题栏容器里
/// （层级在 contentView 之上），不受这条影响。
final class TitlebarDragStrip: NSView {
    /// 窗口不在前台时，AppKit 默认把第一次点击只用来激活窗口。真标题栏是可以
    /// 「一下就拖起来」的，这里跟上。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            Self.performDoubleClickAction(on: window)
        } else {
            window.performDrag(with: event)
        }
    }

    /// 双击标题栏的行为跟随系统设置（NSGlobalDomain 的 AppleActionOnDoubleClick）。
    private static func performDoubleClickAction(on window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

/// 窗口的 contentView：SwiftUI 的内容视图 + 盖在最上层的那条拖拽条。
///
/// 拖拽条为什么落在 AppKit 层而不是 SwiftUI 的 `.overlay(alignment: .top)`：
/// `ignoresSafeArea` 只让内容**画**出安全区，覆盖层的布局框仍从安全区顶边算起，
/// 条子于是整条落在红绿灯下方那一段 —— 顶部这 32pt 照旧归 `WKWebView`（窗口拖不动），
/// 而页面里反倒被横向抢走一条点击。挂在 contentView 上就没有这层解释：几何直接是
/// 窗口坐标，层级也确定（最后一个子视图，命中测试先到它）。
final class ContentContainerView: NSView {
    private let content: NSView
    private let strip = TitlebarDragStrip()

    /// 拖拽条高度（点）。0 表示不需要 —— 此时标题栏还露在上面，AppKit 自己就能拖。
    var dragStripHeight: CGFloat = 0 {
        didSet {
            guard dragStripHeight != oldValue else { return }
            strip.isHidden = dragStripHeight <= 0
            needsLayout = true
        }
    }

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
        strip.isHidden = true
        addSubview(strip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现：容器只在代码里构造") }

    override func layout() {
        super.layout()
        content.frame = bounds
        strip.frame = NSRect(
            x: bounds.minX,
            y: bounds.maxY - dragStripHeight,
            width: bounds.width,
            height: dragStripHeight
        )
    }
}
