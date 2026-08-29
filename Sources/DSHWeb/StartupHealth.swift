import Foundation

/// 判定一次启动到底「有没有真的跑起来」。
///
/// 为什么需要：端口能连上只说明 dsh 开始监听了，它之后仍可能在插件初始化阶段崩溃，
/// 或者页面永远加载不出来。只看端口的话，界面会先显示成功、几秒后再跳成失败，
/// 而「连续启动失败」这个信号（安全模式的触发条件）根本无从统计。
///
/// 两个必要条件：WebView 报告页面加载完成，且进程从启动起存活满 `minimumUptime`。
/// 全部做成纯函数，时序组合可以在单测里一次钉死。
enum StartupHealth {

    /// 判定阈值。
    struct Policy: Sendable {
        /// 最短存活时长：页面加载完成后还要活过这么久才算健康。
        let minimumUptime: TimeInterval
        /// 页面加载超时：超过这么久还没加载完成就判不健康。
        let pageLoadTimeout: TimeInterval
        /// 连续多少次不健康启动后进入安全模式。
        let unhealthyStreakForSafeMode: Int

        init(minimumUptime: TimeInterval, pageLoadTimeout: TimeInterval, unhealthyStreakForSafeMode: Int) {
            self.minimumUptime = minimumUptime
            self.pageLoadTimeout = pageLoadTimeout
            self.unhealthyStreakForSafeMode = unhealthyStreakForSafeMode
        }

        /// 生产默认：存活 20s、页面 60s 内加载完成、连续 3 次不健康进安全模式。
        ///
        /// 20s 覆盖 dsh 插件初始化的整个尾段（崩溃基本都发生在这之前）；60s 留足首次
        /// 加载的余量；3 次而不是 2 次，是因为偶发的一次端口抢占不该把用户推进安全模式。
        static let standard = Policy(minimumUptime: 20, pageLoadTimeout: 60, unhealthyStreakForSafeMode: 3)
    }

    /// 一次启动过程中观察到的事实。
    struct Observation: Equatable {
        /// 进程启动时刻。
        var spawnedAt: Date
        /// WebView 报告页面加载完成的时刻；nil 表示还没加载完成。
        var pageLoadedAt: Date?
        /// 进程退出时刻；nil 表示还在运行。
        var exitedAt: Date?
        var exitStatus: Int32?

        init(spawnedAt: Date, pageLoadedAt: Date? = nil, exitedAt: Date? = nil, exitStatus: Int32? = nil) {
            self.spawnedAt = spawnedAt
            self.pageLoadedAt = pageLoadedAt
            self.exitedAt = exitedAt
            self.exitStatus = exitStatus
        }
    }

    /// 判定结果。
    enum Outcome: Equatable {
        /// 还在观察窗口内，不下结论。
        case pending
        /// 页面加载完成且存活达标。
        case healthy
        /// 启动没成功，附可读原因。
        case unhealthy(String)

        var isUnhealthy: Bool {
            if case .unhealthy = self { return true }
            return false
        }

        /// 不健康时的原因文案；其它状态为 nil。
        var reason: String? {
            if case .unhealthy(let reason) = self { return reason }
            return nil
        }
    }

    /// 依据观察到的事实给出判定。
    ///
    /// 判定顺序是有意为之：先看「是否已达标」，再看退出。这样一个健康跑了一整天之后
    /// 才退出的进程不会被算成启动失败——否则用户每天正常退出应用都会把安全模式的
    /// 计数器往上推。
    static func evaluate(_ observation: Observation, now: Date, policy: Policy) -> Outcome {
        let uptime = (observation.exitedAt ?? now).timeIntervalSince(observation.spawnedAt)

        if observation.pageLoadedAt != nil, uptime >= policy.minimumUptime {
            return .healthy
        }
        if observation.exitedAt != nil {
            let status = observation.exitStatus.map(String.init) ?? "未知"
            return .unhealthy("启动 \(Int(uptime))s 内退出（exit \(status)）")
        }
        if observation.pageLoadedAt == nil,
           now.timeIntervalSince(observation.spawnedAt) > policy.pageLoadTimeout {
            return .unhealthy("页面 \(Int(policy.pageLoadTimeout))s 未加载完成")
        }
        return .pending
    }

    /// 连续不健康次数的推进规则。`pending` 不动计数——判定还没结束。
    static func nextStreak(current: Int, outcome: Outcome) -> Int {
        switch outcome {
        case .healthy: return 0
        case .unhealthy: return current + 1
        case .pending: return current
        }
    }

    /// 是否该进入安全模式。
    static func shouldEnterSafeMode(streak: Int, policy: Policy = .standard) -> Bool {
        streak >= policy.unhealthyStreakForSafeMode
    }
}

/// 连续不健康启动次数的持久化。
///
/// 必须存盘：崩溃后进程就没了，内存里的计数一起消失，「连续三次失败进安全模式」
/// 就永远触发不了。
struct UnhealthyStreakStore {

    private static let key = "unhealthyStartStreak"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 当前连续不健康次数。
    var value: Int {
        defaults.integer(forKey: Self.key)
    }

    /// 按判定结果更新计数。
    func record(_ outcome: StartupHealth.Outcome) {
        let next = StartupHealth.nextStreak(current: value, outcome: outcome)
        defaults.set(next, forKey: Self.key)
    }

    /// 显式清零（用户手动退出安全模式时用）。
    func reset() {
        defaults.set(0, forKey: Self.key)
    }
}
