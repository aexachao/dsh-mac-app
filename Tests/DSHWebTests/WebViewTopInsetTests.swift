import Foundation
import Testing
@testable import DSHWeb

/// 网页铺满窗口顶部之后，红绿灯下面那一段由页面自己让位。
/// 让位靠一个 CSS 变量，样式规则与赋值脚本必须认同一个名字。
@MainActor
struct WebViewTopInsetTests {

    @Test func styleAndScriptShareTheSameVariable() {
        // 两边任意改一个名字都不会编译失败，只会让位失效 —— 所以钉住
        let name = WebViewController.topInsetVariable
        #expect(WebViewController.topInsetStyleScript.contains(name))
        #expect(WebViewController.topInsetScript(points: 32).contains(name))
    }

    @Test func styleTargetsTheStableRootSelector() {
        let css = WebViewController.topInsetStyleScript
        // #root 是 dsh 前端 index.html 里的挂载点 id（非 hash 类名）
        #expect(css.contains("#root{"))
        // border-box：padding 计入 height:100%，否则页面高出一段、多一条滚动
        #expect(css.contains("box-sizing:border-box"))
        #expect(css.contains("padding-top:var(\(WebViewController.topInsetVariable),0px)"))
    }

    @Test func scriptWritesWholePixels() {
        #expect(WebViewController.topInsetScript(points: 32).contains("'32px'"))
        // 缩放比例下标题栏高度可能是小数，取整避免写出 '31.5px' 这类值
        #expect(WebViewController.topInsetScript(points: 31.6).contains("'32px'"))
        #expect(WebViewController.topInsetScript(points: 0).contains("'0px'"))
        // 负值只能来自计算错误，夹到 0：让位为负会把页面顶出视口
        #expect(WebViewController.topInsetScript(points: -8).contains("'0px'"))
    }

    @Test func immersiveOnlyWhenNothingOfOursSitsOnTop() {
        // 铺满到 y=0 的前提是上方没有我们自己的控件，
        // 否则状态栏/安全模式横幅会被塞到红绿灯下面
        #expect(ContentView.isImmersive(needsHeader: false, isSafeMode: false) == true)
        #expect(ContentView.isImmersive(needsHeader: true, isSafeMode: false) == false)
        #expect(ContentView.isImmersive(needsHeader: false, isSafeMode: true) == false)
        #expect(ContentView.isImmersive(needsHeader: true, isSafeMode: true) == false)
    }

    // MARK: - 横带的两段颜色（左侧栏色 / 右会话区色）

    @Test func bandVariablesAreSharedByStyleAndProbe() {
        // 三个变量各在样式与实测脚本里出现一次，名字对不上就是「横带退回单色」，
        // 编译器不会说话，肉眼也只在特定主题下看得出来
        for name in [
            WebViewController.topBandLeftVariable,
            WebViewController.topBandRightVariable,
            WebViewController.topBandSplitVariable,
        ] {
            #expect(WebViewController.topInsetStyleScript.contains(name))
            #expect(WebViewController.topBandProbeScript.contains(name))
        }
    }

    @Test func bandFallsBackToTransparentWhenUnmeasured() {
        let css = WebViewController.topInsetStyleScript
        // 实测跑不起来（取不到元素、脚本被 CSP 挡掉）时三个变量都没赋值，
        // 于是回落到 transparent —— 露出 body 底色，也就是加横带之前的样子
        #expect(css.contains("var(\(WebViewController.topBandLeftVariable),transparent)"))
        #expect(css.contains("var(\(WebViewController.topBandRightVariable),transparent)"))
        // 横带高度跟让位高度是同一个变量：让位为 0 时 background-size 也是 0，什么都不画
        #expect(css.contains("background-size:100% var(\(WebViewController.topInsetVariable),0px)"))
        // 只有 background-* 抢 !important，background-color 留给 dsh 自己
        #expect(css.contains("background-image:") && css.contains(")!important"))
        #expect(css.contains("background-color") == false)
    }

    @Test func measureCallMatchesTheInjectedFunctionName() {
        let name = WebViewController.measureFunctionName
        #expect(WebViewController.topBandProbeScript.contains("window.\(name) = measure"))
        #expect(WebViewController.measureTopBandScript.contains("window.\(name) && window.\(name)()"))
    }

    @Test func probeDoesNotObserveTheStreamingDOM() {
        let js = WebViewController.topBandProbeScript
        // dsh 流式输出时整棵 DOM 每秒变几十次，subtree observer 正好加重输入延迟；
        // 触发点只能是这几个便宜的事件
        #expect(js.contains("MutationObserver") == false)
        #expect(js.contains("addEventListener('resize'"))
        #expect(js.contains("addEventListener('transitionend'"))
        // 不认 dsh 的任何选择器：只有挂载点 id 和 elementFromPoint
        #expect(js.contains("elementFromPoint"))
        #expect(js.contains("querySelector") == false)
        #expect(js.contains("data-slot") == false)
    }
}
