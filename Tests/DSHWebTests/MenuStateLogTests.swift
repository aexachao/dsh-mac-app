import Foundation
import Testing
@testable import DSHWeb

@Suite("菜单诊断日志")
struct MenuStateLogTests {

    @Test("周期快照结构没变就不写，变了才写")
    func tickDedupes() {
        #expect(!MenuStateLog.shouldWrite(.tick, body: "A", previousBody: "A"))
        #expect(MenuStateLog.shouldWrite(.tick, body: "B", previousBody: "A"))
        #expect(MenuStateLog.shouldWrite(.tick, body: "A", previousBody: nil))
    }

    @Test("事件型记录一律写：事件本身就是信息")
    func eventsAlwaysWrite() {
        for event in [MenuStateLog.Event.rebuildSet, .rebuildDelayed, .guardOverride] {
            #expect(event.dedupes == false)
            #expect(MenuStateLog.shouldWrite(event, body: "A", previousBody: "A"))
        }
        #expect(MenuStateLog.Event.tick.dedupes)
    }

    @Test("tag 与过去的文件格式一致")
    func rawValuesMatchLegacyTags() {
        #expect(MenuStateLog.Event.rebuildSet.rawValue == "rebuild-set")
        #expect(MenuStateLog.Event.rebuildDelayed.rawValue == "rebuild-delayed")
        #expect(MenuStateLog.Event.guardOverride.rawValue == "guard-override")
        #expect(MenuStateLog.Event.tick.rawValue == "tick")
    }

    @Test("刚好到上限不重写，超过才重写")
    func resetOnlyWhenOverLimit() {
        #expect(!MenuStateLog.shouldReset(currentSize: 90, incoming: 10, limit: 100))
        #expect(MenuStateLog.shouldReset(currentSize: 91, incoming: 10, limit: 100))
        #expect(!MenuStateLog.shouldReset(currentSize: 0, incoming: 0, limit: 100))
    }

    @Test("渲染带 tag、时间戳与结构，且自带换行")
    func entryFormat() {
        let text = MenuStateLog.entry(.guardOverride, body: "Harness: 关于|退出", timestamp: "2026-08-30 12:00:00")
        #expect(text == "=== guard-override 2026-08-30 12:00:00 ===\nHarness: 关于|退出\n")
    }

    @Test("落盘：先追加，顶破上限就从头重写，只留最近的")
    func writeAppendsThenWraps() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("menu-state-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("menu-state.log")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 目录不存在也要能写（record 首次运行就是这种情况）
        MenuStateLog.write("aaaa\n", to: url, limit: 12)
        MenuStateLog.write("bbbb\n", to: url, limit: 12)
        #expect(try String(contentsOf: url, encoding: .utf8) == "aaaa\nbbbb\n")

        // 第三条会顶破上限 → 从头重写，只留最近的那条
        MenuStateLog.write("cccc\n", to: url, limit: 12)
        let wrapped = try String(contentsOf: url, encoding: .utf8)
        #expect(wrapped.contains("从头重写"))
        #expect(wrapped.hasSuffix("cccc\n"))
        #expect(!wrapped.contains("aaaa"))
    }

    @Test("落盘位置在应用自己的日志目录，不在 /tmp")
    func writesUnderOwnLogDirectory() {
        let path = MenuStateLog.fileURL.path
        #expect(path.contains("Library/Logs/Harness"))
        #expect(!path.hasPrefix("/tmp"))
        #expect(!path.contains("/.dsh/"))
    }
}
