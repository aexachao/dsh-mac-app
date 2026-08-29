import Foundation
import Testing
@testable import DSHWeb

// MARK: - 应用自重启

struct AppRelaunchTests {

    @Test func waitsForTheOldProcessToExitBeforeOpening() {
        // 固定 sleep 会和单实例锁打架：旧进程退得慢一点，新实例就会以为
        // 「已有实例在运行」然后自杀——用户看到的是切换语言后应用直接没了。
        let command = AppRelaunch.command(bundlePath: "/Applications/Harness.app", pid: 4242)
        #expect(command.contains("kill -0 4242"))
        #expect(command.contains("open "))
        let waitEnds = command.range(of: "done")
        let opens = command.range(of: "open ")
        #expect(waitEnds != nil)
        #expect(opens != nil)
        if let waitEnds, let opens { #expect(waitEnds.upperBound <= opens.lowerBound) }
    }

    @Test func waitIsBounded() {
        // 旧进程万一卡死不退，也必须收手去 open，而不是永远转圈
        let command = AppRelaunch.command(bundlePath: "/Applications/Harness.app", pid: 4242, maxTicks: 50)
        #expect(command.contains("50"))
    }

    @Test func opensEvenWhenTheWaitTimesOut() {
        // 循环与 open 之间必须是 `;` 而不是 `&&`：超时退出循环时条件为假，
        // 用 && 会连 open 都不执行。
        let command = AppRelaunch.command(bundlePath: "/Applications/Harness.app", pid: 1)
        #expect(command.contains("done; open") || command.contains("done ; open"))
    }

    @Test func quotesThePathSoSpacesSurvive() {
        let command = AppRelaunch.command(bundlePath: "/Users/me/My Apps/Harness.app", pid: 1)
        #expect(command.contains("\"/Users/me/My Apps/Harness.app\""))
    }

    @Test func escapesQuotesAndBackslashes() {
        // 路径由 Bundle 提供而非用户输入，但拼 shell 命令时逐一转义是唯一安全的默认
        let command = AppRelaunch.command(bundlePath: #"/tmp/we"ird\path.app"#, pid: 1)
        #expect(command.contains(#""/tmp/we\"ird\\path.app""#))
    }
}
