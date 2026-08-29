import Foundation

/// 安全模式的配置 overlay：一份只写「停用哪些插件」的 YAML，用 `--patch` 叠加给 dsh。
///
/// 三条约束，缺一不可：
/// - **写在应用自己的目录里**（`~/Library/Application Support/Harness/`）。`~/.dsh`
///   是用户和其它 dsh 版本（比如 DSH Desktop 自带的运行时）共享的状态，安全模式
///   没有资格改写它——那会把「临时救场」变成「悄悄改了用户配置」。
/// - **只叠加，不修改**。overlay 是 dsh 组合链的最后一层，删掉文件即恢复原状。
/// - **内容稳定**。同一套插件生成的文件逐字节相同（时间戳除外），用户 diff 得出来。
enum SafeModeOverlay {

    /// overlay 的默认位置。
    static var defaultURL: URL {
        applicationSupportDirectory.appendingPathComponent("safe-mode.yml")
    }

    /// 应用自己的支持目录。
    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Harness")
    }

    /// dsh 的 web profile 目录：插件清单从这里静态读出。
    static var profileDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dsh/profiles/web")
    }

    /// 渲染 overlay 文本。
    ///
    /// 头部注释是写给用户看的：他在磁盘上撞见这个文件时，必须能立刻判断出是谁写的、
    /// 删掉会不会坏事。
    static func render(disabling ids: [String], generatedAt: Date = Date()) -> String {
        let sorted = Set(ids).sorted()
        var lines = [
            "# Harness 安全模式 overlay — 由应用自动生成于 \(timestamp(generatedAt))",
            "# 连续启动失败后，Harness 用 `dsh --patch` 把这一层叠加到配置上，临时停用第三方插件。",
            "# 它不属于 ~/.dsh，Harness 也永远不会往那里写。删掉本文件不会损坏任何配置，",
            "# 下次进入安全模式时会重新生成。",
        ]
        if sorted.isEmpty {
            // 没有第三方插件时也要是一份合法 YAML：写半个文件会让 dsh 直接拒绝启动。
            lines.append("[]")
        } else {
            for id in sorted {
                lines.append("- id: \(id)")
                lines.append("  disabled: true")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 渲染并写盘，按需创建上级目录。
    @discardableResult
    static func write(
        disabling ids: [String],
        to url: URL = defaultURL,
        generatedAt: Date = Date()
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try render(disabling: ids, generatedAt: generatedAt)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// 「下次以安全模式启动」这个决定的持久化。
///
/// 必须存盘：触发安全模式的场景就是进程反复崩溃，内存里的标记跟着进程一起消失。
struct SafeModeStore {

    private static let key = "safeModeEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Self.key)
    }

    func enable() {
        defaults.set(true, forKey: Self.key)
    }

    func disable() {
        defaults.set(false, forKey: Self.key)
    }
}
