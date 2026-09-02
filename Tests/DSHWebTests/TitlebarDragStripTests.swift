import AppKit
import Testing
@testable import DSHWeb

/// 红绿灯右边那条透明拖拽条。
///
/// 这一层踩过两次坑，都不在编译期暴露：
/// 1. 上一版把条子做成 SwiftUI 的 `.overlay(alignment: .top)`。`ignoresSafeArea` 只让内容
///    **画**出安全区，覆盖层的布局框仍从安全区顶边算起，于是条子整条落在红绿灯**下方**，
///    顶部那一段照旧归 `WKWebView` —— 表现是「应用打开后顶部拖不动」，而截图里看不出
///    任何异样（条子是透明的）。
/// 2. 再上一版让网页铺到 y=0、靠 `#root` 的 `padding-top` 让位，条子整条通吃鼠标事件。
///    padding 推得动的只有 `#root` 的子元素，dsh 右上角那两个图标是 `position: fixed`
///    （相对视口定位）纹丝不动地留在横带里，点击被条子吃掉。
///
/// 现在网页整体在标题栏下方，横带里不可能有页面内容，所以这里钉的是：条子在窗口顶部、
/// 整条都命中它、横带以下一点也不碰，以及高度归零时它彻底让开。
@MainActor
struct TitlebarDragStripTests {

    /// 构造一份与主窗口同款的容器（同一个 styleMask，含 fullSizeContentView）。
    private func makeWindow(stripHeight: CGFloat) -> (ContentContainerView, NSView) {
        let content = NSView(frame: .zero)
        let container = ContentContainerView(content: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: MainWindow.styleMask,
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.stripHeight = stripHeight
        container.layoutSubtreeIfNeeded()
        return (container, content)
    }

    private func strip(in container: ContentContainerView) -> TitlebarDragStrip? {
        container.subviews.compactMap { $0 as? TitlebarDragStrip }.first
    }

    /// `point` 用容器自己的坐标（左下原点）；`hitTest` 要的是父视图坐标。
    private func hitTest(_ container: ContentContainerView, at point: NSPoint) -> NSView? {
        container.hitTest(container.convert(point, to: container.superview))
    }

    @Test func stripCoversTheTopBandOfTheWindow() throws {
        let (container, _) = makeWindow(stripHeight: 32)
        let frame = try #require(strip(in: container)).frame
        // 顶边贴住容器顶边（contentView 在 fullSizeContentView 下覆盖整个窗口），
        // 高度就是标题栏实测高度，宽度铺满 —— 三者任一错位都表现为「某处拖不动」
        #expect(frame.maxY == container.bounds.maxY)
        #expect(frame.height == 32)
        #expect(frame.width == container.bounds.width)
        #expect(frame.minX == container.bounds.minX)
    }

    @Test func stripWinsHitTestingAcrossTheWholeBand() {
        // 横带里没有任何页面内容，整条归拖拽条 —— 包括最左、最右两端
        let (container, _) = makeWindow(stripHeight: 32)
        let y = container.bounds.maxY - 5
        for x in [CGFloat(1), 100, 400, 799] {
            #expect(hitTest(container, at: NSPoint(x: x, y: y)) is TitlebarDragStrip)
        }
    }

    @Test func stripDoesNotStealClicksBelowTheBand() {
        let (container, content) = makeWindow(stripHeight: 32)
        // 条子只该盖住横带那一段。多盖一点，页面顶部就被横向抢掉一条点击。
        let hit = hitTest(container, at: NSPoint(x: 100, y: container.bounds.maxY - 40))
        #expect(hit === content)
    }

    @Test func zeroHeightGivesTheBandBackToThePage() {
        // 进入全屏后标题栏收起、实测高度为 0：条子必须彻底让开
        //（isHidden 的视图不参与命中测试）
        let (container, content) = makeWindow(stripHeight: 0)
        #expect(strip(in: container)?.isHidden == true)
        let hit = hitTest(container, at: NSPoint(x: 100, y: container.bounds.maxY - 1))
        #expect(hit === content)
    }

    @Test func contentFillsTheContainer() {
        // 让位由 `NSHostingView` 的 safeArea 做（网页整体在标题栏下方），
        // 原生这层不缩内容 —— 缩了顶部会露出窗口底色
        let (container, content) = makeWindow(stripHeight: 32)
        #expect(content.frame == container.bounds)
    }

    @Test func stripTakesTheFirstClickOnAnInactiveWindow() {
        // 真标题栏在窗口不在前台时也能「一下就拖起来」；默认行为是第一次点击只激活窗口
        let (container, _) = makeWindow(stripHeight: 32)
        #expect(strip(in: container)?.acceptsFirstMouse(for: nil) == true)
    }

    @Test func heightReachesTheStripThroughWindowChrome() throws {
        // 高度从 `WindowChrome.setDragStripHeight` 一路到条子；断在中途就是窗口拖不动
        let (container, _) = makeWindow(stripHeight: 0)
        WindowChrome.setDragStripHeight(32, on: container.window)
        container.layoutSubtreeIfNeeded()
        #expect(try #require(strip(in: container)).frame.height == 32)
        WindowChrome.setDragStripHeight(0, on: container.window)
        #expect(strip(in: container)?.isHidden == true)
    }
}
