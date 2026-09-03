import Foundation
import Testing
@testable import DSHWeb

// MARK: - 插件清单（静态扫描）

/// 安全模式要禁用插件，就得先知道有哪些插件。不能靠 `dsh --dump-config`：那需要 dsh
/// 能启动，而安全模式恰恰是为「dsh 启动不了」准备的。所以只静态读 profile 目录。
struct PluginInventoryTests {

    // MARK: 从 bundle 的 cordis.patch.yml 抽 id

    @Test func extractsIDsFromInsertBlocks() {
        // 真实形状：bundle 用 insert 把自己的插件塞进 profile 的层级栈
        let text = """
        # dsh bundle patch: inserts this plugin into a profile's layer stack.
        - insert:
            - id: dsh-market
              name: 'dshmarket'
        """
        #expect(PluginInventory.ids(inPatch: text) == ["dsh-market"])
    }

    @Test func extractsMultipleIDsInOrder() {
        let text = """
        # from self
        - insert:
            - id: web-ui-compat
              name: '@linxin666/dsh-web-ui-all'

        # from ../dsh-web-settings
        - insert:
            - id: web-ui-settings
              name: '@linxin666/dsh-client-ui-web-ui-settings'
        """
        #expect(PluginInventory.ids(inPatch: text) == ["web-ui-compat", "web-ui-settings"])
    }

    @Test func extractsIDsFromProfileLevelDisableEntries() {
        // profile 自己的 cordis.patch.yml 是另一种形状（id + disabled）
        let text = """
        - id: ui-skin-miku
          disabled: true
        - id: web-ui-pet
          disabled: false
        """
        #expect(PluginInventory.ids(inPatch: text) == ["ui-skin-miku", "web-ui-pet"])
    }

    @Test func ignoresCommentedOutIDs() {
        let text = """
        # - id: not-a-plugin
        - id: real-plugin
        """
        #expect(PluginInventory.ids(inPatch: text) == ["real-plugin"])
    }

    @Test func stripsQuotesAndInlineComments() {
        let text = """
        - id: "quoted-plugin"
        - id: 'single-quoted'
        - id: bare-plugin # 说明
        """
        #expect(PluginInventory.ids(inPatch: text) == ["quoted-plugin", "single-quoted", "bare-plugin"])
    }

    @Test func ignoresNameAndOtherFields() {
        let text = """
        - insert:
            - id: only-this
              name: 'some-package'
              identifier: not-an-id
        """
        #expect(PluginInventory.ids(inPatch: text) == ["only-this"])
    }

    @Test func emptyPatchYieldsNothing() {
        #expect(PluginInventory.ids(inPatch: "[]").isEmpty)
        #expect(PluginInventory.ids(inPatch: "").isEmpty)
    }

    // MARK: 条目自己声明的包名

