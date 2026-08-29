import Foundation
import Testing
@testable import DSHWeb

// MARK: - 失败原因分类

/// 「服务意外退出（exit 1）」对用户毫无用处：他既不知道哪里错了，也不知道下一步该做什么。
/// 分类逻辑做成纯函数，保证每种失败都有可读原因和至少一个可操作的下一步。
struct FailureCauseTests {

    // MARK: 从退出码与日志尾部分类

    @Test func configValidationErrorIsRecognizedFromLogTail() {
        // 本机上最真实的一次失败：dsh 因共享状态文件格式不符而拒绝启动
        let cause = FailureCause.classify(exitStatus: 1, logTail: [
            "[12:00:00] [dsh-web] 服务进程已启动 (PID 123)",
            #"[12:00:01] credentials-local: the value for "version" in /Users/me/.dsh/.credentials.yaml must be a string"#,
        ])
        guard case .invalidConfig(let path, let message) = cause else {
            Issue.record("应识别为配置错误，实际为 \(cause)")
            return
        }
        #expect(path == "/Users/me/.dsh/.credentials.yaml")
        #expect(message.contains("must be a string"))
    }

    @Test func configErrorTakesPrecedenceOverPlainExit() {
        // 日志里已经写明了原因，就不该退回「未知退出」
        let cause = FailureCause.classify(exitStatus: 1, logTail: [
            "some.yaml: broken",
            "field \"x\" in /Users/me/.dsh/settings.yml is invalid",
        ])
        #expect(cause != .abnormalExit(status: 1, message: nil))
    }

    @Test func yamlPathWithoutValidationVerbIsNotAConfigError() {
        // 只是提到某个 yaml 文件（例如「已写入」）不代表配置有问题
        let cause = FailureCause.classify(exitStatus: 1, logTail: [
            "已写入 /Users/me/.dsh/settings.yaml",
        ])
        guard case .abnormalExit = cause else {
            Issue.record("不该判成配置错误，实际为 \(cause)")
            return
        }
    }

    @Test func lastErrorLineBecomesTheMessageOfAnAbnormalExit() {
        let cause = FailureCause.classify(exitStatus: 3, logTail: [
            "[12:00:00] boot",
            "[12:00:01] Error: cannot find module 'foo'",
            "[12:00:02] [dsh-web] 服务进程已启动 (PID 1)",
        ])
        #expect(cause == .abnormalExit(status: 3, message: "Error: cannot find module 'foo'"))
    }

    @Test func emptyLogTailStillClassifies() {
        #expect(FailureCause.classify(exitStatus: 9, logTail: []) == .abnormalExit(status: 9, message: nil))
    }

    @Test func classificationIgnoresOurOwnPrefixedLines() {
        // 应用自己写的行（[dsh-web] 前缀）不是服务的报错，不能当成原因
        let cause = FailureCause.classify(exitStatus: 1, logTail: [
            "[12:00:00] [dsh-web] ❌ 服务意外退出（exit 1），详见日志。",
        ])
        #expect(cause == .abnormalExit(status: 1, message: nil))
    }

    // MARK: 捆绑运行时与 ~/.dsh 的版本错位
    //
    // 捆绑之后多出来的一整类失败：我们发的 dsh 是定版的，而 `~/.dsh` 是用户和别的 dsh
    // 共用的状态——更新版 dsh（比如官方 Electron 客户端）迁移过配置之后，我们这份就读不
    // 懂了。对用户来说这既不是他的错也不是他能改的，唯一的出路是改用他机器上那份新的，
    // 而不是去 Finder 里手改 yaml。

    private let skewLog = [
        "[12:00:00] [dsh-web] 服务进程已启动 (PID 123)",
        #"[12:00:01] credentials-local: the value for "version" in /Users/me/.dsh/.credentials.yaml must be a string"#,
    ]

    @Test func bundledRuntimeConfigRejectionIsClassifiedAsSkew() {
        let cause = FailureCause.classify(
            exitStatus: 1, logTail: skewLog,
            runtime: .init(source: .bundled, bundledVersion: "dsh 0.1.1-rc.2 / node 24.20.0 (arm64)")
        )
        guard case .runtimeVersionSkew(let bundled, let path, _) = cause else {
            Issue.record("捆绑运行时下的配置格式错误应识别为版本错位，实际为 \(cause)")
            return
        }
        #expect(bundled == "dsh 0.1.1-rc.2 / node 24.20.0 (arm64)")
        #expect(path == "/Users/me/.dsh/.credentials.yaml")
    }

