import Foundation
import Testing
@testable import DSHWeb

// MARK: - 启动健康判定

/// 「端口能连上」不等于「服务真的能用」：dsh 监听后仍可能在插件初始化阶段崩溃，
/// 或页面永远加载不出来。判定逻辑做成纯函数，便于把各种时序组合一次钉死。
struct StartupHealthTests {

    private let policy = StartupHealth.Policy(minimumUptime: 20, pageLoadTimeout: 60, unhealthyStreakForSafeMode: 3)
    private let spawned = Date(timeIntervalSince1970: 1_787_000_000)

    private func observation(
        pageLoadedAfter: TimeInterval? = nil,
        exitedAfter: TimeInterval? = nil,
        exitStatus: Int32 = 1
    ) -> StartupHealth.Observation {
        StartupHealth.Observation(
            spawnedAt: spawned,
            pageLoadedAt: pageLoadedAfter.map { spawned.addingTimeInterval($0) },
            exitedAt: exitedAfter.map { spawned.addingTimeInterval($0) },
            exitStatus: exitedAfter == nil ? nil : exitStatus
        )
    }

    private func evaluate(_ o: StartupHealth.Observation, after seconds: TimeInterval) -> StartupHealth.Outcome {
        StartupHealth.evaluate(o, now: spawned.addingTimeInterval(seconds), policy: policy)
    }

    // MARK: 观察窗口内还不下结论

    @Test func staysPendingBeforePageLoads() {
        #expect(evaluate(observation(), after: 5) == .pending)
    }

    @Test func staysPendingUntilMinimumUptimeElapses() {
        // 页面已加载但只活了 10s：插件崩溃通常正好发生在这个窗口里
        #expect(evaluate(observation(pageLoadedAfter: 3), after: 10) == .pending)
    }

    // MARK: 健康

    @Test func healthyOncePageLoadedAndUptimeReached() {
        #expect(evaluate(observation(pageLoadedAfter: 3), after: 20) == .healthy)
    }

    @Test func healthyStaysHealthyLater() {
        #expect(evaluate(observation(pageLoadedAfter: 3), after: 600) == .healthy)
    }

    // MARK: 不健康

    @Test func earlyExitIsUnhealthyEvenAfterPageLoaded() {
        // 页面出来过又崩掉，正是插件导致崩溃的典型形态
        let outcome = evaluate(observation(pageLoadedAfter: 3, exitedAfter: 8), after: 9)
        #expect(outcome.isUnhealthy)
        #expect(outcome.reason?.contains("退出") == true)
    }

    @Test func earlyExitWithoutPageLoadIsUnhealthy() {
        #expect(evaluate(observation(exitedAfter: 2), after: 3).isUnhealthy)
    }

    @Test func exitAfterHealthyDoesNotCountAsFailedStart() {
        // 已经健康跑了很久之后退出属于运行期问题，不能算「启动失败」——
        // 否则用户正常用一整天再退出，也会把安全模式的计数器推上去
        let o = StartupHealth.Observation(
            spawnedAt: spawned,
            pageLoadedAt: spawned.addingTimeInterval(3),
            exitedAt: spawned.addingTimeInterval(3600),
            exitStatus: 0
        )
        #expect(StartupHealth.evaluate(o, now: spawned.addingTimeInterval(3601), policy: policy) == .healthy)
    }

    @Test func pageLoadTimeoutIsUnhealthy() {
        let outcome = evaluate(observation(), after: 61)
        #expect(outcome.isUnhealthy)
        #expect(outcome.reason?.contains("页面") == true)
    }

    @Test func exitStatusAppearsInReason() {
        let outcome = evaluate(observation(exitedAfter: 2, exitStatus: 7), after: 3)
        #expect(outcome.reason?.contains("7") == true)
    }

    // MARK: 连续不健康计数

    @Test func healthyResetsStreak() {
        #expect(StartupHealth.nextStreak(current: 2, outcome: .healthy) == 0)
    }

    @Test func unhealthyIncrementsStreak() {
        #expect(StartupHealth.nextStreak(current: 2, outcome: .unhealthy("崩了")) == 3)
    }

    @Test func pendingLeavesStreakUntouched() {
        #expect(StartupHealth.nextStreak(current: 2, outcome: .pending) == 2)
    }

    @Test func safeModeTriggersAtThreshold() {
        #expect(StartupHealth.shouldEnterSafeMode(streak: 2, policy: policy) == false)
        #expect(StartupHealth.shouldEnterSafeMode(streak: 3, policy: policy))
        #expect(StartupHealth.shouldEnterSafeMode(streak: 9, policy: policy))
    }

    // MARK: 默认策略

    @Test func standardPolicyIsInternallyConsistent() {
        let standard = StartupHealth.Policy.standard
        // 最短存活必须短于页面加载超时，否则页面还没判超时就先被判健康
        #expect(standard.minimumUptime < standard.pageLoadTimeout)
        #expect(standard.unhealthyStreakForSafeMode >= 2)
    }
}

// MARK: - 连续不健康次数的持久化

/// 崩溃后进程就没了，计数只能存盘——否则「连续三次失败进安全模式」永远触发不了。
struct UnhealthyStreakStoreTests {

    private func store() -> (UnhealthyStreakStore, UserDefaults) {
        let suite = "harness-health-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (UnhealthyStreakStore(defaults: defaults), defaults)
    }

    @Test func startsAtZero() {
        let (subject, _) = store()
        #expect(subject.value == 0)
    }

    @Test func recordsUnhealthyCumulatively() {
        let (subject, _) = store()
        subject.record(.unhealthy("一"))
        subject.record(.unhealthy("二"))
        #expect(subject.value == 2)
    }

    @Test func healthyClearsTheStreak() {
        let (subject, _) = store()
        subject.record(.unhealthy("一"))
        subject.record(.healthy)
        #expect(subject.value == 0)
    }

    @Test func pendingIsNotPersisted() {
        let (subject, _) = store()
        subject.record(.unhealthy("一"))
        subject.record(.pending)
        #expect(subject.value == 1)
    }

    @Test func resetClearsExplicitly() {
        let (subject, _) = store()
        subject.record(.unhealthy("一"))
        subject.reset()
        #expect(subject.value == 0)
    }

    @Test func survivesANewStoreOverTheSameDefaults() {
        let (subject, defaults) = store()
        subject.record(.unhealthy("一"))
        #expect(UnhealthyStreakStore(defaults: defaults).value == 1)
    }
}
