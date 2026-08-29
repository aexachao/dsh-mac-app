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
        nodePath: String? = "/Users/me/.nvm/versions/node/v24.13.0/bin/node",
        safeMode: Bool = false,
        disabledPlugins: [String] = [],
        runtimeSource: String? = "bundled",
        bundledRuntime: String? = "dsh 0.1.1-rc.2 / node 24.20.0 (arm64)",
        prefersMachineRuntime: Bool = false
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
            generatedAt: Date(timeIntervalSince1970: 1_787_000_000),
            safeMode: safeMode,
            disabledPlugins: disabledPlugins,
            runtimeSource: runtimeSource,
            bundledRuntime: bundledRuntime,
            prefersMachineRuntime: prefersMachineRuntime
        )
    }

    // MARK: 运行时来源
    //
    // 捆绑之后，「哪一份运行时」是读 issue 时第一个要问的问题：捆绑那份跑不起来是我们发错了
    // 版本，本机那份跑不起来是用户机器上的状态。报告分不清这两者，等于把最关键的一条线索
    // 留给来回追问。

    @Test func statesWhichRuntimeIsInUse() {
        let report = DiagnosticsReport.render(environment: environment(runtimeSource: "machine"), logTail: [])
        #expect(report.contains("machine"))
    }

    @Test func includesBundledRuntimeVersions() {
        // 我们这一版捆绑了哪个 dsh，只能由应用自己报——用户看不到 manifest.json
        let report = DiagnosticsReport.render(environment: environment(), logTail: [])
        #expect(report.contains("dsh 0.1.1-rc.2 / node 24.20.0 (arm64)"))
    }

    @Test func marksMissingBundleExplicitly() {
        // 开发构建（swift run）没有 .app 外壳，捆绑那份不存在；空白会被当成报告漏字段
        let report = DiagnosticsReport.render(
            environment: environment(runtimeSource: "machine", bundledRuntime: nil),
            logTail: []
        )
        #expect(report.contains("未解析"))
    }

    @Test func statesTheEscapeHatchPreference() {
        // 用户打开过「改用本机 dsh」又忘了，表现就是 dsh 版本莫名其妙地旧。
        // 报告里写明这一条，能省掉一整轮来回追问。
        let on = DiagnosticsReport.render(environment: environment(prefersMachineRuntime: true), logTail: [])
        let off = DiagnosticsReport.render(environment: environment(prefersMachineRuntime: false), logTail: [])
        #expect(on.contains("Prefer machine: on"))
        #expect(off.contains("Prefer machine: off"))
    }

    // MARK: 安全模式

    @Test func safeModeIsStatedInTheReport() {
        // 安全模式下界面少了插件，报障时如果不写明，看 issue 的人会照着一个不完整的
        // 环境去复现
        let report = DiagnosticsReport.render(
            environment: environment(safeMode: true, disabledPlugins: ["dsh-market", "web-ui-pet"]),
            logTail: []
        )
        #expect(report.contains("dsh-market"))
        #expect(report.contains("web-ui-pet"))
    }

    @Test func normalModeSaysSoExplicitly() {
        // 留空会让人以为报告漏了字段
        let report = DiagnosticsReport.render(environment: environment(), logTail: [])
        #expect(report.lowercased().contains("safe mode"))
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