    @Test func pairsEachIDWithTheNameAtTheSameColumn() {
        // id 与 name 的归属只能靠列判断：第三方 bundle 的 patch 里
        // 「重新配置一个第一方条目」是合法写法，名字就写在这里
        let text = """
        - insert:
            - id: session-rdb
              name: "@morlay/session-rdb"
            - id: session-branch
              name: "@morlay/session-branch"
        """
        #expect(PluginInventory.entries(inPatch: text) == [
            PatchEntry(id: "session-rdb", name: "@morlay/session-rdb"),
            PatchEntry(id: "session-branch", name: "@morlay/session-branch"),
        ])
    }

    @Test func nestedNameIsNotTheEntryName() {
        // config 里的 name 是插件自己的配置项，缩进更深；认成条目名就会把
        // 第三方插件当第一方留下来（或者反过来）
        let text = """
        - insert:
            - id: session-rdb
              config:
                type: sqlite
                name: sessions
        """
        #expect(PluginInventory.entries(inPatch: text) == [PatchEntry(id: "session-rdb", name: nil)])
    }

    @Test func nameOnANewListEntryDoesNotAttachToThePreviousID() {
        // 行首的 `-` 就是另起一条，哪怕列对得上也不能算上一条的名字
        let text = """
        - insert:
            - id: only-this
            - name: '@deepseek-ai/not-its-name'
        """
        #expect(PluginInventory.entries(inPatch: text) == [PatchEntry(id: "only-this", name: nil)])
    }

    @Test func entriesKeepDuplicatesSoTheirNamesSurvive() {
        // 去重发生在 ids()/scan() 里。entries() 保留每一次出现，否则先出现的那次
        // 没写 name，后出现的那次写了 name 也会被丢掉
        let text = """
        - id: session-persistence-jsonl
          disabled: true
        - id: session-persistence-jsonl
          name: '@deepseek-ai/dsh-session-persistence-jsonl'
        """
        #expect(PluginInventory.entries(inPatch: text).count == 2)
        #expect(PluginInventory.ids(inPatch: text) == ["session-persistence-jsonl"])
    }

    // MARK: 第一方判定

    @Test func deepseekBundlesAreFirstParty() {
        // 安全模式必须留下 dsh 自己的 Web 界面，否则界面根本起不来，等于没恢复
        #expect(PluginInventory.isFirstParty(bundle: "@deepseek-ai/dsh-base"))
        #expect(PluginInventory.isFirstParty(bundle: "@deepseek-ai/dsh-web-app"))
    }

    @Test func communityBundlesAreNotFirstParty() {
        #expect(PluginInventory.isFirstParty(bundle: "dshmarket") == false)
        #expect(PluginInventory.isFirstParty(bundle: "@linxin666/dsh-web-ui-all") == false)
        #expect(PluginInventory.isFirstParty(bundle: "dsh-balance-tracker") == false)
        // 名字里带 deepseek 但不是它的 scope，不能算第一方
        #expect(PluginInventory.isFirstParty(bundle: "deepseek-ai-lookalike") == false)
    }

    @Test func theEntryNameOutranksTheBundleItWasFoundIn() {
        // 实测的致命形状：第一方条目写在第三方 bundle 的 patch 里。只按 bundle 判，
        // 安全模式会把内置的会话持久化插件一起禁掉，sessionPersistence 没人提供，
        // 四个第一方插件卡在 pending，dsh 直接起不来 —— 安全模式成了起不来的原因
        let borrowed = PluginRef(id: "session-persistence-jsonl",
                                 bundle: "@linxin666/dsh-perf",
                                 name: "@deepseek-ai/dsh-session-persistence-jsonl")
        #expect(PluginInventory.isFirstParty(borrowed))
    }

    @Test func aThirdPartyNameIsNotRescuedByAFirstPartyBundle() {
        // 反方向也得成立：第一方 bundle 里插进来的第三方条目仍然是第三方
        let inserted = PluginRef(id: "web-ui-pet",
                                 bundle: "@deepseek-ai/dsh-web-app",
                                 name: "@linxin666/dsh-web-ui-all")
        #expect(PluginInventory.isFirstParty(inserted) == false)
    }

    @Test func withoutANameTheBundleStillDecides() {
        // profile 自己手写的条目、以及 bundle patch 里没写 name 的行，只有 bundle 可依据
        #expect(PluginInventory.isFirstParty(PluginRef(id: "x", bundle: "@deepseek-ai/dsh-base")))
        #expect(PluginInventory.isFirstParty(PluginRef(id: "x", bundle: "profile")) == false)
    }

    // MARK: 待禁用清单

    @Test func onlyThirdPartyPluginsGetDisabled() {
        let plugins = [
            PluginRef(id: "core", bundle: "@deepseek-ai/dsh-base"),
            PluginRef(id: "web-ui-pet", bundle: "@linxin666/dsh-web-ui-all"),
            PluginRef(id: "dsh-market", bundle: "dshmarket"),
        ]
        #expect(PluginInventory.thirdPartyIDs(in: plugins) == ["dsh-market", "web-ui-pet"])
    }

    @Test func disableListIsDeduplicatedAndSorted() {
        // 同一个 id 可能既由 bundle 插入、又在 profile 的 patch 里出现
        let plugins = [
            PluginRef(id: "b", bundle: "x"),
            PluginRef(id: "a", bundle: "y"),
            PluginRef(id: "b", bundle: "profile"),
        ]
        #expect(PluginInventory.thirdPartyIDs(in: plugins) == ["a", "b"])
    }

    @Test func aFirstPartyEntryInsideAThirdPartyBundleIsNotDisabled() {
        let plugins = [
            PluginRef(id: "session-rdb", bundle: "@morlay/better-session", name: "@morlay/session-rdb"),
            PluginRef(id: "session-persistence-jsonl", bundle: "@linxin666/dsh-perf",
                      name: "@deepseek-ai/dsh-session-persistence-jsonl"),
        ]
        #expect(PluginInventory.thirdPartyIDs(in: plugins) == ["session-rdb"])
    }

    // MARK: 扫描真实目录结构

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-plugins-\(UUID().uuidString)")
        let modules = root.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: modules.appendingPathComponent("@deepseek-ai/dsh-web-app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modules.appendingPathComponent("community-bundle"), withIntermediateDirectories: true)

        let packageJSON = """
        {"dsh":{"profile":{"bundles":["@deepseek-ai/dsh-web-app","community-bundle","missing-bundle"]}}}
        """
        try packageJSON.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "- insert:\n    - id: web-app\n".write(
            to: modules.appendingPathComponent("@deepseek-ai/dsh-web-app/cordis.patch.yml"),
            atomically: true, encoding: .utf8
        )
        try "- insert:\n    - id: community-thing\n".write(
            to: modules.appendingPathComponent("community-bundle/cordis.patch.yml"),
            atomically: true, encoding: .utf8
        )
        try "- id: hand-added\n  disabled: false\n".write(
            to: root.appendingPathComponent("cordis.patch.yml"),
            atomically: true, encoding: .utf8
        )
        return root
    }

    @Test func scanAttributesEachIDToItsBundle() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugins = PluginInventory.scan(profileDirectory: root)
        #expect(plugins.contains(PluginRef(id: "web-app", bundle: "@deepseek-ai/dsh-web-app")))
        #expect(plugins.contains(PluginRef(id: "community-thing", bundle: "community-bundle")))
    }

    @Test func scanToleratesBundlesThatAreNotInstalled() throws {
        // package.json 里列了但 node_modules 下没有——安装未完成时很常见，不能整体失败
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PluginInventory.scan(profileDirectory: root).isEmpty == false)
    }

    @Test func scanIncludesHandAddedProfileEntries() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = PluginInventory.scan(profileDirectory: root).map(\.id)
        #expect(ids.contains("hand-added"))
    }

    @Test func handAddedEntriesCountAsThirdParty() throws {
        // 用户自己写进 profile patch 的 id 来源不明，安全模式应当把它关掉
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let disable = PluginInventory.thirdPartyIDs(in: PluginInventory.scan(profileDirectory: root))
        #expect(disable.contains("hand-added"))
        #expect(disable.contains("community-thing"))
        #expect(disable.contains("web-app") == false)
    }

    @Test func scanOfMissingDirectoryIsEmptyNotACrash() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(PluginInventory.scan(profileDirectory: missing).isEmpty)
    }

    // MARK: 同一个 id 出现在多份 patch 里

    /// 造一个 profile，bundle 名与 patch 内容按给定顺序写进 `dsh.profile.bundles`。
    private func profile(bundles: [(name: String, patch: String)]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-order-\(UUID().uuidString)")
        let modules = root.appendingPathComponent("node_modules")
        for bundle in bundles {
            let directory = modules.appendingPathComponent(bundle.name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bundle.patch.write(to: directory.appendingPathComponent("cordis.patch.yml"),
                                   atomically: true, encoding: .utf8)
        }
        let names = bundles.map { "\"\($0.name)\"" }.joined(separator: ",")
        try "{\"dsh\":{\"profile\":{\"bundles\":[\(names)]}}}"
            .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        return root
    }

    /// 实测形状：一个第三方 bundle 关掉内置的持久化插件并换成自己的 sqlite 实现，
    /// 另一个第三方 bundle 给同一个内置插件改配置、并写明了它的第一方包名。
    private static let replacesPersistence = """
    - id: session-persistence-jsonl
      disabled: true

    - insert:
        - id: session-rdb
          name: "@morlay/session-rdb"
          config:
            type: sqlite
    """

    private static let reconfiguresPersistence = """
    # from ../dsh-perf (patch row session-persistence-jsonl)
    - id: session-persistence-jsonl
      name: '@deepseek-ai/dsh-session-persistence-jsonl'
      config:
        root: !!js dshHomePath('sessions')
    """

    @Test(arguments: [false, true])
    func aFirstPartyEntryWinsRegardlessOfBundleOrder(reversed: Bool) throws {
        // bundles 的排列就是用户装插件的顺序，我们无从控制。先到先得的话，
        // 「谁先写了这个 id」决定安全模式会不会把第一方条目一起禁掉 —— 一半的概率启动失败
        var listed = [
            (name: "@morlay/better-session", patch: Self.replacesPersistence),
            (name: "@linxin666/dsh-perf", patch: Self.reconfiguresPersistence),
        ]
        if reversed { listed.reverse() }

        let root = try profile(bundles: listed)
        defer { try? FileManager.default.removeItem(at: root) }

        let disable = PluginInventory.thirdPartyIDs(in: PluginInventory.scan(profileDirectory: root))
        #expect(disable == ["session-rdb"])
    }
}

