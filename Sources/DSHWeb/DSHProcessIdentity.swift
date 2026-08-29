import Foundation

/// 判定某个本地进程是否确实是 dsh 服务进程。
///
/// 早期 `killPortOwner` 用 `lsof` 找出监听 3080 的 PID 后直接 `SIGTERM`，把「监听这个
/// 端口」等同于「是 dsh 残留进程」。用户跑在同一端口上的任何服务都会被应用杀掉，而且
/// 用户完全看不出是谁杀的。现在改为：先核对进程命令行确实是 dsh 启动入口，再终止；
/// 核对不通过就一律不碰，改用别的端口。
///
/// 同一判定也用于「端口已被占用时能否直接接管」——只有确认对面是 dsh，才把 WebView
/// 指向它，否则可能把用户的其它本地服务加载进应用窗口。
enum DSHProcessIdentity {

    /// npx 缓存或本地安装中，dsh 包路径在命令行里的稳定特征。
    private static let packageMarker = "@deepseek-ai/dsh"

    /// npm 为 bin 入口生成的可执行名（用户从终端跑 `dsh web` 时 ps 只看到它）。
    private static let binName = "dsh"

    /// 承载 dsh 的解释器可执行名。
    private static let interpreterName = "node"

    // MARK: - 纯判定

    /// `ps -o command=` 输出的命令行是否是一个 dsh 启动进程。
    static func isDSHBoot(commandLine: String) -> Bool {
        let tokens = commandLine
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        // 必须由 node 承载：排除 grep/编辑器等只是「提到」dsh 路径的进程。
        guard let executable = tokens.first,
              lastPathComponent(of: executable) == interpreterName else { return false }

        let arguments = tokens.dropFirst()
        // 直接跑包内入口（应用自己的启动方式），或跑 npm 生成的 dsh bin 链接。
        return arguments.contains { $0.contains(packageMarker) }
            || arguments.contains { lastPathComponent(of: $0) == binName }
    }

    /// 解析 `lsof -t` 的输出为可终止的 PID 列表。
    ///
    /// 同一进程的多个 fd 会重复出现，去重后保持首次出现顺序；PID 0/1
    /// （kernel 与 launchd）永远排除，避免任何情况下把信号发给系统进程。
    static func parseListenerPIDs(lsofOutput: String) -> [Int] {
        var seen = Set<Int>()
        var pids: [Int] = []
        for line in lsofOutput.split(whereSeparator: \.isNewline) {
            guard let pid = Int(line.trimmingCharacters(in: .whitespaces)),
                  pid > 1, seen.insert(pid).inserted else { continue }
            pids.append(pid)
        }
        return pids
    }

    private static func lastPathComponent(of path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }

    // MARK: - 系统探测

    /// 监听指定端口的进程 PID 列表。
    static func listenerPIDs(on port: Int) -> [Int] {
        guard let output = runCapturing(
            "/usr/sbin/lsof",
            ["-tiTCP:\(port)", "-sTCP:LISTEN"]
        ) ?? runCapturing("/usr/bin/lsof", ["-tiTCP:\(port)", "-sTCP:LISTEN"]) else { return [] }
        return parseListenerPIDs(lsofOutput: output)
    }

    /// 指定 PID 的完整命令行；进程不存在时为 nil。
    static func commandLine(pid: Int) -> String? {
        guard let output = runCapturing("/bin/ps", ["-p", String(pid), "-o", "command="]) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 监听该端口的进程中，确实是 dsh 的那些 PID。
    static func dshListenerPIDs(on port: Int) -> [Int] {
        listenerPIDs(on: port).filter { pid in
            guard let command = commandLine(pid: pid) else { return false }
            return isDSHBoot(commandLine: command)
        }
    }

    /// 同步执行一条命令并捕获 stdout；可执行文件不存在或失败时为 nil。
    ///
    /// 只用于 lsof/ps 这类毫秒级查询，且仅在端口确实被占用时才会走到。
    private static func runCapturing(_ executable: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