    @Test func machineRuntimeConfigRejectionStaysInvalidConfig() {
        // 跑的是用户自己那份 dsh 时，「改用本机 dsh」没有意义——已经在用了
        let cause = FailureCause.classify(
            exitStatus: 1, logTail: skewLog,
            runtime: .init(source: .machine, bundledVersion: nil)
        )
        guard case .invalidConfig = cause else {
            Issue.record("本机运行时下应保持配置错误分类，实际为 \(cause)")
            return
        }
    }

    @Test func unknownRuntimeFallsBackToInvalidConfig() {
        // 不知道是哪一份在跑时选保守的那一类：推荐一个可能毫无作用的逃生开关，
        // 比让用户去看文件更糟
        let cause = FailureCause.classify(exitStatus: 1, logTail: skewLog)
        guard case .invalidConfig = cause else {
            Issue.record("未知运行时应退回配置错误分类，实际为 \(cause)")
            return
        }
    }

    @Test func skewMakesTheEscapeHatchThePrimaryAction() {
        // 这一类失败里「重试」必然再失败一次，不能是被强调的那个按钮
        let cause = FailureCause.runtimeVersionSkew(
            bundled: "dsh 0.1.1-rc.2 / node 24.20.0 (arm64)",
            path: "/Users/me/.dsh/.credentials.yaml",
            message: "must be a string"
        )
        #expect(cause.primaryAction == .useMachineRuntime)
        #expect(cause.actions.contains(.retry)) // 手改过配置的用户仍需要一个普通重试入口
    }

    @Test func skewDetailNamesTheBundledVersionAndFile() {
        // 用户看不到 manifest.json：不写版本，他无法判断该等我们更新还是自己动手
        let cause = FailureCause.runtimeVersionSkew(
            bundled: "dsh 0.1.1-rc.2 / node 24.20.0 (arm64)",
            path: "/Users/me/.dsh/.credentials.yaml",
            message: "must be a string"
        )
        for language in AppLanguage.allCases {
            #expect(cause.detail(language).contains("0.1.1-rc.2"))
            #expect(cause.detail(language).contains(".credentials.yaml"))
        }
    }

    @Test func skewWithoutAManifestStillReadsWell() {
        // manifest 缺失（捆绑被裁过）时不能出现「内置版本 nil」这种文案
        let cause = FailureCause.runtimeVersionSkew(
            bundled: nil, path: "/Users/me/.dsh/settings.yaml", message: "is invalid"
        )
        for language in AppLanguage.allCases {
            #expect(cause.detail(language).lowercased().contains("nil") == false)
            #expect(cause.detail(language).isEmpty == false)
        }
    }

    // MARK: 每种原因都要能说清楚、且有下一步

    private let all: [FailureCause] = [
        .nodeMissing,
        .portExhausted(from: 3080, scanned: 32),
        .npxUnavailable("permission denied"),
        .npxTimeout(seconds: 180),
        .bootJSMissing,
        .spawnFailed("no such file"),
        .readinessTimeout(seconds: 90),
        .invalidConfig(path: "/Users/me/.dsh/.credentials.yaml", message: "must be a string"),
        .runtimeVersionSkew(bundled: "dsh 0.1.1-rc.2 / node 24.20.0 (arm64)",
                            path: "/Users/me/.dsh/.credentials.yaml",
                            message: "must be a string"),
        .abnormalExit(status: 1, message: "Error: boom"),
    ]

    @Test func everyCauseHasBilingualTitleAndDetail() {
        for cause in all {
            for language in AppLanguage.allCases {
                #expect(!cause.title(language).isEmpty, "\(cause) 缺 \(language) 标题")
                #expect(!cause.detail(language).isEmpty, "\(cause) 缺 \(language) 说明")
            }
        }
    }

    @Test func everyCauseOffersAtLeastOneAction() {
        for cause in all {
            #expect(!cause.actions.isEmpty, "\(cause) 没有可操作的下一步")
        }
    }

    @Test func everyCauseCanBeRetried() {
        // 重试是唯一对所有失败都成立的动作：环境问题修好后用户需要一个入口
        for cause in all {
            #expect(cause.actions.contains(.retry), "\(cause) 无法重试")
        }
    }