// MARK: - 安全模式 overlay

/// overlay 写进应用自己的目录，`--patch` 传给 dsh，**绝不改动 `~/.dsh`**：
/// 那是用户和其它 dsh 版本共享的状态，安全模式没有资格改写它。
struct SafeModeOverlayTests {

    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    @Test func rendersOneDisabledEntryPerPlugin() {
        let yaml = SafeModeOverlay.render(disabling: ["a", "b"], generatedAt: now)
        #expect(yaml.contains("- id: a"))
        #expect(yaml.contains("- id: b"))
        #expect(yaml.components(separatedBy: "disabled: true").count - 1 == 2)
    }

    @Test func idsAreSortedForAStableDiff() {
        let yaml = SafeModeOverlay.render(disabling: ["z", "a"], generatedAt: now)
        let aIndex = yaml.range(of: "- id: a")?.lowerBound
        let zIndex = yaml.range(of: "- id: z")?.lowerBound
        #expect(aIndex != nil && zIndex != nil && aIndex! < zIndex!)
    }

    @Test func headerExplainsWhereTheFileCameFrom() {
        // 用户在磁盘上看到这个文件时必须能立刻知道是谁写的、能不能删
        let yaml = SafeModeOverlay.render(disabling: ["a"], generatedAt: now)
        #expect(yaml.contains("Harness"))
        #expect(yaml.hasPrefix("#"))
    }

