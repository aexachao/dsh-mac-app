import AppKit
import Testing
@testable import DSHWeb

/// 红绿灯右边那条透明拖拽条：网页铺满到 y=0 之后，窗口全靠它才拖得动。
///
/// 上一版把它做成 SwiftUI 的 `.overlay(alignment: .top)`。`ignoresSafeArea` 只让内容
/// **画**出安全区，覆盖层的布局框仍从安全区顶边算起，于是条子整条落在红绿灯**下方**，
/// 顶部那一段照旧归 `WKWebView` —— 表现就是「应用打开后顶部拖不动」，而编译期、
/// 截图里都看不出任何异样（条子是透明的）。所以这里钉两件事：条子在窗口顶部，
/// 且命中测试先到它。
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
        container.dragStripHeight = stripHeight
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
        // 高度就是让位高度，宽度铺满 —— 三者任一错位都表现为「某处拖不动」
        #expect(frame.maxY == container.bounds.maxY)
        #expect(frame.height == 32)
        #expect(frame.width == container.bounds.width)
        #expect(frame.minX == container.bounds.minX)
    }

    @Test func stripWinsHitTestingInsideTheBand() {
        let (container, _) = makeWindow(stripHeight: 32)
        let hit = hitTest(container, at: NSPoint(x: 100, y: container.bounds.maxY - 5))
        #expect(hit is TitlebarDragStrip)
    }

    @Test func stripDoesNotStealClicksBelowTheBand() {
        let (container, content) = makeWindow(stripHeight: 32)
        // 条子只该盖住让位那一段。多盖一点，页面顶部就被横向抢掉一条点击。
        let hit = hitTest(container, at: NSPoint(x: 100, y: container.bounds.maxY - 40))
        #expect(hit === content)
    }

    @Test func zeroHeightGivesTheBandBackToThePage() {
        // 有状态栏/安全模式横幅时不铺满，标题栏还露在上面，AppKit 自己就能拖，
        // 此时条子必须彻底让开（isHidden 的视图不参与命中测试）
        let (container, content) = makeWindow(stripHeight: 0)
        #expect(strip(in: container)?.isHidden == true)
        let hit = hitTest(container, at: NSPoint(x: 100, y: container.bounds.maxY - 1))
        #expect(hit === content)
    }

    @Test func contentFillsTheContainer() {
        // 让位是网页自己用 padding 做的，原生这层不能再缩内容 —— 否则顶部会露出窗口底色
        let (container, content) = makeWindow(stripHeight: 32)
        #expect(content.frame == container.bounds)
    }

    @Test func stripTakesTheFirstClickOnAnInactiveWindow() {
        // 真标题栏在窗口不在前台时也能「一下就拖起来」；默认行为是第一次点击只激活窗口
        let (container, _) = makeWindow(stripHeight: 32)
        #expect(strip(in: container)?.acceptsFirstMouse(for: nil) == true)
    }
}