    @Test func exactlyOnePrimaryActionPerCause() {
        // 主按钮由原因挑（`primaryAction`），不是动作自带的属性：同一个「重试」在版本
        // 错位里必然再失败一次，不该被强调；两个都强调等于没强调。
        for cause in all {
            guard let primary = cause.primaryAction else {
                Issue.record("\(cause) 没有主按钮")
                continue
            }
            #expect(cause.actions.contains(primary), "\(cause) 的主按钮不在动作列表里")
        }
    }

    @Test func retryStaysThePrimaryActionForEverythingButSkew() {
        // 引入 `primaryAction` 不能顺手改掉既有失败的强调按钮
        for cause in all {
            if case .runtimeVersionSkew = cause { continue }
            #expect(cause.primaryAction == .retry, "\(cause) 的主按钮不再是重试")
        }
    }

    // MARK: 原因专属的可操作动作

    @Test func nodeMissingLinksToTheNodeDownloadPage() {
        // 缺 Node 是最常见的首次启动失败，直接给下载入口
        let opens = FailureCause.nodeMissing.actions.compactMap { action -> URL? in
            if case .open(let url) = action { return url }
            return nil
        }
        #expect(opens.contains { $0.host?.contains("nodejs.org") == true })
    }

    @Test func invalidConfigRevealsTheOffendingFile() {
        let path = "/Users/me/.dsh/.credentials.yaml"
        let cause = FailureCause.invalidConfig(path: path, message: "must be a string")
        #expect(cause.actions.contains(.reveal(path: path)))
    }

    @Test func invalidConfigDetailNamesTheFile() {
        // 只说「配置有问题」等于没说，必须点名文件
        let cause = FailureCause.invalidConfig(path: "/Users/me/.dsh/.credentials.yaml", message: "must be a string")
        #expect(cause.detail(.zh).contains(".credentials.yaml"))
        #expect(cause.detail(.en).contains(".credentials.yaml"))
    }

    @Test func abnormalExitDetailCarriesTheExitStatus() {
        #expect(FailureCause.abnormalExit(status: 7, message: nil).detail(.zh).contains("7"))
    }

    @Test func abnormalExitWithMessageShowsIt() {
        #expect(FailureCause.abnormalExit(status: 1, message: "Error: boom").detail(.zh).contains("Error: boom"))
    }

    @Test func portExhaustedDetailNamesTheScannedRange() {
        let detail = FailureCause.portExhausted(from: 3080, scanned: 32).detail(.zh)
        #expect(detail.contains("3080"))
        #expect(detail.contains("32"))
    }

    @Test func diagnosticsIsOfferedForCausesUsersCannotFixThemselves() {
        // 这两类是「请把日志给我」的典型场景
        #expect(FailureCause.abnormalExit(status: 1, message: nil).actions.contains(.exportDiagnostics))
        #expect(FailureCause.readinessTimeout(seconds: 90).actions.contains(.exportDiagnostics))
    }

    // MARK: 出口脱敏

    @Test func detailIsMaskedOnTheWayOut() {
        // 失败文案会显示在界面上、并随截图流出，日志里脱敏过的东西这里不能漏出来
        let cause = FailureCause.spawnFailed("token=sk-abcdefghijklmnopqrstuvwxyz012345")
        #expect(cause.detail(.zh).contains("sk-abcdefghijklmnopqrstuvwxyz012345") == false)
    }

    @Test func maskingKeepsOrdinaryPathsIntact() {
        // 脱敏不能把文件路径也吃掉——那是用户唯一能拿去排查的线索
        let cause = FailureCause.invalidConfig(path: "/Users/me/.dsh/.credentials.yaml", message: "must be a string")
        #expect(cause.detail(.en).contains("/Users/me/.dsh/.credentials.yaml"))
    }

    // MARK: 动作文案

    @Test func everyActionHasBilingualLabel() {
        let actions: [FailureCause.RecoveryAction] = [
            .retry, .viewLogs, .exportDiagnostics, .useMachineRuntime,
            .open(URL(string: "https://nodejs.org/")!),
            .reveal(path: "/tmp/x.yaml"),
        ]
        for action in actions {
            for language in AppLanguage.allCases {
                #expect(!action.label(language).isEmpty, "\(action) 缺 \(language) 文案")
            }
        }
    }
}