    @Test func emptyListStillProducesValidYaml() {
        // 没有第三方插件时也要写出一个合法的空 overlay，不能写出半个文件
        let yaml = SafeModeOverlay.render(disabling: [], generatedAt: now)
        #expect(yaml.contains("[]"))
    }

    @Test func overlayLivesInTheAppsOwnDirectory() {
        let path = SafeModeOverlay.defaultURL.path
        #expect(path.contains("Application Support/Harness"))
        #expect(path.contains("/.dsh/") == false)
    }

    @Test func writesToDiskCreatingIntermediateDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-safe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("nested/safe-mode.yml")
        try SafeModeOverlay.write(disabling: ["a"], to: target, generatedAt: now)
        let written = try String(contentsOf: target, encoding: .utf8)
        #expect(written.contains("- id: a"))
    }

    @Test func rewriteReplacesThePreviousContent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-safe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("safe-mode.yml")
        try SafeModeOverlay.write(disabling: ["old"], to: target, generatedAt: now)
        try SafeModeOverlay.write(disabling: ["new"], to: target, generatedAt: now)
        let written = try String(contentsOf: target, encoding: .utf8)
        #expect(written.contains("old") == false)
        #expect(written.contains("- id: new"))
    }

    /// 用 dsh 自带的 yaml 解析器验证 overlay 真的能被读成期望的结构。
    /// 自己拼字符串最容易出的错就是缩进——那种错误只有真解析器能发现。
    @Test func renderedOverlayParsesAsASequenceOfDisabledEntries() throws {
        let yamlModule = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".dsh/profiles/web/node_modules/yaml/dist/index.js")
        guard FileManager.default.isReadableFile(atPath: yamlModule.path) else { return } // CI 无 dsh profile

        let overlay = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-overlay-\(UUID().uuidString).yml")
        defer { try? FileManager.default.removeItem(at: overlay) }
        try SafeModeOverlay.write(disabling: ["plugin-a", "plugin-b"], to: overlay, generatedAt: now)

        let script = "const YAML=require(\(escaped(yamlModule.path)));"
            + "const fs=require('fs');"
            + "const doc=YAML.parse(fs.readFileSync(\(escaped(overlay.path)),'utf8'));"
            + "process.stdout.write(JSON.stringify(doc));"
        guard let output = runNode(script) else { return } // 没有可用的 node 就跳过
        #expect(output == #"[{"id":"plugin-a","disabled":true},{"id":"plugin-b","disabled":true}]"#)
    }

    private func escaped(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private func runNode(_ script: String) -> String? {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        guard let node = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            ?? newestNVMNode() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func newestNVMNode() -> String? {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return versions.map { $0.appendingPathComponent("bin/node").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - 安全模式开关的持久化

/// 崩溃时进程没了，「下次以安全模式启动」这个决定必须留在磁盘上。
struct SafeModeStoreTests {

    private func store() -> SafeModeStore {
        SafeModeStore(defaults: UserDefaults(suiteName: "harness-safe-\(UUID().uuidString)")!)
    }

    @Test func defaultsToOff() {
        #expect(store().isEnabled == false)
    }

    @Test func enableThenDisable() {
        let subject = store()
        subject.enable()
        #expect(subject.isEnabled)
        subject.disable()
        #expect(subject.isEnabled == false)
    }

    @Test func survivesANewStoreOverTheSameDefaults() {
        let defaults = UserDefaults(suiteName: "harness-safe-\(UUID().uuidString)")!
        SafeModeStore(defaults: defaults).enable()
        #expect(SafeModeStore(defaults: defaults).isEnabled)
    }
}
