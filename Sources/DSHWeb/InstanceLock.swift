import Foundation

/// 单实例锁：保证同一时刻只有一个 Harness 在跑。
///
/// 为什么需要：macOS 只在「同一个 bundle 被再次打开」时替你拦截，`open -n`、
/// `swift run`、以及 `dist/Harness.app` 与 `~/Applications/Harness.app` 两份拷贝
/// 都能绕过去。两个实例同时跑意味着两个 dsh 服务、两份日志写同一个目录、以及争抢
/// 同一份 `~/.dsh` 状态——这类问题在日志里看起来毫无道理。
///
/// 用 `flock` 而不是 pid 文件：锁随进程消失，崩溃后不会留下一个谁也解不开的死锁。
/// 锁挂在「打开文件描述」上而非进程上，所以同进程第二次 `open` + `flock` 同样会被
/// 拒绝——这让它能在单元测试里被真实验证。（`fcntl` 的锁按进程算，同进程会静默
/// 成功，那既没法测，语义也不对。）
///
/// 判定不了就放行：目录建不出来、`open` 失败这类情况一律当作拿到锁。多开一个实例
/// 是可恢复的，应用永远打不开不是。
final class InstanceLock {

    enum Acquisition: Equatable {
        case acquired
        /// 锁被另一个实例持有；`pid` 是它写在锁文件里的进程号（读不出来时为 nil）。
        case heldByAnother(pid: pid_t?)
    }

    /// 默认锁文件位置。
    static var defaultURL: URL {
        AppDirectories.support.appendingPathComponent("instance.lock")
    }

    private let url: URL
    /// 持锁期间必须一直开着：关掉描述就等于解锁。
    private var descriptor: Int32?

    init(url: URL = defaultURL) {
        self.url = url
    }

    deinit {
        release()
    }

    /// 尝试取锁。已持有时直接返回成功——重新 `open` 一个描述会把自己锁在外面。
    func acquire() -> Acquisition {
        guard descriptor == nil else { return .acquired }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return .acquired // 判定不了 → 放行
        }

        // 不带 O_TRUNC：拿不到锁时要能读出持锁者的 pid，先截断就把它抹掉了。
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return .acquired }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let holder = holderPID()
            close(fd)
            return .heldByAnother(pid: holder)
        }

        descriptor = fd
        writeOwnPID(to: fd)
        return .acquired
    }

    /// 释放并关闭描述符。未持有时是空操作，可重复调用。
    func release() {
        guard let fd = descriptor else { return }
        descriptor = nil
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// 把自己的 pid 写进锁文件，供下一个实例在提示里指名道姓。
    ///
    /// 写失败只影响那句提示的细节，不影响锁本身，所以不上报。
    private func writeOwnPID(to fd: Int32) {
        guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) == 0 else { return }
        let bytes = Array("\(getpid())\n".utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }

    /// 读锁文件里的 pid。内容损坏或为空时返回 nil。
    private func holderPID() -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
