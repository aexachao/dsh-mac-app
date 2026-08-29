import Foundation

/// 启动失败的原因，以及针对这个原因用户能做的下一步。
///
/// 为什么需要：`.failed("服务意外退出（exit 1）")` 对用户没有任何用处——他既不知道
/// 哪里错了，也不知道下一步该干什么。分类之后每种失败都能给出「是什么 / 为什么 /
/// 怎么办」，其中「怎么办」是按钮而不是文字说明。
///
/// 全部做成纯值类型与纯函数：分类规则可以在单测里钉死，不必真的把服务弄崩一次。
enum FailureCause: Equatable {
    /// 找不到 Node.js（首次启动最常见的失败）。
    case nodeMissing
    /// 从首选端口起连续扫描都被占用。
    case portExhausted(from: Int, scanned: Int)
    /// npx 本身跑不起来（权限、路径异常等）。
    case npxUnavailable(String)
    /// npx 安装超时（通常是网络）。
    case npxTimeout(seconds: Int)
    /// 装完了却找不到启动入口（缓存被破坏）。
    case bootJSMissing
    /// `Process.run()` 抛错，服务进程根本没起来。
    case spawnFailed(String)
    /// 进程活着但迟迟不响应。
    case readinessTimeout(seconds: Int)
    /// 配置/凭据文件格式不符，dsh 拒绝启动。
    case invalidConfig(path: String, message: String)
    /// 其它异常退出；`message` 是日志里能找到的最后一条报错。
    case abnormalExit(status: Int32, message: String?)

    // MARK: - 可操作的下一步

    /// 失败态上可以点的按钮。
    enum RecoveryAction: Equatable {
        case retry
        case viewLogs
        case exportDiagnostics
        /// 打开外部链接（如 Node 官网）。
        case open(URL)
        /// 在 Finder 中定位文件（如出错的配置文件）。
        case reveal(path: String)

        /// 主按钮只允许一个：失败界面上如果有两个同等强调的按钮，用户就不知道该点哪个。
        var isPrimary: Bool { self == .retry }

        func label(_ language: AppLanguage) -> String {
            switch self {
            case .retry: return language == .zh ? "重试" : "Retry"
            case .viewLogs: return language == .zh ? "查看日志" : "View Logs"
            case .exportDiagnostics: return language == .zh ? "导出诊断信息" : "Export Diagnostics"
            case .open: return language == .zh ? "前往下载" : "Open Download Page"
            case .reveal: return language == .zh ? "在 Finder 中显示" : "Show in Finder"
            }
        }

        var symbol: String {
            switch self {
            case .retry: return "arrow.clockwise"
            case .viewLogs: return "terminal"
            case .exportDiagnostics: return "stethoscope"
            case .open: return "arrow.up.right.square"
            case .reveal: return "folder"
            }
        }
    }

    /// 「重试」对所有失败都成立——环境问题修好后用户总需要一个入口，
    /// 否则只能退出重开应用。
    var actions: [RecoveryAction] {
        switch self {
        case .nodeMissing:
            return [.open(Self.nodeDownloadURL), .viewLogs, .retry]
        case .invalidConfig(let path, _):
            return [.reveal(path: path), .viewLogs, .retry]
        case .portExhausted:
            return [.viewLogs, .retry]
        case .npxTimeout, .npxUnavailable, .bootJSMissing:
            return [.viewLogs, .exportDiagnostics, .retry]
        case .spawnFailed, .readinessTimeout, .abnormalExit:
            return [.viewLogs, .exportDiagnostics, .retry]
        }
    }

    static let nodeDownloadURL = URL(string: "https://nodejs.org/en/download")!

