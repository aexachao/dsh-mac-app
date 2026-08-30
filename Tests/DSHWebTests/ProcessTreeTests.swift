import Foundation
import Testing
@testable import DSHWeb

@Suite("进程树")
struct ProcessTreeTests {

    @Test("解析 ps 输出：多余空格、缺列、非数字都不影响其余行")
    func parsesPSOutput() {
        let output = """
            1     0
          683     1
         1024   683
        garbage line
          999
        """
        let pairs = ProcessTree.parse(output)
        // pid 1 被排除（它不可能是我们的子孙，且 ppid 自环会污染遍历）
        #expect(pairs.count == 2)
        #expect(pairs.contains { $0.pid == 683 && $0.ppid == 1 })
        #expect(pairs.contains { $0.pid == 1024 && $0.ppid == 683 })
    }

    @Test("子孙按深度倒序：叶子在前")
    func descendantsAreDeepestFirst() {
        let pairs: [(pid: Int32, ppid: Int32)] = [
            (100, 1),      // root
            (200, 100),    // 子
            (201, 100),    // 子
            (300, 200),    // 孙
            (400, 300),    // 曾孙
            (500, 999),    // 无关
        ]
        let found = ProcessTree.descendants(of: 100, in: pairs)
        #expect(Set(found) == [200, 201, 300, 400])
        // 顺序是终止顺序：先收叶子，再收派生它的那一层
        #expect(found.firstIndex(of: 400)! < found.firstIndex(of: 300)!)
        #expect(found.firstIndex(of: 300)! < found.firstIndex(of: 200)!)
        #expect(!found.contains(100))
        #expect(!found.contains(500))
    }

    @Test("环不会让遍历转不出来")
    func cyclesTerminate() {
        let pairs: [(pid: Int32, ppid: Int32)] = [
            (100, 1),
            (200, 100),
            (300, 200),
            (200, 300),   // 环
        ]
        let found = ProcessTree.descendants(of: 100, in: pairs)
        #expect(Set(found) == [200, 300])
    }

    @Test("root 是 0/1 时一律返回空——参数失误不该变成杀掉整台机器")
    func refusesInitProcesses() {
        let pairs: [(pid: Int32, ppid: Int32)] = [(100, 1), (200, 100), (300, 0)]
        #expect(ProcessTree.descendants(of: 1, in: pairs).isEmpty)
        #expect(ProcessTree.descendants(of: 0, in: pairs).isEmpty)
    }

    @Test("真实进程表里能看到自己，且父进程合法")
    func snapshotSeesSelf() {
        let pairs = ProcessTree.snapshot()
        #expect(pairs.count > 1)
        let me = getpid()
        let mine = pairs.first { $0.pid == me }
        #expect(mine != nil)
        #expect(mine?.ppid ?? 0 > 0)
    }

    @Test("真实的孙进程能被枚举出来")
    func findsRealGrandchild() throws {
        // sh 自己派生一个 sleep：孙进程正是修这个 bug 的对象
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "/bin/sleep 30 & wait"]
        try sh.run()
        defer {
            ProcessTree.terminate([sh.processIdentifier], grace: 0.5)
            sh.waitUntilExit()
        }

        // 给 sh 一点时间把 sleep 派生出来
        var found: [Int32] = []
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.05)
            found = ProcessTree.descendants(of: sh.processIdentifier)
            if !found.isEmpty { break }
        }
        #expect(!found.isEmpty)

        // 收树，孙进程必须真的没了
        ProcessTree.terminate(found, grace: 1.0)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(found.allSatisfy { kill($0, 0) != 0 })
    }

    @Test("不理 SIGTERM 的进程会被 SIGKILL 收掉，并出现在返回值里")
    func escalatesToSIGKILL() throws {
        let stubborn = Process()
        stubborn.executableURL = URL(fileURLWithPath: "/bin/sh")
        stubborn.arguments = ["-c", "trap '' TERM; while :; do sleep 0.2; done"]
        try stubborn.run()
        let pid = stubborn.processIdentifier
        Thread.sleep(forTimeInterval: 0.3)   // 等 trap 装上

        let forced = ProcessTree.terminate([pid], grace: 0.3)
        stubborn.waitUntilExit()
        #expect(forced == [pid])
        #expect(kill(pid, 0) != 0)
    }

    @Test("空名单与 pid<=1 直接返回，不发任何信号")
    func ignoresEmptyAndInitPIDs() {
        #expect(ProcessTree.terminate([], grace: 0.1).isEmpty)
        #expect(ProcessTree.terminate([0, 1], grace: 0.1).isEmpty)
    }
}
