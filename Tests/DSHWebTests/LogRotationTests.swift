import Foundation
import Testing
@testable import DSHWeb

// MARK: - 日志文件命名与轮转策略

/// 落盘目录里可能混着别人的东西（用户手动放的、别的工具写的），所以
/// 「哪些文件是我们的」必须有明确判定——清理只能动自己的文件。
/// 这些用例把命名规则、时序排序、清理边界固定下来。
struct LogRotationTests {

    // MARK: 文件名生成

    @Test func namesFirstSegmentWithoutSuffix() {
        #expect(LogRotation.fileName(dateStamp: "2026-08-29", segment: 0) == "harness-2026-08-29.log")
    }

    @Test func namesLaterSegmentsWithNumericSuffix() {
        #expect(LogRotation.fileName(dateStamp: "2026-08-29", segment: 3) == "harness-2026-08-29.3.log")
    }

    // MARK: 归属判定

    @Test func recognizesOwnedLogFiles() {
        #expect(LogRotation.isOwnedLogFile("harness-2026-08-29.log"))
        #expect(LogRotation.isOwnedLogFile("harness-2026-08-29.12.log"))
    }

    @Test func rejectsForeignFiles() {
        // 清理逻辑会按这个判定删文件，误判一次就是删别人的数据
        #expect(LogRotation.isOwnedLogFile("harness.log") == false)
        #expect(LogRotation.isOwnedLogFile("dsh-2026-08-29.log") == false)
        #expect(LogRotation.isOwnedLogFile("harness-2026-08-29.log.gz") == false)
        #expect(LogRotation.isOwnedLogFile("harness-2026-8-9.log") == false)
        #expect(LogRotation.isOwnedLogFile("harness-2026-08-29.abc.log") == false)
        #expect(LogRotation.isOwnedLogFile(".DS_Store") == false)
        #expect(LogRotation.isOwnedLogFile("") == false)
    }

    // MARK: 名字解析

    @Test func parsesDateStampAndSegment() {
        #expect(LogRotation.dateStamp(ofOwnedFile: "harness-2026-08-29.log") == "2026-08-29")
        #expect(LogRotation.segment(ofOwnedFile: "harness-2026-08-29.log") == 0)
        #expect(LogRotation.dateStamp(ofOwnedFile: "harness-2026-08-29.7.log") == "2026-08-29")
        #expect(LogRotation.segment(ofOwnedFile: "harness-2026-08-29.7.log") == 7)
    }

    @Test func returnsNilForForeignFileNames() {
        #expect(LogRotation.dateStamp(ofOwnedFile: "server.log") == nil)
        #expect(LogRotation.segment(ofOwnedFile: "server.log") == nil)
    }

    // MARK: 日期戳

    @Test func stampsLocalDateNotUTC() {
        // 2026-08-29 08:30 +08:00 = 前一天 17:30 太平洋时间。用户看到的「今天」是本地日期，
        // 日志文件名必须跟着本地时区走，否则东八区用户早上的日志会落进前一天的文件。
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 29
        components.hour = 8
        components.minute = 30
        var calendar = Calendar(identifier: .gregorian)
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        calendar.timeZone = shanghai
        let date = calendar.date(from: components)!

        #expect(LogRotation.dateStamp(date, timeZone: shanghai) == "2026-08-29")
        #expect(LogRotation.dateStamp(date, timeZone: TimeZone(identifier: "America/Los_Angeles")!) == "2026-08-28")
    }

    // MARK: 时序排序

