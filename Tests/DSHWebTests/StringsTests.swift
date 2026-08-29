import Foundation
import Testing
@testable import DSHWeb

// MARK: - 界面文案表

struct StringsTests {

    @Test func everyKeyHasBothLanguages() {
        // 这条断言是整张表存在的理由：中文写完就交付、英文位留空，
        // 英文用户看到的就是一片空白控件。
        for key in Strings.Key.allCases {
            let text = Strings.localized(key)
            #expect(text.zh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                    "\(key) 缺中文")
            #expect(text.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                    "\(key) 缺英文")
        }
    }

    @Test func englishNeverContainsChineseCharacters() {
        // 真正会发生的漏译是「英文位直接抄了中文」，比留空更难被发现
        for key in Strings.Key.allCases {
            #expect(containsCJK(Strings.localized(key).en) == false, "\(key) 的英文文案里有中文字符")
        }
    }

    @Test func placeholdersMatchAcrossLanguages() {
        // 占位符对不上意味着某一种语言里会漏掉端口号/数量这类关键信息
        for key in Strings.Key.allCases {
            let text = Strings.localized(key)
            #expect(placeholders(in: text.zh) == placeholders(in: text.en),
                    "\(key) 的占位符两种语言不一致")
        }
    }

    @Test func languageSelectionPicksTheMatchingSide() {
        let text = LocalizedText(zh: "甲", en: "A")
        #expect(text.value(.zh) == "甲")
        #expect(text.value(.en) == "A")
    }

    @Test func substitutionFillsPlaceholders() {
        let zh = Strings.text(.statusRunning, .zh, substituting: ["port": "3080"])
        #expect(zh.contains("3080"))
        #expect(zh.contains("{") == false)
        let en = Strings.text(.statusRunning, .en, substituting: ["port": "3080"])
        #expect(en.contains("3080"))
        #expect(en.contains("{") == false)
    }

    @Test func missingSubstitutionLeavesThePlaceholderVisible() {
        // 故意不静默成空串：屏幕上一个显眼的 {port} 会被立刻发现并修掉
        #expect(Strings.text(.statusRunning, .zh).contains("{port}"))
    }

    @Test func unrelatedSubstitutionsAreIgnored() {
        let text = Strings.text(.logs, .zh, substituting: ["port": "3080"])
        #expect(text == Strings.localized(.logs).zh)
    }

    // MARK: - 辅助

    private func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x3000...0x303F).contains(v)   // CJK 标点
                || (0x3040...0x30FF).contains(v)   // 假名
                || (0x3400...0x4DBF).contains(v)   // 扩展 A
                || (0x4E00...0x9FFF).contains(v)   // 基本汉字
                || (0xFF00...0xFFEF).contains(v)   // 全角形式
        }
    }

    private func placeholders(in text: String) -> Set<String> {
        var found: Set<String> = []
        var current: String?
        for character in text {
            if character == "{" {
                current = ""
            } else if character == "}", let name = current {
                found.insert(name)
                current = nil
            } else if current != nil {
                current?.append(character)
            }
        }
        return found
    }
}
