import Foundation

/// 进程树：谁是谁的子孙，以及怎么把一整棵树收干净。
///
/// 只终止直接子进程是不够的。dsh 的插件会自己 spawn 常驻进程（实测 dsh-doctor 的
/// supervisor），我们那个 node 一死，它们就被 launchd 收养，于是活过应用退出：
/// 下次启动被判成「端口已被占用」，从 dmg / translocation 目录启动时那个挂载点还
/// 一直被占着卸不掉。
///
/// 所有权判据是**父子关系**，不是命令行特征。孙进程是我们自己那个 node 派生出来的，
/// 这件事本身就是证明，不需要再猜它长什么样——`DSHProcessIdentity` 那套猜测是给
/// 「端口上有个陌生进程」用的，那种场合恰恰没有父子关系可依赖。
enum ProcessTree {

    /// 解析 `ps -Ao pid=,ppid=` 的输出。
    ///
    /// 解析不出来的行直接丢弃：这是诊断输入，宁可少收一个进程，也不能让一行怪格式
    /// 把整个退出流程搞崩。
    static func parse(_ output: String) -> [(pid: Int32, ppid: Int32)] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2,
                  let pid = Int32(fields[0]), let ppid = Int32(fields[1]),
                  pid > 1 else { return nil }
            return (pid: pid, ppid: ppid)
        }
    }

    /// `root` 的全部子孙，**深的在前**。
    ///
    /// 顺序是给终止用的：先收叶子。反过来先杀中间那层，它派生的进程会立刻被收养成
    /// 孤儿——名单虽然已经在手上，但那一层要是又派生了新进程，就再也归不到这棵树里。
    ///
    /// 不含 `root` 自己。`visited` 是为了 `ps` 里 pid == ppid 这类自环（pid 1）不会
    /// 让遍历转不出来；`root <= 1` 直接返回空，免得一次参数失误变成「杀掉整台机器」。
    static func descendants(of root: Int32, in pairs: [(pid: Int32, ppid: Int32)]) -> [Int32] {
        guard root > 1 else { return [] }

        var childrenOf: [Int32: [Int32]] = [:]
        for pair in pairs where pair.pid != pair.ppid {
            childrenOf[pair.ppid, default: []].append(pair.pid)
        }

        var levels: [[Int32]] = []
        var visited: Set<Int32> = [root]
        var frontier = childrenOf[root] ?? []
        while !frontier.isEmpty {
            let level = frontier.filter { visited.insert($0).inserted }
            if level.isEmpty { break }
            levels.append(level)
            frontier = level.flatMap { childrenOf[$0] ?? [] }
        }
        return levels.reversed().flatMap { $0 }
    }

    /// 读一次当前进程表；取不到就返回空。
    ///
    /// 空表意味着清理退化成「只终止直接子进程」，也就是修这个 bug 之前的行为——
    /// 收不干净是遗憾，退出流程崩掉是事故。
    static func snapshot() -> [(pid: Int32, ppid: Int32)] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-Ao", "pid=,ppid="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do {
            try ps.run()
        } catch {
            return []
        }
        // 先读到 EOF 再 wait：反过来在输出超过管道缓冲时会死锁。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// `root` 的全部子孙（现场读一次进程表），深的在前。
    static func descendants(of root: Int32) -> [Int32] {
        descendants(of: root, in: snapshot())
    }

    /// 一次 `stop()` 要收拾的全部 pid，深的在前。
    ///
    /// 两种所有权混在一起，处理方式不同：`own` 是我们自己 spawn 的那个 node，`Process`
    /// 还在手上，由 `Process.terminate()` 亲自终止，所以它**不出现在返回值里**，只有它的
    /// 子孙出现；`adopted` 是 dsh 自己重启后我们接管的接班进程，我们只有 pid、没有
    /// `Process`，所以它自己也必须在名单里。
    ///
    /// 接班进程不是我们的直接子进程——我们那个 node 一退出，它就被 launchd 收养了——但它
    /// 是我们派生出来的进程派生出来的。⌘Q 不收它，就留下一个占着端口的孤儿，那正是这套
    /// 清理最初要解决的问题。反过来，`adoptExternalService` 接管的外部实例绝不会走到这里：
    /// 那是用户自己在终端里起的 dsh，杀它是越权（见 `ServerManager.adoptedPIDs`）。
    static func stopTargets(
        own: Int32?, adopted: [Int32], in pairs: [(pid: Int32, ppid: Int32)]
    ) -> [Int32] {
        var ordered: [Int32] = []
        if let own { ordered += descendants(of: own, in: pairs) }
        for root in adopted where root > 1 {
            ordered += descendants(of: root, in: pairs) + [root]
        }
        // `own` 预先放进 seen，等于把它从名单里剔掉：它由 `Process.terminate()` 负责。
        var seen: Set<Int32> = own.map { [$0] } ?? []
        return ordered.filter { seen.insert($0).inserted }
    }

    /// 同上，现场读一次进程表。
    static func stopTargets(own: Int32?, adopted: [Int32]) -> [Int32] {
        stopTargets(own: own, adopted: adopted, in: snapshot())
    }

    /// 先对全体发 SIGTERM，等一小段，再对仍在的补 SIGKILL；返回被强杀的那些 pid。
    ///
    /// 两级是必须的：实测那个 supervisor 完全不理 SIGTERM，只发一次「礼貌信号」
    /// 等于什么都没做。整个过程**同步**——调用它的是应用退出路径
    /// （`applicationShouldTerminate` / `applicationWillTerminate` 都是同步的），
    /// 起 Task 根本轮不到执行就随进程一起没了。
    ///
    /// `kill(pid, 0) == 0` 也包含僵尸进程（已死、尚未被父进程回收）。对僵尸补一刀
    /// 是无害的空操作，宁可多发一个信号，不要漏掉一个真活着的。
    @discardableResult
    static func terminate(_ pids: [Int32], grace: TimeInterval, poll: TimeInterval = 0.05) -> [Int32] {
        let targets = pids.filter { $0 > 1 }
        guard !targets.isEmpty else { return [] }

        for pid in targets { kill(pid, SIGTERM) }

        let deadline = Date().addingTimeInterval(grace)
        var alive = targets
        while !alive.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: poll)
            alive = alive.filter { kill($0, 0) == 0 }
        }

        for pid in alive { kill(pid, SIGKILL) }
        return alive
    }
}