    @Test func ordersByDateThenSegmentNotLexicographically() {
        // `harness-D.1.log` 的字典序在 `harness-D.log` 之前，但它是后写的。
        // 清理必须按真实时序删，否则会先删掉最新那一段。
        let names = [
            "harness-2026-08-29.1.log",
            "harness-2026-08-28.log",
            "harness-2026-08-29.log",
            "harness-2026-08-29.10.log",
        ]
        #expect(LogRotation.chronological(names) == [
            "harness-2026-08-28.log",
            "harness-2026-08-29.log",
            "harness-2026-08-29.1.log",
            "harness-2026-08-29.10.log",
        ])
    }

    @Test func chronologicalDropsForeignNames() {
        #expect(LogRotation.chronological(["notes.txt", "harness-2026-08-29.log"]) == ["harness-2026-08-29.log"])
    }

    // MARK: 目录上限清理

    @Test func keepsEverythingWhenUnderCeiling() {
        let files = [
            LogRotation.FileEntry(name: "harness-2026-08-28.log", byteSize: 100),
            LogRotation.FileEntry(name: "harness-2026-08-29.log", byteSize: 100),
        ]
        #expect(LogRotation.evictions(files: files, maxDirectoryBytes: 1000).isEmpty)
    }

    @Test func evictsOldestFirstAndStopsWhenUnderCeiling() {
        let files = [
            LogRotation.FileEntry(name: "harness-2026-08-29.log", byteSize: 400),
            LogRotation.FileEntry(name: "harness-2026-08-27.log", byteSize: 400),
            LogRotation.FileEntry(name: "harness-2026-08-28.log", byteSize: 400),
        ]
        // 合计 1200 > 1000：删掉最老的一个就够了，不该顺手多删
        #expect(LogRotation.evictions(files: files, maxDirectoryBytes: 1000) == ["harness-2026-08-27.log"])
    }

    @Test func neverEvictsTheNewestFile() {
        // 最新那一段正在被写入，删掉它等于把当前日志丢了
        let files = [LogRotation.FileEntry(name: "harness-2026-08-29.log", byteSize: 9999)]
        #expect(LogRotation.evictions(files: files, maxDirectoryBytes: 10).isEmpty)
    }

    @Test func ignoresForeignFilesEntirely() {
        // 别人的文件既不计入总量、也绝不删除：目录是我们的，文件不一定
        let files = [
            LogRotation.FileEntry(name: "someone-else.log", byteSize: 100_000),
            LogRotation.FileEntry(name: "harness-2026-08-28.log", byteSize: 100),
            LogRotation.FileEntry(name: "harness-2026-08-29.log", byteSize: 100),
        ]
        let evictions = LogRotation.evictions(files: files, maxDirectoryBytes: 1000)
        #expect(evictions.isEmpty)
        #expect(evictions.contains("someone-else.log") == false)
    }

    @Test func evictsMultipleFilesWhenFarOverCeiling() {
        let files = (20...25).map {
            LogRotation.FileEntry(name: "harness-2026-08-\($0).log", byteSize: 300)
        }
        // 6 × 300 = 1800，上限 700 → 留最新两个（600），删最老四个
        #expect(LogRotation.evictions(files: files, maxDirectoryBytes: 700) == [
            "harness-2026-08-20.log",
            "harness-2026-08-21.log",
            "harness-2026-08-22.log",
            "harness-2026-08-23.log",
        ])
    }

    // MARK: UTF-8 安全截断

    @Test func truncatesASCIIAtByteLimit() {
        #expect(LogRotation.truncate("abcdefgh", maxBytes: 3) == "abc")
    }

    @Test func neverSplitsMultibyteCharacters() {
        // 每个汉字 3 字节：上限 7 只能装 2 个字，第 3 个必须整体丢弃
        let masked = LogRotation.truncate("服务已就绪", maxBytes: 7)
        #expect(masked == "服务")
        #expect(masked.utf8.count <= 7)
    }

    @Test func leavesShortLinesUntouched() {
        #expect(LogRotation.truncate("短", maxBytes: 100) == "短")
        #expect(LogRotation.truncate("", maxBytes: 100) == "")
    }

    @Test func handlesNonPositiveLimit() {
        #expect(LogRotation.truncate("abc", maxBytes: 0) == "")
        #expect(LogRotation.truncate("abc", maxBytes: -5) == "")
    }
}
