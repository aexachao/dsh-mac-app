import Foundation
import Testing
@testable import DSHWeb

// MARK: - 日志落盘

/// 落盘的价值在于「崩溃/退出之后还能看到发生了什么」，所以这些用例都用真实临时目录
/// 和真实文件句柄跑，不做 I/O 抽象——mock 掉文件系统就验证不了轮转和清理真的生效。
struct LogFileSinkTests {

    /// 每个用例一个独立临时目录，结束时删除。
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-logsink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func contents(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func text(_ directory: URL, _ name: String) -> String {
        (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    private func fixedClock(_ stamp: String) -> @Sendable () -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = formatter.date(from: "\(stamp) 12:00:00")!
        return { date }
    }

    // MARK: 基本写入

    @Test func createsDirectoryAndWritesDatedFile() throws {
        try withTemporaryDirectory { directory in
            let sink = LogFileSink(directory: directory, clock: fixedClock("2026-08-29"))
            sink.append("第一行")
            sink.append("第二行")
            sink.flush()

            #expect(contents(of: directory) == ["harness-2026-08-29.log"])
            #expect(text(directory, "harness-2026-08-29.log") == "第一行\n第二行\n")
        }
    }

    @Test func appendsToExistingFileAcrossSinkInstances() throws {
        // 应用重启后不能覆盖当天已有日志——那会丢掉上一次运行的失败原因
        try withTemporaryDirectory { directory in
            let clock = fixedClock("2026-08-29")
            let first = LogFileSink(directory: directory, clock: clock)
            first.append("上一次运行")
            first.flush()
            first.close()

            let second = LogFileSink(directory: directory, clock: clock)
            second.append("这一次运行")
            second.flush()

            #expect(text(directory, "harness-2026-08-29.log") == "上一次运行\n这一次运行\n")
        }
    }

    @Test func writesBatchInOrder() throws {
        try withTemporaryDirectory { directory in
            let sink = LogFileSink(directory: directory, clock: fixedClock("2026-08-29"))
            sink.append(["a", "b", "c"])
            sink.flush()
            #expect(text(directory, "harness-2026-08-29.log") == "a\nb\nc\n")
        }
    }

    @Test func preservesOrderUnderConcurrentAppends() throws {
        // 日志顺序错乱会让排障时因果关系反过来，比丢几行更糟
        try withTemporaryDirectory { directory in
            let sink = LogFileSink(directory: directory, clock: fixedClock("2026-08-29"))
            for index in 0..<200 { sink.append("line-\(index)") }
            sink.flush()
            let lines = text(directory, "harness-2026-08-29.log")
                .split(separator: "\n", omittingEmptySubsequences: true)
            #expect(lines.count == 200)
            #expect(lines.first == "line-0")
            #expect(lines.last == "line-199")
        }
    }

    // MARK: 单文件上限与分段

    @Test func rotatesToNextSegmentWhenFileLimitReached() throws {
        try withTemporaryDirectory { directory in
            // 每行 "0123456789\n" = 11 字节；上限 25 字节只装得下 2 行
            let limits = LogFileSink.Limits(maxFileBytes: 25, maxDirectoryBytes: 10_000, maxLineBytes: 1024)
            let sink = LogFileSink(directory: directory, limits: limits, clock: fixedClock("2026-08-29"))
            sink.append(["0123456789", "0123456789", "0123456789"])
            sink.flush()

            #expect(contents(of: directory) == ["harness-2026-08-29.1.log", "harness-2026-08-29.log"])
            #expect(text(directory, "harness-2026-08-29.log") == "0123456789\n0123456789\n")
            #expect(text(directory, "harness-2026-08-29.1.log") == "0123456789\n")
        }
    }

    @Test func resumesAtHighestExistingSegment() throws {
        // 磁盘上已有 .1 段时，重启后必须接着 .1 写，不能回头覆盖 .log
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "满了\n".write(to: directory.appendingPathComponent("harness-2026-08-29.log"), atomically: true, encoding: .utf8)
            try "第二段\n".write(to: directory.appendingPathComponent("harness-2026-08-29.1.log"), atomically: true, encoding: .utf8)

            let sink = LogFileSink(directory: directory, clock: fixedClock("2026-08-29"))
            sink.append("新行")
            sink.flush()

            #expect(text(directory, "harness-2026-08-29.1.log") == "第二段\n新行\n")
            #expect(text(directory, "harness-2026-08-29.log") == "满了\n")
        }
    }

    @Test func startsNewFileWhenDateChanges() throws {
        try withTemporaryDirectory { directory in
            let clock = MovableClock(stamp: "2026-08-29")
            let sink = LogFileSink(directory: directory, clock: { clock.now() })

            sink.append("昨天")
            sink.flush()
            clock.stamp = "2026-08-30"
            sink.append("今天")
            sink.flush()

            #expect(contents(of: directory) == ["harness-2026-08-29.log", "harness-2026-08-30.log"])
            #expect(text(directory, "harness-2026-08-30.log") == "今天\n")
        }
    }

    // MARK: 目录上限清理

    @Test func evictsOldOwnedFilesWhenDirectoryLimitExceeded() throws {
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for day in ["25", "26", "27"] {
                try String(repeating: "x", count: 400)
                    .write(to: directory.appendingPathComponent("harness-2026-08-\(day).log"),
                           atomically: true, encoding: .utf8)
            }
            let limits = LogFileSink.Limits(maxFileBytes: 10_000, maxDirectoryBytes: 900, maxLineBytes: 1024)
            let sink = LogFileSink(directory: directory, limits: limits, clock: fixedClock("2026-08-29"))
            sink.append("今天")
            sink.flush()

            // 1200 + 今天那一点 > 900：从最老的开始删到达标
            #expect(contents(of: directory).contains("harness-2026-08-25.log") == false)
            #expect(contents(of: directory).contains("harness-2026-08-29.log"))
        }
    }

