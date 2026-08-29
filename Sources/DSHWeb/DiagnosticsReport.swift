import Foundation

/// 渲染一份可直接贴进 issue 的诊断报告（纯函数，环境事实由调用方注入）。
///
/// 为什么单独一层：用户报障时最缺的就是「我这边是什么环境」。让他们手抄 Node 路径、
/// macOS 版本、端口和最近日志是不现实的，所以做成一次点击导出。
///
/// 出口脱敏：日志行进入内存缓冲区时已经过 `SecretMasker`，但报告还会带上解析出的路径、
/// 状态文案等，而它是整份内容离开本机的最后一道关口，因此渲染结果整体再过一遍。
enum DiagnosticsReport {

    /// 报告里的环境事实。全部由调用方采集，便于单测逐项固定格式。
    struct Environment {
        let appVersion: String
        let appBuild: String
        let osVersion: String
        let architecture: String
        /// 解析到的 node 可执行文件；nil 表示没找到（最常见的失败原因）。
        let nodePath: String?
        /// 解析到的 dsh 启动入口；nil 表示 npx 缓存里没有。
        let bootJSPath: String?
        let port: Int
        /// 服务状态的可读描述。
        let state: String
        /// 界面语言偏好。
        let language: String
        let logDirectory: String
        /// 落盘日志文件名（按写入时序）。
        let logFiles: [String]
        let generatedAt: Date
        /// 本次是否以安全模式运行。
        let safeMode: Bool
        /// 安全模式停用的插件 id。
        let disabledPlugins: [String]
        /// 本次实际用的是哪一份运行时（`bundled` / `machine`）；nil 表示还没启动过。
        ///
        /// 捆绑之后这是读 issue 时第一个要问的问题：捆绑那份跑不起来是**我们**发错了版本，
        /// 本机那份跑不起来是用户机器上的状态。报告分不清这两者，就得靠来回追问补上。
        let runtimeSource: String?
        /// 捆绑运行时的版本摘要（`RuntimeManifest.summary`）；nil 表示这份构建没有捆绑。
        let bundledRuntime: String?
        /// 「改用本机 dsh」逃生开关是否打开。
        let prefersMachineRuntime: Bool

        init(
            appVersion: String,
            appBuild: String,
            osVersion: String,
            architecture: String,
            nodePath: String?,
            bootJSPath: String?,
            port: Int,
            state: String,
            language: String,
            logDirectory: String,
            logFiles: [String],
            generatedAt: Date,
            safeMode: Bool,
            disabledPlugins: [String],
            runtimeSource: String?,
            bundledRuntime: String?,
            prefersMachineRuntime: Bool
        ) {
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.osVersion = osVersion
            self.architecture = architecture
            self.nodePath = nodePath
            self.bootJSPath = bootJSPath
            self.port = port
            self.state = state
            self.language = language
            self.logDirectory = logDirectory
            self.logFiles = logFiles
            self.generatedAt = generatedAt
            self.safeMode = safeMode
            self.disabledPlugins = disabledPlugins
            self.runtimeSource = runtimeSource
            self.bundledRuntime = bundledRuntime
            self.prefersMachineRuntime = prefersMachineRuntime
        }
    }

    /// 未解析到的字段占位符——留空会让人以为是报告本身缺字段。
    private static let unresolved = "未解析"

    /// 渲染完整报告。
    static func render(environment: Environment, logTail: [String]) -> String {
        var out: [String] = []
        out.append("# Harness 诊断报告 / Diagnostics")
        out.append("生成时间 / Generated: \(timestamp(environment.generatedAt))")
        out.append("")

        out.append("## 环境 / Environment")
        out.append("- Harness: \(environment.appVersion) (build \(environment.appBuild))")
        out.append("- macOS: \(environment.osVersion)")
        out.append("- 架构 / Arch: \(environment.architecture)")
        out.append("- 界面语言 / Language: \(environment.language)")
        out.append("- 运行时来源 / Runtime: \(environment.runtimeSource ?? unresolved)")
        out.append("- 捆绑运行时 / Bundled: \(environment.bundledRuntime ?? unresolved)")
        out.append("- 改用本机 dsh / Prefer machine: \(environment.prefersMachineRuntime ? "on" : "off")")
        out.append("- Node: \(environment.nodePath ?? unresolved)")
        out.append("- dsh 启动入口 / Boot: \(environment.bootJSPath ?? unresolved)")
        out.append("")

        out.append("## 服务 / Service")
        out.append("- 状态 / State: \(environment.state)")
        out.append("- 端口 / Port: \(environment.port)")
        // 安全模式必须写明：这一屏少了插件，看 issue 的人若不知道，会照着一个不完整的
        // 环境去复现。
        out.append("- 安全模式 / Safe mode: \(environment.safeMode ? "on" : "off")")
        if environment.safeMode {
            out.append("- 已停用插件 / Disabled plugins (\(environment.disabledPlugins.count)): "
                       + (environment.disabledPlugins.isEmpty
                          ? "none"
                          : environment.disabledPlugins.joined(separator: ", ")))
        }
        out.append("")

        out.append("## 日志文件 / Log files")
        out.append("- 目录 / Directory: \(environment.logDirectory)")
        if environment.logFiles.isEmpty {
            out.append("- 无落盘文件 / none")
        } else {
            for name in environment.logFiles { out.append("- \(name)") }
        }
        out.append("")

        out.append("## 最近日志 / Recent log (\(logTail.count))")
        if logTail.isEmpty {
            out.append("（无 / none）")
        } else {
            out.append(contentsOf: logTail)
        }
        out.append("")

        // 出口再脱敏一次：报告会整份离开本机。
        return SecretMasker.mask(out.joined(separator: "\n"))
    }

    /// 保存对话框的建议文件名：不含空格与冒号，方便直接在终端里引用。
    static func suggestedFileName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = timeZone
        return "Harness-diagnostics-\(formatter.string(from: date)).txt"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
