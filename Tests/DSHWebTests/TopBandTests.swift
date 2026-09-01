import Foundation
import Testing
@testable import DSHWeb

/// 红绿灯所在那条横带：高度由窗口实测，两段颜色由网页实测后报上来。
///
/// 横带画在原生这一层（`TopBandView`），网页整体留在标题栏**下方** ——
/// 所以这里钉的是「颜色怎么从页面到 Swift」，以及那条通道两端认的是同一个名字。
@MainActor
struct TopBandTests {

    @Test func immersiveOnlyWhenNothingOfOursSitsOnTop() {
        // 横带只在网页确实顶在最上面时才染色：上面压着状态栏或安全模式横幅时，
        // 那一段画的不是网页，照页面的颜色染就是一条对不上的横带
        #expect(ContentView.isImmersive(needsHeader: false, isSafeMode: false) == true)
        #expect(ContentView.isImmersive(needsHeader: true, isSafeMode: false) == false)
        #expect(ContentView.isImmersive(needsHeader: false, isSafeMode: true) == false)
        #expect(ContentView.isImmersive(needsHeader: true, isSafeMode: true) == false)
    }

    // MARK: - 页面 → 原生的那条通道

    @Test func colourChannelNameIsSharedByScriptAndHandler() {
        // 脚本里的 postMessage 目标、注册的 handler 名、分发处的 case 是三处同一个
        // 字符串：错一个字就是「颜色永远报不上来」，编译期毫无迹象
        let name = WebViewController.bandColorsMessageName
        #expect(name.isEmpty == false)
        #expect(WebViewController.topBandProbeScript.contains("handlers.\(name)"))
    }

    @Test func measureCallMatchesTheInjectedFunctionName() {
        let name = WebViewController.measureFunctionName
        #expect(WebViewController.topBandProbeScript.contains("window.\(name) = measure"))
        #expect(WebViewController.measureTopBandScript.contains("window.\(name) && window.\(name)()"))
    }

    @Test func probeNormalisesColoursThroughACanvas() {
        let js = WebViewController.topBandProbeScript
        // 归一化交给浏览器：画一个像素再读回来，rgb()／rgba()／color(srgb …)／oklch(…)
        // 全都变成 sRGB 字节。在 Swift 里追 WebKit 的序列化格式迟早漏一种
        #expect(js.contains("getContext('2d'"))
        #expect(js.contains("getImageData(0, 0, 1, 1)"))
        // alpha 不足按「没量到」处理，继续往上找不透明的祖先
        #expect(js.contains("d[3] < 250 ? null"))
        #expect(js.contains("parentElement"))
    }

    @Test func probeDoesNotObserveTheStreamingDOM() {
        let js = WebViewController.topBandProbeScript
        // dsh 流式输出时整棵 DOM 每秒变几十次，subtree observer 正好加重输入延迟；
        // 触发点只能是这几个便宜的事件
        #expect(js.contains("MutationObserver") == false)
        #expect(js.contains("addEventListener('resize'"))
        #expect(js.contains("addEventListener('transitionend'"))
        // 不认 dsh 的任何选择器：只有 elementFromPoint
        #expect(js.contains("elementFromPoint"))
        #expect(js.contains("querySelector") == false)
        #expect(js.contains("data-slot") == false)
    }

    @Test func eventsOnlyScheduleAMeasurePerFrame() {
        let js = WebViewController.topBandProbeScript
        // 用户实测「侧栏展开／收起卡顿」的根因：`transitionend` 会冒泡，监听挂在
        // window 捕获阶段，一次折叠动的是整棵子树、每元素每属性各发一次事件，
        // 而 measure() 里两次 elementFromPoint、逐级 getComputedStyle、
        // getBoundingClientRect 全是强制同步布局。合并到一帧一次是唯一出路
        #expect(js.contains("requestAnimationFrame"))
        for event in ["resize", "transitionend", "click"] {
            #expect(js.contains("addEventListener('\(event)', schedule"))
            // 事件不能再直连 measure，否则这一道闸等于没有
            #expect(js.contains("addEventListener('\(event)', measure") == false)
        }
    }

    @Test func colourNormalisationIsCached() {
        let js = WebViewController.topBandProbeScript
        // getImageData 是 GPU→CPU 回读。页面上真出现过的颜色只有两三种，
        // 同一个字符串重复回读就是白扛动画那几帧
        #expect(js.contains("cache.has(color)"))
        #expect(js.contains("cache.set(color"))
        // 上限防呆：背景色过渡的中间态会造出一大批一次性字符串
        #expect(js.contains("cache.clear()"))
    }

    @Test func probeGivesUpSilentlyWhenEitherSideIsUnmeasurable() {
        let js = WebViewController.topBandProbeScript
        // 少一边就什么都不报：横带留在窗口底色上，跟加这条横带之前一模一样，
        // 而不是拿一个乱数染色
        #expect(js.contains("if (!left || !right) return;"))
    }

    // MARK: - 载荷解析（网页那边来的数据一律不可信）

    @Test func parseAcceptsAWellFormedPayload() throws {
        let colors = try #require(TopBandColors.parse([
            "left": [21, 21, 23] as [NSNumber],
            "right": [30, 31, 33] as [NSNumber],
            "split": NSNumber(value: 248),
        ] as [String: Any]))
        #expect(colors.left == TopBandColors.RGB(red: 21, green: 21, blue: 23))
        #expect(colors.right == TopBandColors.RGB(red: 30, green: 31, blue: 33))
        #expect(colors.split == 248)
    }

    @Test func parseRejectsAnythingMalformed() {
        let left = [21, 21, 23] as [NSNumber]
        // 任何一处不成形都退到「没量到」（横带露出窗口底色），而不是画一条错色的横带
        #expect(TopBandColors.parse("topBand") == nil)                       // 根本不是字典
        #expect(TopBandColors.parse(["left": left] as [String: Any]) == nil) // 少一边
        #expect(TopBandColors.parse([
            "left": left, "right": [1, 2] as [NSNumber], "split": NSNumber(value: 8),
        ] as [String: Any]) == nil)                                          // 通道数不对
        #expect(TopBandColors.parse([
            "left": left, "right": ["1", "2", "3"], "split": NSNumber(value: 8),
        ] as [String: Any]) == nil)                                          // 不是数字
        #expect(TopBandColors.parse([
            "left": left, "right": [0, 0, 300] as [NSNumber], "split": NSNumber(value: 8),
        ] as [String: Any]) == nil)                                          // 超出 0–255
        #expect(TopBandColors.parse([
            "left": left, "right": [0, 0, Double.nan] as [NSNumber], "split": NSNumber(value: 8),
        ] as [String: Any]) == nil)                                          // NaN
        #expect(TopBandColors.parse([
            "left": left, "right": left,
        ] as [String: Any]) == nil)                                          // 没有分界
        #expect(TopBandColors.parse([
            "left": left, "right": left, "split": NSNumber(value: -1),
        ] as [String: Any]) == nil)                                          // 分界为负
        #expect(TopBandColors.parse([
            "left": left, "right": left, "split": NSNumber(value: Double.infinity),
        ] as [String: Any]) == nil)                                          // 分界不是有限值
    }
}
