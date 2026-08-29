import Foundation
import Testing
@testable import DSHWeb

// MARK: - 诊断报告

/// 报告是给 issue 用的：既要包含足够的排障信息，也不能把用户的密钥一起带出去。
/// 渲染是纯函数，环境事实全部由调用方注入，便于在这里逐项固定格式。
struct DiagnosticsReportTests {

    private func environment(
        state: String = "running(port: 3080)",
        logFiles: [String] = ["harness-2026-08-29.log"],
        nodePath: String? = "/Users/me/.nvm/versions/node/v24.13.0/bin/node"
    ) -> DiagnosticsReport.Environment {
        DiagnosticsReport.Environment(
            appVersion: "0.2.1",
            appBuild: "25",
            osVersion: "15.0",
            architecture: "arm64",
            nodePath: nodePath,
            bootJSPath: "/Users/me/.npm/_npx/1e7f6d9597241db0/node_modules/@deepseek-ai/dsh/lib/bin.js",
            port: 3080,
            state: state,
            language: "zh",
            logDirectory: "/Users/me/Library/Logs/Harness",
            logFiles: logFiles,
            generatedAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
    }

    // MARK: 必须出现的内容

    @Test func includesVersionAndPlatformFacts() {
        let report = DiagnosticsReport.render(environment: environment(), logTail: [])
        #expect(report.contains("0.2.1"))
        #expect(report.contains("25"))
        #expect(report.contains("15.0"))
        #expect(report.contains("arm64"))
    }

    @Test func includesServiceStateAndPort() {
        let report = DiagnosticsReport.render(environment: environment(state: "failed(找不到 Node.js)"), logTail: [])
        #expect(report.contains("failed(找不到 Node.js)"))
        #expect(report.contains("3080"))
    }

    @Test func includesResolvedRuntimePaths() {
        let report = DiagnosticsReport.render(environment: environment(), logTail: [])
        #expect(report.contains("v24.13.0/bin/node"))
        #expect(report.contains("@deepseek-ai/dsh/lib/bin.js"))
    }

    @Test func listsLogFilesAndDirectory() {
        let report = DiagnosticsReport.render(
            environment: environment(logFiles: ["harness-2026-08-28.log", "harness-2026-08-29.log"]),
            logTail: []
        )
        #expect(report.contains("/Users/me/Library/Logs/Harness"))
        #expect(report.contains("harness-2026-08-28.log"))
        #expect(report.contains("harness-2026-08-29.log"))
    }

    @Test func includesLogTailInOriginalOrder() {
        let report = DiagnosticsReport.render(environment: environment(), logTail: ["第一行", "第二行", "第三行"])
        let first = report.range(of: "第一行")
        let third = report.range(of: "第三行")
        #expect(first != nil)
        #expect(third != nil)
        if let first, let third { #expect(first.lowerBound < third.lowerBound) }
    }

    // MARK: 缺失与空值

    @Test func marksUnresolvedRuntimeExplicitly() {
        // Node 没找到本身就是最常见的失败原因，报告里必须能看出「没解析到」而不是空白
        let report = DiagnosticsReport.render(environment: environment(nodePath: nil), logTail: [])
        #expect(report.contains("未解析"))
    }

    @Test func rendersWithoutLogsPresent() {
        let report = DiagnosticsReport.render(environment: environment(logFiles: []), logTail: [])
        #expect(report.isEmpty == false)
        #expect(report.contains("Harness"))
    }

    // MARK: 脱敏

    @Test func masksSecretsThatSlippedIntoTheTail() {
        // 兜底：内存缓冲区里的行本已脱敏，但报告是最后一道出口，再过一遍
        let report = DiagnosticsReport.render(
            environment: environment(),
            logTail: ["Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature"]
        )
        #expect(report.contains("Authorization: ****"))
        #expect(report.contains("eyJhbGciOiJIUzI1NiJ9") == false)
    }

    @Test func masksSecretsInEnvironmentFields() {
        let report = DiagnosticsReport.render(
            environment: environment(state: "failed(密钥 sk-abcdefghijklmnopqrst 无效)"),
            logTail: []
        )
        #expect(report.contains("sk-****"))
        #expect(report.contains("abcdefghij") == false)
    }

    // MARK: 文件名

    @Test func suggestsTimestampedFileName() {
        let name = DiagnosticsReport.suggestedFileName(at: Date(timeIntervalSince1970: 1_787_000_000),
                                                       timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        #expect(name.hasPrefix("Harness-diagnostics-"))
        #expect(name.hasSuffix(".txt"))
        // 文件名不能含空格/冒号，否则贴到终端还得转义
        #expect(name.contains(" ") == false)
        #expect(name.contains(":") == false)
    }
}