    @Test func neverDeletesForeignFiles() throws {
        // 目录里若有别的东西，宁可超出上限也不动它
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let foreign = directory.appendingPathComponent("important-notes.txt")
            try String(repeating: "y", count: 5_000).write(to: foreign, atomically: true, encoding: .utf8)

            let limits = LogFileSink.Limits(maxFileBytes: 100, maxDirectoryBytes: 200, maxLineBytes: 1024)
            let sink = LogFileSink(directory: directory, limits: limits, clock: fixedClock("2026-08-29"))
            sink.append(String(repeating: "z", count: 90))
            sink.append(String(repeating: "z", count: 90))
            sink.append(String(repeating: "z", count: 90))
            sink.flush()

            #expect(FileManager.default.fileExists(atPath: foreign.path))
        }
    }

    @Test func neverDeletesTheFileItIsWritingTo() throws {
        try withTemporaryDirectory { directory in
            // 上限比单个文件还小：清理逻辑必须保住正在写的那一段
            let limits = LogFileSink.Limits(maxFileBytes: 1_000, maxDirectoryBytes: 10, maxLineBytes: 1024)
            let sink = LogFileSink(directory: directory, limits: limits, clock: fixedClock("2026-08-29"))
            sink.append("必须留下")
            sink.flush()
            #expect(text(directory, "harness-2026-08-29.log") == "必须留下\n")
        }
    }

    // MARK: 单行上限

    @Test func truncatesOverlongLinesWithoutBreakingUTF8() throws {
        try withTemporaryDirectory { directory in
            let limits = LogFileSink.Limits(maxFileBytes: 10_000, maxDirectoryBytes: 100_000, maxLineBytes: 7)
            let sink = LogFileSink(directory: directory, limits: limits, clock: fixedClock("2026-08-29"))
            sink.append("服务已就绪")
            sink.flush()
            #expect(text(directory, "harness-2026-08-29.log") == "服务\n")
        }
    }

    // MARK: 当前文件与清单

    @Test func reportsCurrentFileAndOwnedInventory() throws {
        try withTemporaryDirectory { directory in
            let limits = LogFileSink.Limits(maxFileBytes: 25, maxDirectoryBytes: 10_000, maxLineBytes: 1024)
            let sink = LogFileSink(directory: directory, limits: limits, clock: fixedClock("2026-08-29"))
            sink.append(["0123456789", "0123456789", "0123456789"])
            sink.flush()

            #expect(sink.currentFileURL?.lastPathComponent == "harness-2026-08-29.1.log")
            #expect(sink.ownedFileNames() == ["harness-2026-08-29.log", "harness-2026-08-29.1.log"])
        }
    }

    @Test func reportsNoCurrentFileBeforeFirstWrite() throws {
        try withTemporaryDirectory { directory in
            let sink = LogFileSink(directory: directory, clock: fixedClock("2026-08-29"))
            #expect(sink.currentFileURL == nil)
            #expect(sink.ownedFileNames().isEmpty)
        }
    }

    // MARK: 失败不能拖垮应用

    @Test func staysSilentWhenDirectoryCannotBeCreated() throws {
        // 落盘只是增强能力：目录不可写（沙箱/权限）时应用必须继续正常运行
        let blocked = URL(fileURLWithPath: "/dev/null/harness-logs")
        let sink = LogFileSink(directory: blocked, clock: fixedClock("2026-08-29"))
        sink.append("不该崩")
        sink.flush()
        #expect(sink.currentFileURL == nil)
    }

    // MARK: 默认位置与默认上限

    @Test func defaultsToUserLogsDirectory() {
        #expect(LogFileSink.defaultDirectory.path.hasSuffix("/Library/Logs/Harness"))
    }

    @Test func defaultLimitsAreSaneRelativeToEachOther() {
        let limits = LogFileSink.Limits.standard
        // 单行必须远小于单文件，否则轮转判定会退化
        #expect(limits.maxLineBytes < limits.maxFileBytes)
        #expect(limits.maxFileBytes < limits.maxDirectoryBytes)
    }
}

/// 测试辅助：可推进的时钟（落盘要验证跨天换文件）。
private final class MovableClock: @unchecked Sendable {
    var stamp: String
    private let formatter: DateFormatter

    init(stamp: String) {
        self.stamp = stamp
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
    }

    func now() -> Date {
        formatter.date(from: "\(stamp) 12:00:00")!
    }
}
