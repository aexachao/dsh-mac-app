import Foundation
import Testing
@testable import DSHWeb

// MARK: - 时限

/// `Deadline` 存在的唯一理由：有些同步工作会永远不返回（受 TCC 保护的目录里的
/// `open()` 就是），而调用方必须能继续走下去。所以只有两件事需要钉住——按时完成时
/// 拿到值，超时了拿到 nil，且两条路都不会把进程弄崩（continuation 恢复两次会崩）。
struct DeadlineTests {

    @Test func returnsValueWhenWorkFinishesInTime() async {
        let value = await Deadline.run(timeout: 5) { 42 }
        #expect(value == 42)
    }

    @Test func returnsNilWhenWorkOutlivesTheDeadline() async {
        // 卡住的那条线程被放弃，不影响本次返回——这正是设计意图。
        let value: Int? = await Deadline.run(timeout: 0.05) {
            Thread.sleep(forTimeInterval: 2)
            return 42
        }
        #expect(value == nil)
    }

    /// 超时之后被放弃的工作最终完成时，第二次 `resume` 必须被拦掉。
    /// 拦不掉不是返回错值，是直接崩进程——所以让这条路真的跑一遍。
    @Test func lateFinishAfterTimeoutDoesNotCrash() async {
        let value: Int? = await Deadline.run(timeout: 0.05) {
            Thread.sleep(forTimeInterval: 0.2)
            return 7
        }
        #expect(value == nil)
        // 留出时间让那条后台线程跑完并尝试第二次恢复。
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    @Test func doesNotBlockTheCaller() async {
        // 两次超时并发进行，总耗时应接近单次时限而不是两次之和。
        let start = Date()
        async let first: Int? = Deadline.run(timeout: 0.1) {
            Thread.sleep(forTimeInterval: 2)
            return 1
        }
        async let second: Int? = Deadline.run(timeout: 0.1) {
            Thread.sleep(forTimeInterval: 2)
            return 2
        }
        _ = await (first, second)
        #expect(Date().timeIntervalSince(start) < 1)
    }
}
