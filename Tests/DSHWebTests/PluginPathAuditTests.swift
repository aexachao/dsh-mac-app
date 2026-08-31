import Foundation
import Testing
@testable import DSHWeb

// MARK: - 插件路径体检

/// 病根现场：一个插件被链进 `~/Documents/dev/…`（把开发仓库链进 node_modules 是常规做法），
/// 而那类目录受 macOS 隐私保护——没授权时读它不是报错，是永远不返回。dsh 卡在 `open()` 里，
/// 界面停在「启动中」，日志一行异常都没有。这份体检就是替用户省掉 `sample` 抓调用栈那一步。
struct PluginPathAuditTests {

    // MARK: 造一个假的 profile + 假的家目录

    /// 返回 (根目录, profile 目录, 家目录)。根目录由调用方负责删。
    private func makeTree() throws -> (root: URL, profile: URL, home: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PluginPathAuditTests-\(UUID().uuidString)")
        let profile = root.appendingPathComponent("profiles/web")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(
            at: profile.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        for name in PluginPathAudit.protectedDirectories {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        return (root, profile, home)
    }

    private func link(_ name: String, to target: URL, in profile: URL) throws {
        let path = profile.appendingPathComponent("node_modules").appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
    }

    // MARK: 找出链到受保护目录的插件

    @Test func findsPluginSymlinkedIntoDocuments() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }

        let target = tree.home.appendingPathComponent("Documents/dev/dsh-balance-tracker")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try link("dsh-balance-tracker", to: target, in: tree.profile)

        let findings = PluginPathAudit.symlinkedIntoProtectedDirectories(
            profileDirectory: tree.profile, home: tree.home)
        #expect(findings.count == 1)
        #expect(findings.first?.bundle == "dsh-balance-tracker")
        #expect(findings.first?.protectedDirectory == "Documents")
        #expect(findings.first?.target == target.standardizedFileURL.path)
    }

    @Test func reportsWhichProtectedDirectoryWasHit() throws {
        // 命中的是哪一层决定要让用户去开哪个开关，不能一律说成 Documents。
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }

        for (name, directory) in [("a", "Desktop"), ("b", "Downloads")] {
            let target = tree.home.appendingPathComponent("\(directory)/plugin")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try link(name, to: target, in: tree.profile)
        }

        let hits = PluginPathAudit.symlinkedIntoProtectedDirectories(
            profileDirectory: tree.profile, home: tree.home)
        #expect(hits.map(\.protectedDirectory) == ["Desktop", "Downloads"])
    }

    @Test func ignoresSymlinksOutsideProtectedDirectories() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }

        let target = tree.root.appendingPathComponent("elsewhere/plugin")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try link("elsewhere-plugin", to: target, in: tree.profile)

        #expect(PluginPathAudit.symlinkedIntoProtectedDirectories(
            profileDirectory: tree.profile, home: tree.home).isEmpty)
    }

    @Test func ignoresOrdinaryInstalledPackages() throws {
        // 绝大多数包是真目录，不是符号链接；它们不可能触发这个问题，也不该被点名。
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }

        try FileManager.default.createDirectory(
            at: tree.profile.appendingPathComponent("node_modules/yaml"),
            withIntermediateDirectories: true)

        #expect(PluginPathAudit.symlinkedIntoProtectedDirectories(
            profileDirectory: tree.profile, home: tree.home).isEmpty)
    }

    @Test func expandsScopedPackageDirectories() throws {
        // `@scope/` 只是一层目录，里面才是包；不展开就漏掉所有带 scope 的插件。
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }

        let target = tree.home.appendingPathComponent("Documents/dev/web-ui")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try link("@linxin666/dsh-web-ui-all", to: target, in: tree.profile)

        let findings = PluginPathAudit.symlinkedIntoProtectedDirectories(
            profileDirectory: tree.profile, home: tree.home)
        #expect(findings.map(\.bundle) == ["@linxin666/dsh-web-ui-all"])
    }

    @Test func resolvesRelativeSymlinks() throws {
        // 现场那条链子就是相对的：`../../../../Documents/dev/…`
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }

        let target = tree.home.appendingPathComponent("Documents/dev/relative-plugin")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let linkPath = tree.profile.appendingPathComponent("node_modules/relative-plugin")
        try FileManager.default.createSymbolicLink(
            atPath: linkPath.path,
            withDestinationPath: "../../../home/Documents/dev/relative-plugin")

        let findings = PluginPathAudit.symlinkedIntoProtectedDirectories(
            profileDirectory: tree.profile, home: tree.home)
        #expect(findings.map(\.target) == [target.standardizedFileURL.path])
    }

    @Test func missingNodeModulesYieldsNoFindings() throws {
        // profile 不存在、node_modules 没装：体检只能少报，不能整体失败。
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PluginPathAuditTests-\(UUID().uuidString)")
        #expect(PluginPathAudit.symlinkedIntoProtectedDirectories(
            profileDirectory: root, home: root).isEmpty)
    }

    // MARK: 路径归属判断

    @Test func isInsideRequiresAPathSeparator() {
        // 少了补分隔符这一步，`~/Documents-old` 会被算进 `~/Documents`，于是无辜的插件被点名。
        #expect(PluginPathAudit.isInside("/Users/x/Documents/dev", root: "/Users/x/Documents"))
        #expect(PluginPathAudit.isInside("/Users/x/Documents", root: "/Users/x/Documents"))
        #expect(!PluginPathAudit.isInside("/Users/x/Documents-old/dev", root: "/Users/x/Documents"))
        #expect(!PluginPathAudit.isInside("/Users/x/Doc", root: "/Users/x/Documents"))
    }

    @Test func isInsideToleratesATrailingSlashOnTheRoot() {
        #expect(PluginPathAudit.isInside("/Users/x/Desktop/p", root: "/Users/x/Desktop/"))
    }

    // MARK: 读得动吗

    @Test func readableTargetsAreNotReported() async throws {
        // 授权过的机器上这些路径读得动，那就不是病根，一句话都不该说。
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }

        let target = tree.home.appendingPathComponent("Documents/dev/ok")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try link("ok", to: target, in: tree.profile)

        let findings = PluginPathAudit.symlinkedIntoProtectedDirectories(
            profileDirectory: tree.profile, home: tree.home)
        #expect(findings.count == 1)
        #expect(await PluginPathAudit.unreadable(findings).isEmpty)
        #expect(await PluginPathAudit.blocked(
            profileDirectory: tree.profile, home: tree.home).isEmpty)
    }

    @Test func brokenSymlinkCountsAsUnreadable() async throws {
        // 打不开就是打不开：TCC 拦住和目标不存在在这里是同一种处置（都得让用户看一眼）。
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }

        try link("gone", to: tree.home.appendingPathComponent("Documents/dev/gone"), in: tree.profile)

        let blocked = await PluginPathAudit.blocked(
            profileDirectory: tree.profile, home: tree.home)
        #expect(blocked.map(\.bundle) == ["gone"])
    }

    @Test func unreadableKeepsInputOrder() async throws {
        // 日志每次一致，用户对比两次启动的输出才有意义。
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }

        for name in ["a", "b", "c"] {
            try link(name, to: tree.home.appendingPathComponent("Documents/\(name)"), in: tree.profile)
        }
        let findings = PluginPathAudit.symlinkedIntoProtectedDirectories(
            profileDirectory: tree.profile, home: tree.home)
        #expect(await PluginPathAudit.unreadable(findings).map(\.bundle) == findings.map(\.bundle))
    }

    @Test func noFindingsMeansNoProbing() async {
        #expect(await PluginPathAudit.unreadable([]).isEmpty)
    }
}
