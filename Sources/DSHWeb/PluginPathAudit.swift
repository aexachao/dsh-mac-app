import Foundation

/// 插件路径体检：找出「链到 macOS 隐私保护目录」的插件，并确认那些路径此刻读不读得动。
///
/// 为什么需要它：dsh 的 profile 里插件可以是指向任何位置的符号链接（开发插件时把仓库
/// 链进 `node_modules` 是常规做法）。而 `~/Documents`、`~/Desktop`、`~/Downloads` 受
/// TCC 保护——应用没拿到授权时读它**不是报错，是永远不返回**：dsh 卡在 `open()` 里，
/// 界面停在「启动中」，日志里一行异常都没有，等到 90 秒超时才报一句「服务无响应」。
///
/// 本机实测过一次：一个插件链到 `~/Documents/dev/…`，从现象到病根要靠 `sample` 抓 node
/// 的调用栈才看得出来。这份体检就是替用户省掉那一步——它自己不修任何东西，只把那句
/// 「去系统设置里授权，或者把插件移出受保护目录」在正确的时刻说出来。
enum PluginPathAudit {

    /// 受 TCC 保护的家目录子目录。iCloud 云盘（`Library/Mobile Documents`）同理，
    /// 但它的表现是「下载中」而不是「没授权」，成因不同，不混在一起报。
    static let protectedDirectories = ["Documents", "Desktop", "Downloads"]

    /// 一条发现：某个 bundle 链到了受保护目录。
    struct Finding: Equatable, Sendable {
        /// `node_modules` 下的包名（可能带 scope）。
        let bundle: String
        /// 符号链接解析后的绝对路径。
        let target: String
        /// 命中的是哪一层保护目录——决定要让用户去开哪个开关。
        let protectedDirectory: String
    }

    /// 列出链到受保护目录的插件。
    ///
    /// 只用 `readlink` + 路径比较，绝不打开目标：`readlink` 不受 TCC 限制，所以这一步
    /// 本身不可能卡住。判断读不读得动是 `unreadable(_:)` 的事，那一步才需要时限。
    static func symlinkedIntoProtectedDirectories(profileDirectory: URL, home: URL) -> [Finding] {
        let modules = profileDirectory.appendingPathComponent("node_modules")
        let roots = protectedDirectories.map { (name: $0, prefix: home.appendingPathComponent($0).path) }

        return packageDirectories(in: modules).compactMap { bundle, path in
            guard let target = resolvedSymlink(at: path) else { return nil }
            guard let hit = roots.first(where: { isInside(target, root: $0.prefix) }) else { return nil }
            return Finding(bundle: bundle, target: target, protectedDirectory: hit.name)
        }
    }

    /// 这些路径现在读得动吗？读不动的原样返回。
    ///
    /// 逐条并发探测而不是顺序：卡住的那条不返回，顺序探测会被它挡住后面全部。
    static func unreadable(_ findings: [Finding], timeout: TimeInterval = 1.5) async -> [Finding] {
        guard !findings.isEmpty else { return [] }
        var blocked: [Finding] = []
        await withTaskGroup(of: (Finding, Bool).self) { group in
            for finding in findings {
                group.addTask { (finding, await isReadable(finding.target, timeout: timeout)) }
            }
            for await (finding, readable) in group where !readable {
                blocked.append(finding)
            }
        }
        // 顺序按输入来，日志每次一致。
        return findings.filter { blocked.contains($0) }
    }

    /// 打开一次目标路径——和 dsh 会做的事一样，所以卡住的方式也一样。
    ///
    /// 用 `open()` 而不是 `access()`/`stat()`：TCC 拦的是 `open`，另两个在受保护路径上
    /// 会直接给答案，探不到真正的阻塞。
    private static func isReadable(_ path: String, timeout: TimeInterval) async -> Bool {
        await Deadline.run(timeout: timeout, qos: .utility) {
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { return false }
            close(fd)
            return true
        } ?? false
    }

    // MARK: - 一次完整体检

    /// 枚举 `node_modules` 的时间上限。这一步不会被 TCC 卡住（只 `readlink`，不打开），
    /// 但 profile 的 node_modules 动辄上万条目，仍然不该在主线程上做，也仍然要有个尽头。
    static let enumerationTimeout: TimeInterval = 3

    /// 完整体检：链到受保护目录、而且此刻确实读不动的插件。
    ///
    /// 每一步都在后台、每一步都有时限——这份体检的用途正是解释「应用卡住了」，
    /// 它自己绝不能成为下一个卡住的地方。超时按「没发现」处理：漏报只是少几行日志，
    /// 而把启动流程拖住是实打实的故障。
    static func blocked(profileDirectory: URL, home: URL) async -> [Finding] {
        let findings = await Deadline.run(timeout: enumerationTimeout, qos: .utility) {
            symlinkedIntoProtectedDirectories(profileDirectory: profileDirectory, home: home)
        }
        guard let findings, !findings.isEmpty else { return [] }
        return await unreadable(findings)
    }

    // MARK: - 目录枚举

    /// `node_modules` 下的包目录，scope 目录（`@foo/`）展开一层。
    ///
    /// 用 `contentsOfDirectory` 而不是深度遍历：只要顶层这一层就够，而且 profile 的
    /// `node_modules` 动辄上万个文件，深遍历本身就是一次可观的磁盘开销。
    private static func packageDirectories(in modules: URL) -> [(bundle: String, path: String)] {
        entries(of: modules).flatMap { name -> [(String, String)] in
            let path = modules.appendingPathComponent(name)
            guard name.hasPrefix("@") else { return [(name, path.path)] }
            return entries(of: path).map { ("\(name)/\($0)", path.appendingPathComponent($0).path) }
        }
    }

    private static func entries(of directory: URL) -> [String] {
        let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        return (names ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// 符号链接指向哪里（绝对路径）；不是符号链接返回 nil。
    private static func resolvedSymlink(at path: String) -> String? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return nil
        }
        let url = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(destination)
        return url.standardizedFileURL.path
    }

    /// `path` 是否落在 `root` 之下。
    ///
    /// 比较前补上分隔符，否则 `~/Documents-old` 会被算进 `~/Documents`。
    static func isInside(_ path: String, root: String) -> Bool {
        let root = root.hasSuffix("/") ? root : root + "/"
        return path == String(root.dropLast()) || path.hasPrefix(root)
    }
}
