import Foundation

/// 把日志行追加写入 `~/Library/Logs/Harness/`，按天与体积分段，并把目录总量压在上限内。
///
/// 为什么要落盘：内存缓冲区随进程消失。用户遇到「打开就退出」「昨天那次失败」这类问题
/// 时，没有落盘就什么都拿不到。写进来的行已在 `ServerManager.log(_:)` 里脱敏过。
///
/// 并发模型：所有可变状态都只在私有串行队列 `queue` 上访问，`append` 异步入队。
/// 用串行队列而不是 actor，是因为 actor 的非结构化任务不保证 FIFO——日志顺序错乱会让
/// 排障时因果关系反过来，比丢几行更糟。因此 `@unchecked Sendable` 是可控的。
///
/// 失败策略：落盘属于增强能力，任何 I/O 失败（目录不可写、句柄打开失败）都静默降级为
/// 不落盘，绝不影响服务本身运行。
final class LogFileSink: @unchecked Sendable {

    /// 容量上限。
    struct Limits: Sendable {
        /// 单个文件上限，超过则开新分段。
        let maxFileBytes: Int
        /// 自有日志文件总量上限，超过则从最老的开始删。
        let maxDirectoryBytes: Int
        /// 单行上限，超过则按 UTF-8 边界截断。
        let maxLineBytes: Int

        init(maxFileBytes: Int, maxDirectoryBytes: Int, maxLineBytes: Int) {
            self.maxFileBytes = maxFileBytes
            self.maxDirectoryBytes = maxDirectoryBytes
            self.maxLineBytes = maxLineBytes
        }

        /// 生产默认：单文件 2 MB、总量 16 MB、单行 8 KB。
        /// 2 MB 大约是一次长时间运行的完整日志，16 MB 够留下最近若干天。
        static let standard = Limits(
            maxFileBytes: 2 * 1024 * 1024,
            maxDirectoryBytes: 16 * 1024 * 1024,
            maxLineBytes: 8 * 1024
        )
    }

    /// 生产落盘位置：`~/Library/Logs/Harness`（Console.app 能直接看到）。
    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Harness")
    }

    private let directory: URL
    private let limits: Limits
    private let clock: @Sendable () -> Date
    private let queue = DispatchQueue(label: "dsh-web.logfile")

    // 以下状态只在 queue 上访问
    private var handle: FileHandle?
    private var activeStamp: String?
    private var activeSegment: Int?
    private var activeBytes = 0
    private var directoryReady = false

    init(
        directory: URL = LogFileSink.defaultDirectory,
        limits: Limits = .standard,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.limits = limits
        self.clock = clock
    }

    deinit {
        handle?.closeFile()
    }

    // MARK: - 写入

    /// 追加一行（异步入队，调用方不阻塞）。
    func append(_ line: String) {
        let now = clock()
        queue.async { [self] in write(line, at: now) }
    }

    /// 追加一批行，保持批内顺序。
    func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let now = clock()
        queue.async { [self] in
            for line in lines { write(line, at: now) }
        }
    }

    /// 等待已入队的写入全部落盘（导出诊断前、测试断言前调用）。
    func flush() {
        queue.sync {}
    }

    /// 关闭当前文件句柄（应用退出前调用；下次 `append` 会重新打开）。
    func close() {
        queue.sync { [self] in closeActive() }
    }

    // MARK: - 查询

    /// 当前正在写入的文件；一次都没写过时为 nil。
    var currentFileURL: URL? {
        queue.sync { [self] in
            guard let activeStamp, let activeSegment else { return nil }
            return directory.appendingPathComponent(
                LogRotation.fileName(dateStamp: activeStamp, segment: activeSegment)
            )
        }
    }

    /// 目录里自有日志文件的名字（按写入时序）。
    func ownedFileNames() -> [String] {
        queue.sync { [self] in LogRotation.chronological(directoryContents()) }
    }

    // MARK: - 内部实现（全部在 queue 上）

    private func write(_ line: String, at date: Date) {
        let payload = LogRotation.truncate(line, maxBytes: limits.maxLineBytes) + "\n"
        let data = Data(payload.utf8)
        ensureCapacity(for: data.count, stamp: LogRotation.dateStamp(date))
        guard let handle else { return }
        // Swift 6 的 write(contentsOf:) 会 throw；落盘失败不该影响服务，记下并放弃当前句柄。
        do {
            try handle.write(contentsOf: data)
            activeBytes += data.count
        } catch {
            closeActive()
        }
    }

    /// 确保当前句柄指向一个还能再写 `incoming` 字节的文件。
    ///
    /// 三种情况需要换文件：首次写入、跨天、当前分段写满。
    private func ensureCapacity(for incoming: Int, stamp: String) {
        // 单行理论上可能超过单文件上限，夹一下避免下面的 while 无法收敛。
        let needed = min(incoming, limits.maxFileBytes)
        if handle != nil, activeStamp == stamp, activeBytes + needed <= limits.maxFileBytes { return }

        // 关闭前先取旧值：closeActive() 之后 activeSegment 就没了。
        let writingSameDay = (handle != nil && activeStamp == stamp)
        let previousSegment = activeSegment
        closeActive()
        guard prepareDirectory() else { return }

        // 同一天写满 → 下一段；首次打开或跨天 → 接续磁盘上已存在的最新一段（不覆盖旧内容）
        var segment: Int
        if writingSameDay, let previousSegment {
            segment = previousSegment + 1
        } else {
            segment = highestSegment(stamp: stamp) ?? 0
        }

        var url = directory.appendingPathComponent(LogRotation.fileName(dateStamp: stamp, segment: segment))
        var size = byteSize(of: url)
        while size + needed > limits.maxFileBytes {
            segment += 1
            url = directory.appendingPathComponent(LogRotation.fileName(dateStamp: stamp, segment: segment))
            size = byteSize(of: url)
        }

        guard let opened = openForAppending(url) else { return }
        handle = opened
        activeStamp = stamp
        activeSegment = segment
        activeBytes = size
        // 只在换文件时做目录清理：每行都扫一遍目录会在 dsh 流式输出时明显拖慢写入。
        enforceDirectoryCeiling(protecting: url.lastPathComponent)
    }

    private func closeActive() {
        handle?.closeFile()
        handle = nil
        activeSegment = nil
        activeBytes = 0
    }

    private func prepareDirectory() -> Bool {
        if directoryReady { return true }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            directoryReady = isDirectory.boolValue
            return directoryReady
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            directoryReady = true
        } catch {
            directoryReady = false
        }
        return directoryReady
    }

    private func openForAppending(_ url: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }

    private func directoryContents() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    private func highestSegment(stamp: String) -> Int? {
        directoryContents()
            .filter { LogRotation.dateStamp(ofOwnedFile: $0) == stamp }
            .compactMap { LogRotation.segment(ofOwnedFile: $0) }
            .max()
    }

    private func byteSize(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// 把自有日志总量压回上限内。`protecting` 是正在写入的文件，任何情况下都不删。
    private func enforceDirectoryCeiling(protecting active: String) {
        let entries = directoryContents().compactMap { name -> LogRotation.FileEntry? in
            guard LogRotation.isOwnedLogFile(name) else { return nil }
            return LogRotation.FileEntry(
                name: name,
                byteSize: byteSize(of: directory.appendingPathComponent(name))
            )
        }
        for name in LogRotation.evictions(files: entries, maxDirectoryBytes: limits.maxDirectoryBytes)
        where name != active {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