    // MARK: - 文案

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .nodeMissing:
            return language == .zh ? "未找到 Node.js" : "Node.js not found"
        case .portExhausted:
            return language == .zh ? "没有可用端口" : "No available port"
        case .npxUnavailable:
            return language == .zh ? "无法运行 npx" : "Cannot run npx"
        case .npxTimeout:
            return language == .zh ? "安装 dsh 超时" : "Installing dsh timed out"
        case .bootJSMissing:
            return language == .zh ? "找不到 dsh 启动入口" : "dsh entry point missing"
        case .spawnFailed:
            return language == .zh ? "服务进程无法启动" : "Failed to launch service"
        case .readinessTimeout:
            return language == .zh ? "服务启动后无响应" : "Service never became ready"
        case .invalidConfig:
            return language == .zh ? "配置文件格式不符" : "Invalid configuration file"
        case .abnormalExit:
            return language == .zh ? "服务异常退出" : "Service exited unexpectedly"
        }
    }

    /// 说明文字。
    ///
    /// 出口再脱敏一次：这段文字会显示在界面上、并随用户的截图一起流出，而 payload
    /// 里的命令行错误、配置路径都可能带上凭据。
    func detail(_ language: AppLanguage) -> String {
        SecretMasker.mask(rawDetail(language))
    }

    private func rawDetail(_ language: AppLanguage) -> String {
        let zh = language == .zh
        switch self {
        case .nodeMissing:
            return zh
                ? "Harness 需要本机的 Node.js 来运行 dsh 服务。安装 Node（推荐 LTS）后重试即可，也可以用 brew install node 或 nvm。"
                : "Harness runs the dsh service with your local Node.js. Install Node (LTS recommended), then retry — brew install node or nvm both work."
        case .portExhausted(let from, let scanned):
            return zh
                ? "从 \(from) 起连续 \(scanned) 个端口都被占用。请关掉占用这些端口的程序后重试。"
                : "All \(scanned) ports starting at \(from) are in use. Free one of them and retry."
        case .npxUnavailable(let message):
            return zh
                ? "npx 无法执行：\(message)。请确认 Node 安装完整（npx 与 node 在同一个 bin 目录下）。"
                : "npx could not run: \(message). Check that your Node installation is complete (npx sits next to node)."
        case .npxTimeout(let seconds):
            // 超时值已是分钟量级，按秒念（「超过 1200 秒」）读者得自己做除法
            let minutes = max(1, seconds / 60)
            return zh
                ? "通过 npx 安装 @deepseek-ai/dsh 超过 \(minutes) 分钟未完成，通常是网络问题。可先在终端手动执行 npx --yes @deepseek-ai/dsh --version 看进度，装好后再重试。"
                : "Installing @deepseek-ai/dsh via npx did not finish within \(minutes) min — usually a network issue. Run npx --yes @deepseek-ai/dsh --version in a terminal to watch its progress, then retry."
        case .bootJSMissing:
            return zh
                ? "已安装 @deepseek-ai/dsh，但在 ~/.npm/_npx 缓存中找不到启动入口。删除该缓存目录后重试可重新下载。"
                : "@deepseek-ai/dsh is installed but its entry point is missing from the ~/.npm/_npx cache. Delete that cache directory and retry to re-download."
        case .spawnFailed(let message):
            return zh
                ? "启动服务进程失败：\(message)"
                : "Could not spawn the service process: \(message)"
        case .readinessTimeout(let seconds):
            return zh
                ? "服务进程已启动，但 \(seconds) 秒内没有响应本机请求。日志里通常有它卡在哪一步。"
                : "The service process started but answered no local request within \(seconds)s. The log usually shows where it stalled."
        case .invalidConfig(let path, let message):
            return zh
                ? "dsh 拒绝启动，因为 \(path) 的内容不符合它期望的格式：\(message)。这个文件可能被另一个版本的 dsh 写过。"
                : "dsh refused to start because \(path) does not match the format it expects: \(message). Another version of dsh may have written this file."
        case .abnormalExit(let status, let message):
            let tail = message.map { zh ? "最后一条报错：\($0)" : "Last error: \($0)" } ?? (zh ? "日志里没有明确的报错。" : "The log contains no explicit error.")
            return zh
                ? "服务进程以 exit \(status) 退出。\(tail)"
                : "The service process exited with status \(status). \(tail)"
        }
    }

    /// 报告与日志用的稳定描述（不本地化，便于在 issue 里直接匹配代码）。
    var identifier: String {
        switch self {
        case .nodeMissing: return "nodeMissing"
        case .portExhausted: return "portExhausted"
        case .npxUnavailable: return "npxUnavailable"
        case .npxTimeout: return "npxTimeout"
        case .bootJSMissing: return "bootJSMissing"
        case .spawnFailed: return "spawnFailed"
        case .readinessTimeout: return "readinessTimeout"
        case .invalidConfig: return "invalidConfig"
        case .abnormalExit(let status, _): return "abnormalExit(\(status))"
        }
    }

    // MARK: - 从日志分类

    /// 应用自己写出的行（统一带 `[dsh-web]` 前缀）不是服务的报错，分类时必须排除，
    /// 否则「❌ 服务意外退出」这种自述会被当成原因，套成一个循环。
    private static let ownPrefix = "[dsh-web]"

    /// 时间戳前缀由 `ServerManager.log` 统一加上；分类看的是原始内容。
    private static let timestamp = try! NSRegularExpression(pattern: #"^\[\d{2}:\d{2}:\d{2}\]\s*"#)

    /// 配置/凭据校验失败的形状：`… in <某个 yaml 路径> …`。
    private static let configPath = try! NSRegularExpression(pattern: #"\bin\s+(/\S+\.ya?ml)\b"#)

    /// 校验动词。只提到某个 yaml 文件（例如「已写入」）不算配置错误。
    private static let validationVerbs = ["must be", "must not", "is invalid", "invalid", "expected", "unexpected", "required"]

    /// 服务端报错行的特征。
    private static let errorMarkers = ["Error:", "error:", "ERR!", "Exception", "FATAL", "fatal:", "panic:"]

    /// 依据退出码与日志尾部推断原因。
    ///
    /// 顺序有意为之：先找日志里已经写明原因的行（配置错误），找不到才退回「未知退出」。
    /// 反过来的话，本机上最真实的一次失败——dsh 因 `.credentials.yaml` 版本字段类型不符
    /// 而拒绝启动——只会显示成「exit 1」。
    static func classify(exitStatus: Int32, logTail: [String]) -> FailureCause {
        let lines = logTail
            .map(strippingTimestamp)
            .filter { !$0.contains(ownPrefix) && !$0.isEmpty }

        for line in lines.reversed() {
            if let path = configFilePath(in: line) {
                return .invalidConfig(path: path, message: line)
            }
        }
        let message = lines.last { line in errorMarkers.contains(where: line.contains) }
        return .abnormalExit(status: exitStatus, message: message)
    }

    private static func strippingTimestamp(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        return timestamp.stringByReplacingMatches(in: line, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 行里带 yaml 路径且带校验动词时返回该路径。
    private static func configFilePath(in line: String) -> String? {
        let lowered = line.lowercased()
        guard validationVerbs.contains(where: lowered.contains) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = configPath.firstMatch(in: line, range: range),
              let pathRange = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[pathRange])
    }
}
