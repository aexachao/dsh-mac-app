import AppKit
import Testing
@testable import DSHWeb

@MainActor
struct MenuBuilderTests {

    // MARK: - 语言偏好

    @Test func defaultLanguageIsChinese() {
        // 无存储值时默认简体中文
        UserDefaults.standard.removeObject(forKey: "appLanguage")
        #expect(MenuBuilder.current == .zh)
    }

    @Test func storedLanguageIsRespected() {
        UserDefaults.standard.set("en", forKey: "appLanguage")
        #expect(MenuBuilder.current == .en)
        UserDefaults.standard.set("zh", forKey: "appLanguage")
        #expect(MenuBuilder.current == .zh)
        UserDefaults.standard.removeObject(forKey: "appLanguage")
    }

    // MARK: - 中文菜单

    @Test func chineseMenuContainsAllSections() {
        let menu = MenuBuilder.buildMenu(language: .zh)
        let appItem = menu.items.first!

        // 应用菜单核心项
        let appTitles = appItem.submenu!.items.map(\.title)
        #expect(appTitles.contains("设置…"))
        #expect(appTitles.contains("日志"))
        #expect(appTitles.contains("重启服务"))
        #expect(appTitles.contains("关于 Harness"))
        #expect(appTitles.contains("退出 Harness"))

        // 各菜单标题（中文）
        let titles = menu.items.compactMap(\.submenu?.title)
        #expect(titles.contains("文件"))
        #expect(titles.contains("编辑"))
        #expect(titles.contains("视图"))
        #expect(titles.contains("窗口"))

        // 自定义 action 的 target 已绑定（可点击）
        let logs = appItem.submenu!.items.first { $0.title == "日志" }
        #expect(logs?.target !== nil)
        #expect(logs?.action == #selector(MenuActions.toggleLogs))
        let restart = appItem.submenu!.items.first { $0.title == "重启服务" }
        #expect(restart?.target !== nil)
        #expect(restart?.action == #selector(MenuActions.restartService))

        // 日志/重启服务带图标
        #expect(logs?.image != nil)
        #expect(restart?.image != nil)
    }

    // MARK: - 英文菜单

    @Test func englishMenuContainsAllSections() {
        let menu = MenuBuilder.buildMenu(language: .en)
        let appTitles = menu.items.first!.submenu!.items.map(\.title)
        #expect(appTitles.contains("Settings…"))
        #expect(appTitles.contains("Logs"))
        #expect(appTitles.contains("Restart Service"))

        let titles = menu.items.compactMap(\.submenu?.title)
        #expect(titles.contains("File"))
        #expect(titles.contains("Edit"))
        #expect(titles.contains("View"))
        #expect(titles.contains("Window"))
    }

    // MARK: - 快捷键

    @Test func menuShortcutsAreBound() {
        let menu = MenuBuilder.buildMenu(language: .zh)
        let appItem = menu.items.first!
        let logs = appItem.submenu!.items.first { $0.title == "日志" }
        #expect(logs?.keyEquivalent == "l")
        #expect(logs?.keyEquivalentModifierMask == [.command, .shift])
        let restart = appItem.submenu!.items.first { $0.title == "重启服务" }
        #expect(restart?.keyEquivalent == "r")
        #expect(restart?.keyEquivalentModifierMask == [.command, .shift])
    }
}

// MARK: - 语言同步（dsh settings.yaml）

@MainActor
struct ServiceLanguageSyncTests {

    @Test func writesLocalePreferenceToYaml() throws {
        // 临时 settings.yaml（模拟 ~/.dsh/settings.yaml）
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let yamlFile = dir.appendingPathComponent("settings.yaml")
        try """
        ui-onboarding:
          welcomeNoticeVersion: 2026-08-13.1
        """.write(to: yamlFile, atomically: true, encoding: .utf8)

        // 用真实 node + 真实 yaml 模块写入 en。
        // CI runner 没有 ~/.dsh profile（yaml 模块不存在）→ 跳过该场景。
        let nodePath = MenuBuilder.resolveNodePath()
        let yamlPath = NSHomeDirectory() + "/.dsh/profiles/web/node_modules/yaml/dist/index.js"
        #expect(FileManager.default.isExecutableFile(atPath: nodePath))
        guard FileManager.default.isReadableFile(atPath: yamlPath) else {
            return // CI 环境：无 dsh profile，跳过 yaml 写入验证
        }
        MenuBuilder.writeLocalePreference(nodePath: nodePath, settingsPath: yamlFile.path, yamlPath: yamlPath, language: .en)

        let content = try String(contentsOf: yamlFile, encoding: .utf8)
        #expect(content.contains("locale:"))
        #expect(content.contains("preference: en"))

        // 再写 zh
        MenuBuilder.writeLocalePreference(nodePath: nodePath, settingsPath: yamlFile.path, yamlPath: yamlPath, language: .zh)
        let contentZh = try String(contentsOf: yamlFile, encoding: .utf8)
        #expect(contentZh.contains("preference: zh"))
        // 原有内容保留
        #expect(contentZh.contains("welcomeNoticeVersion"))
    }
}
