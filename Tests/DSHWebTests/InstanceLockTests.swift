import Foundation
import Testing
@testable import DSHWeb

// MARK: - 单实例锁

/// 为什么能在同一个进程里测：`flock` 的锁挂在「打开文件描述」上，不是挂在进程上。
/// 同一进程两次 `open()` 得到两个独立的描述，第二次 `flock(LOCK_EX|LOCK_NB)` 会照样
/// 失败——这既让测试成立，也正是我们要的语义。（`fcntl` 的锁是按进程算的，同进程
/// 第二次会静默成功，那种实现既没法测，对本用途也是错的。）
struct InstanceLockTests {

    /// 每个测试一个独立临时目录，互不干扰。
    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("instance-lock-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func acquiresWhenNobodyHoldsIt() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = InstanceLock(url: dir.appendingPathComponent("instance.lock"))
        defer { lock.release() }
        #expect(lock.acquire() == .acquired)
    }

    @Test func secondHolderIsRejected() throws {
        // 核心回归：两个 Harness 同时跑会起两个 dsh、抢同一份 ~/.dsh 状态
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("instance.lock")

        let first = InstanceLock(url: url)
        defer { first.release() }
        #expect(first.acquire() == .acquired)

        let second = InstanceLock(url: url)
        defer { second.release() }
        #expect(second.acquire() == .heldByAnother(pid: getpid()))
    }

    @Test func releaseHandsTheLockToTheNextComer() throws {
        // 上一个实例正常退出后，新实例必须能拿到锁（否则应用再也打不开）
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("instance.lock")

        let first = InstanceLock(url: url)
        #expect(first.acquire() == .acquired)
        first.release()

        let second = InstanceLock(url: url)
        defer { second.release() }
        #expect(second.acquire() == .acquired)
    }

    @Test func reacquiringFromTheSameLockIsIdempotent() throws {
        // 不能自己把自己锁死：已持有时直接返回成功，不重新 open 一个描述
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = InstanceLock(url: dir.appendingPathComponent("instance.lock"))
        defer { lock.release() }
        #expect(lock.acquire() == .acquired)
        #expect(lock.acquire() == .acquired)
    }

    @Test func releaseWithoutAcquireIsHarmless() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = InstanceLock(url: dir.appendingPathComponent("instance.lock"))
        lock.release()
        lock.release()
    }

    @Test func createsIntermediateDirectories() throws {
        // 首次运行时 Application Support/Harness 可能还不存在
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/deeper/instance.lock")
        let lock = InstanceLock(url: url)
        defer { lock.release() }
        #expect(lock.acquire() == .acquired)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func writesHolderPIDSoTheSecondInstanceCanNameIt() throws {
        // 报障时「已有实例在运行（pid N）」比一句「已在运行」有用得多
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("instance.lock")
        let lock = InstanceLock(url: url)
        defer { lock.release() }
        #expect(lock.acquire() == .acquired)

        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.trimmingCharacters(in: .whitespacesAndNewlines) == String(getpid()))
    }

    @Test func staleContentIsOverwrittenNotAppended() throws {
        // 上一个实例的 pid 必须被截断掉，否则文件里会攒出一串历史 pid
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("instance.lock")
        try "999999999\n".write(to: url, atomically: true, encoding: .utf8)

        let lock = InstanceLock(url: url)
        defer { lock.release() }
        #expect(lock.acquire() == .acquired)
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content == "\(getpid())\n")
    }

    @Test func unreadablePIDStillReportsTheLockAsHeld() throws {
        // pid 读不出来不影响结论：锁被别人拿着就是拿着
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("instance.lock")

        let holder = InstanceLock(url: url)
        defer { holder.release() }
        #expect(holder.acquire() == .acquired)
        // 持锁者写完 pid 后被抹掉（模拟内容损坏）
        try Data().write(to: url)

        let second = InstanceLock(url: url)
        defer { second.release() }
        #expect(second.acquire() == .heldByAnother(pid: nil))
    }

    // MARK: - 锁文件位置

    @Test func lockFileLivesInTheAppsOwnDirectory() {
        // 和安全模式 overlay 同一条底线：只写自己的目录，绝不碰 ~/.dsh
        let path = InstanceLock.defaultURL.path
        #expect(path.contains("Application Support/Harness"))
        #expect(path.hasSuffix("instance.lock"))
        #expect(path.contains("/.dsh/") == false)
    }

    // MARK: - 真实跨进程

    /// 同进程的用例已经足以覆盖逻辑，但「两个 Harness」本质上是跨进程问题，
    /// 所以用一个真正的外部进程持锁验一遍：锁被别人拿着时必须拿不到，那个进程
    /// 一死就必须能拿到（这正是选 flock 而不是 pid 文件的理由）。
    @Test func aRealOtherProcessBlocksTheLockAndReleasesItOnDeath() throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { return } // 无 python3 → 跳过

        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("instance.lock")

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: python)
        holder.arguments = ["-c", """
        import fcntl, sys, time
        f = open(sys.argv[1], 'a+')
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.stdout.write('locked\\n')
        sys.stdout.flush()
        time.sleep(60)
        """, url.path]
        let pipe = Pipe()
        holder.standardOutput = pipe
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }

        // 等它确认拿到锁再开始判定，否则测的是竞态而不是行为
        let handshake = pipe.fileHandleForReading.availableData
        #expect(String(decoding: handshake, as: UTF8.self).contains("locked"))

        let lock = InstanceLock(url: url)
        defer { lock.release() }
        if case .acquired = lock.acquire() {
            Issue.record("另一个进程持锁时不应拿到锁")
        }

        holder.terminate()
        holder.waitUntilExit()
        // 进程一死锁就没了：不需要任何清理动作
        #expect(lock.acquire() == .acquired)
    }
}
