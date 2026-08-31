import Foundation

/// 给一段「可能永远不返回」的同步工作加上时限。
///
/// 为什么不用 `Task` + `cancel()`：取消是协作式的，而这里要防的恰好是不协作的那种——
/// 阻塞在内核 `open()` 里的线程收不到取消，也没有任何办法把它捞回来。能做的只有
/// 「不再等它」，并接受那条线程被放弃（进程退出时一起消失）。
///
/// 也不用 `withTaskGroup` 赛跑：任务组返回前会等所有子任务结束，而卡住的那个子任务
/// 永远不结束 —— 赛跑的写法本身会连带把调用方一起挂住。
enum Deadline {

    /// 在后台线程跑 `work`，最多等 `timeout` 秒。
    /// - Returns: 按时完成则是它的返回值；超时为 nil。
    static func run<T: Sendable>(
        timeout: TimeInterval,
        qos: DispatchQoS.QoSClass = .userInitiated,
        work: @escaping @Sendable () -> T
    ) async -> T? {
        let gate = OnlyOnce()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                let value = work()
                if gate.claim() { continuation.resume(returning: value) }
            }
            // 计时放在另一条队列上：`work` 卡死时它必须还能跑。
            DispatchQueue.global(qos: qos).asyncAfter(deadline: .now() + timeout) {
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }
}

/// 两条路只许一条兑现：continuation 恢复第二次会直接崩掉进程。
private final class OnlyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
