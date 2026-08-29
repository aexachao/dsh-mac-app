import Foundation

/// 落盘日志的命名、时序与清理策略（纯函数，无 I/O）。
///
/// 为什么需要：日志只存在内存里的话，用户遇到「打开就闪退」「重启后才出问题」这类
/// 场景时无法回看——进程已经没了。落盘之后目录会无限增长，所以要有单文件上限、
/// 目录总量上限和清理顺序。
///
/// 关键安全约束：**只清理自己写的文件**。日志目录名义上属于本应用，但用户完全可能
/// 往里放东西（或与别的工具共用），所以「哪些文件是我们的」必须由 `isOwnedLogFile`
/// 严格判定，判定不过的文件既不计入总量、也绝不删除。
enum LogRotation {

    /// 自有日志文件的固定前缀。
    static let filePrefix = "harness-"

    /// 自有日志文件的扩展名。
    static let fileExtension = "log"

    /// 目录清理时的一条文件记录。
    struct FileEntry: Equatable {
        let name: String
        let byteSize: Int

        init(name: String, byteSize: Int) {
            self.name = name
            self.byteSize = byteSize
        }
    }

    /// `harness-<date>[.<segment>].log` —— 第 0 段不带序号，沿用最直观的名字。
    private static let ownedPattern = try! NSRegularExpression(
        pattern: #"^harness-(\d{4}-\d{2}-\d{2})(?:\.(\d+))?\.log$"#
    )

    // MARK: - 命名

    /// 本地日期戳（`yyyy-MM-dd`）。
    ///
    /// 用本地时区而不是 UTC：用户看到的「今天」是本地日期，东八区早上的日志若按 UTC
    /// 命名会落进前一天的文件里，翻日志时找不到。
    static func dateStamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// 拼出某一天某一段的文件名。
    static func fileName(dateStamp: String, segment: Int) -> String {
        segment <= 0
            ? "\(filePrefix)\(dateStamp).\(fileExtension)"
            : "\(filePrefix)\(dateStamp).\(segment).\(fileExtension)"
    }

    // MARK: - 归属判定与解析

    /// 该文件名是否为本应用写出的日志。清理只针对判定为 true 的文件。
    static func isOwnedLogFile(_ name: String) -> Bool {
        match(name) != nil
    }

    /// 从自有文件名里取日期戳；不是自有文件则为 nil。
    static func dateStamp(ofOwnedFile name: String) -> String? {
        guard let match = match(name), let range = Range(match.range(at: 1), in: name) else { return nil }
        return String(name[range])
    }

    /// 从自有文件名里取分段序号（不带序号的第一段为 0）；不是自有文件则为 nil。
    static func segment(ofOwnedFile name: String) -> Int? {
        guard let match = match(name) else { return nil }
        guard let range = Range(match.range(at: 2), in: name) else { return 0 }
        return Int(name[range])
    }

    private static func match(_ name: String) -> NSTextCheckingResult? {
        guard !name.isEmpty else { return nil }
        return ownedPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name))
    }

    // MARK: - 时序

    /// 按真实写入顺序（日期 → 分段）排序，并丢掉非自有文件。
    ///
    /// 不能用字典序：`harness-D.1.log` 的字典序排在 `harness-D.log` 之前（`1` < `l`），
    /// 而它其实是后写的。按字典序清理会先删掉最新那一段。
    static func chronological(_ names: [String]) -> [String] {
        names.compactMap { name -> (name: String, stamp: String, segment: Int)? in
            guard let stamp = dateStamp(ofOwnedFile: name), let segment = segment(ofOwnedFile: name) else { return nil }
            return (name, stamp, segment)
        }
        .sorted { lhs, rhs in
            lhs.stamp == rhs.stamp ? lhs.segment < rhs.segment : lhs.stamp < rhs.stamp
        }
        .map(\.name)
    }

    // MARK: - 目录上限清理

    /// 为把自有日志总量压到 `maxDirectoryBytes` 以内，应当删除的文件（最老优先）。
    ///
    /// 两条硬约束：
    /// - 非自有文件不计入总量、不出现在返回值里；
    /// - 最新那一段永不删除——它正在被写入，删了等于把当前这次运行的日志丢掉。
    static func evictions(files: [FileEntry], maxDirectoryBytes: Int) -> [String] {
        let sizes = Dictionary(files.map { ($0.name, $0.byteSize) }, uniquingKeysWith: { first, _ in first })
        let ordered = chronological(files.map(\.name))
        var total = ordered.reduce(0) { $0 + (sizes[$1] ?? 0) }
        guard total > maxDirectoryBytes else { return [] }

        var doomed: [String] = []
        for name in ordered.dropLast() {
            guard total > maxDirectoryBytes else { break }
            doomed.append(name)
            total -= sizes[name] ?? 0
        }
        return doomed
    }

    // MARK: - 单行截断

    /// 截到 `maxBytes` 个 UTF-8 字节以内，且不切碎多字节字符。
    ///
    /// 只做纯截断、不加省略标记：上限（默认 8 KB）远超任何可读日志行，命中的基本都是
    /// base64 数据块，加标记反而要为标记本身预留字节、让边界计算更容易出错。
    static func truncate(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard text.utf8.count > maxBytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            result.append(character)
            used += size
        }
        return result
    }
}
