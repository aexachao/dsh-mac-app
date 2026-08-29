import Foundation
import Observation

/// 服务运行状态。
enum ServerState: Equatable {
    case starting          // 已启动进程，等待就绪
    case running(port: Int) // 就绪，WebView 可加载
    case external(port: Int) // 启动前端口已被占用（外部实例），直接连接
    case failed(String)     // 启动失败或运行中退出
}

/// 管理 dsh 服务进程的生命周期、日志捕获与状态机。
///
/// 设计要点：
/// - 直接以 `node <dsh>/lib/bin.js web` 运行（先经 npx 确保包已缓存），
///   使服务成为本应用的直接子进程，退出时可干净终止，不留孤儿。
/// - stdout/stderr 合并为一条管道，行缓冲后进入日志列表。
/// - 就绪判定：日志出现 `dsh web: http://127.0.0.1:<port>` 行；兜底为端口探测。
@MainActor
@Observable
final class ServerManager {

    /// 全局共享实例（AppDelegate 与应用界面都引用它）。
    static let shared = ServerManager()

    private(set) var state: ServerState = .starting
    private(set) var logLines: [String] = []
    /// 本次运行实际使用的端口（启动时选定后不再变化，直到下次重启）。
    private(set) var port = PortStrategy.defaultPort

    /// 界面用的就绪地址（由状态推导）。
    var webURL: URL? {
        switch state {
        case .running(let p), .external(let p):
            return URL(string: "http://127.0.0.1:\(p)/")
        default:
            return nil
        }
    }

    private var process: Process?
    private var logQueue = DispatchQueue(label: "dsh-web.log")
    private let maxLogLines = 5000

    // MARK: - 启动入口

    /// 应用启动时调用：先看默认端口上是否已有 dsh 服务，再决定接管还是自己启动。
    func start() {
        guard process == nil else { return }
        log("[dsh-web] 启动中…")
        Task {
            if await adoptExternalService(on: PortStrategy.defaultPort) { return }
            launchServer()
        }
    }

    /// 尝试接管端口上已有的服务。
    ///
    /// 只有确认监听方确实是 dsh 才接管——否则会把用户其它本地服务的页面加载进应用窗口。
    /// 占用者是 dsh 但还没响应（通常正在初始化）时也不接管：宁可自己另起一个端口，也不
    /// 让界面卡在一个可能已经僵死的进程上。
    /// - Returns: 已接管并进入 `.external` 时为 true。
    private func adoptExternalService(on candidate: Int) async -> Bool {
        // lsof/ps 是毫秒级查询，且只在端口确实被占用时才会走到。
        let listeners = DSHProcessIdentity.listenerPIDs(on: candidate)
        guard !listeners.isEmpty else { return false }

        let dshPIDs = listeners.filter { pid in
            guard let command = DSHProcessIdentity.commandLine(pid: pid) else { return false }
            return DSHProcessIdentity.isDSHBoot(commandLine: command)
        }
        guard !dshPIDs.isEmpty else {
            log("[dsh-web] 端口 \(candidate) 被非 dsh 进程占用（\(describe(listeners))），改用其它端口。")
            return false
        }
        guard await probePort(candidate) else {
            log("[dsh-web] 端口 \(candidate) 上的 dsh 进程尚未响应，改为自行启动服务。")
            return false
        }
        port = candidate
        state = .external(port: candidate)
        log("[dsh-web] 检测到 127.0.0.1:\(candidate) 已有 dsh 服务（\(describe(dshPIDs))），直接连接。")
        return true
    }

    /// 停止服务进程（退出/重试前调用）。
    func stop() {
        if let process {
            if process.isRunning {
                log("[dsh-web] 停止服务…")
                process.terminate()
            }
            self.process = nil
        }
    }

    /// 重启：彻底重启 — 停自己的进程、等待端口释放、清理**可确认的** dsh 残留进程，
    /// 然后启动新服务（保证插件/配置变更生效）。
    func restart() {
        stop()
        state = .starting
        log("[dsh-web] 重新启动（彻底重启，加载最新配置）…")
        Task {
            // 1. 等自己刚终止的进程释放端口（最多 5s）
            await waitForPortRelease(port)
            // 2. 仍被占用 → 只终止确认是 dsh 的残留进程，其它进程一律不碰
            if !LocalPort.isFree(port) {
                terminateVerifiedDSHListeners(on: port)
                await waitForPortRelease(port, attempts: 15)
            }
            // 3. 端口还是拿不回来时，launchServer 会自动退让到下一个空闲端口
            launchServer()
        }
    }

    /// 轮询等待端口被释放（每 200ms 一次）。
    ///
    /// 用「能否绑定」判定而不是 HTTP 探测：dsh 从监听到能响应 HTTP 有数十秒窗口，
    /// HTTP 探测会把正在初始化的服务误判为端口已释放。
    private func waitForPortRelease(_ port: Int, attempts: Int = 25) async {
        for _ in 0..<attempts {
            if LocalPort.isFree(port) { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// 终止占用指定端口、且命令行可确认为 dsh 启动入口的进程。
    ///
    /// 早期实现直接 SIGTERM 所有监听该端口的 PID，会杀掉用户完全无关的服务。
    /// 现在核对不通过就保持不动，并把这一决定写进日志。
    private func terminateVerifiedDSHListeners(on port: Int) {
        let listeners = DSHProcessIdentity.listenerPIDs(on: port)
        guard !listeners.isEmpty else { return }

        var terminated: [Int] = []
        for pid in listeners {
            guard let command = DSHProcessIdentity.commandLine(pid: pid),
                  DSHProcessIdentity.isDSHBoot(commandLine: command) else {
                log("[dsh-web] 端口 \(port) 的占用者 \(describe([pid])) 不是 dsh 进程，保持不动。")
                continue
            }
            kill(pid_t(pid), SIGTERM)
            terminated.append(pid)
        }
        if !terminated.isEmpty {
            log("[dsh-web] 已终止 dsh 残留进程 \(describe(terminated))。")
        }
    }

    /// 把 PID 列表描述成日志可读的形式。
    ///
    /// 只取可执行文件名，不写完整命令行——别的进程的启动参数可能含敏感信息。
    private func describe(_ pids: [Int]) -> String {
        pids.map { pid in
            guard let command = DSHProcessIdentity.commandLine(pid: pid),
                  let executable = command.split(separator: " ").first,
                  let name = executable.split(separator: "/").last else {
                return "PID \(pid)"
            }
            return "PID \(pid) \(name)"
        }.joined(separator: ", ")
    }

    // MARK: - 服务进程

    private func launchServer() {
        state = .starting
        guard let node = resolveNode() else {
            fail("找不到 Node.js。请先安装 Node（如 brew install node 或 nvm）。")
            return
        }
        guard let chosen = PortStrategy.firstAvailable(from: PortStrategy.defaultPort, isAvailable: LocalPort.isFree) else {
            fail("从 \(PortStrategy.defaultPort) 起连续 \(PortStrategy.scanLimit) 个端口都被占用，请释放端口后重试。")
            return
        }
        if chosen != PortStrategy.defaultPort {
            log("[dsh-web] 端口 \(PortStrategy.defaultPort) 已被占用，本次改用 \(chosen)。")
        }
        port = chosen
        log("[dsh-web] 使用 Node: \(node.path)")
        Task {
            // 优化：缓存里已有 dsh 启动入口时直接使用，跳过 npx 网络检查（省 3-5s）
            if let boot = self.resolveBootJS() {
                self.spawnServer(node: node, bootJS: boot)
                return
            }
            log("[dsh-web] 未找到 dsh 缓存，先通过 npx 安装…")
            let ok = await self.ensurePackage(node: node)
            guard ok else { return } // fail 已由 ensurePackage 处理
            guard let boot = self.resolveBootJS() else {
                self.fail("已安装 @deepseek-ai/dsh 但找不到启动入口，请检查 ~/.npm/_npx 缓存。")
                return
            }
            self.spawnServer(node: node, bootJS: boot)
        }
    }

    /// 确保 npx 缓存里已有 @deepseek-ai/dsh（静默安装，超时 180s）。
    private func ensurePackage(node: URL) async -> Bool {
        let npx = node.deletingLastPathComponent().appendingPathComponent("npx")
        log("[dsh-web] 检查 dsh 包缓存…")
        let p = Process()
        p.executableURL = node
        p.arguments = [npx.path, "--yes", "@deepseek-ai/dsh", "--version"]
        p.currentDirectoryURL = homeDir
        p.environment = environment(node: node)

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        drain(pipe.fileHandleForReading) // npx 的安装进度也会进日志

        do {
            try p.run()
        } catch {
            log("[dsh-web] 启动 npx 失败: \(error.localizedDescription)")
            fail("无法运行 npx: \(error.localizedDescription)")
            return false
        }
        let deadline = Date().addingTimeInterval(180)
        while p.isRunning {
            if Date() > deadline {
                p.terminate()
                log("[dsh-web] 安装 @deepseek-ai/dsh 超时（180s），已终止。")
                fail("安装 @deepseek-ai/dsh 超时，请检查网络后重试。")
                return false
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    /// 以 node 直接运行 dsh 启动入口（单一直接子进程，便于退出清理）。
    ///
    /// 用 `--profile web` 而不是 `dsh web` 子命令形式：后者是前者的别名，且拒收
    /// `--patch` 等父级参数（`web takes none of parent --profile, --patch, …`），
    /// 而端口与后续的安全模式 overlay 都要从父级参数传入。
    private func spawnServer(node: URL, bootJS: URL) {
        let p = Process()
        p.executableURL = node
        // 端口显式传入：不再假设 dsh 的默认端口与本应用的假设一致。
        p.arguments = [bootJS.path, "--profile", "web", "--port", String(port)]
        p.currentDirectoryURL = homeDir
        p.environment = environment(node: node)

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.process === p else { return }
                self.process = nil
                self.fail("服务意外退出（exit \(p.terminationStatus)），详见日志。")
            }
        }

        drain(pipe.fileHandleForReading)

        do {
            try p.run()
        } catch {
            fail("无法启动服务: \(error.localizedDescription)")
            return
        }
        process = p
        log("[dsh-web] 服务进程已启动 (PID \(p.processIdentifier))")

        // 快速就绪：端口可连接即视为就绪（不等 dsh 的完整初始化就绪行，
        // 那要 20-30s；页面由 dsh 前端自己的 loading 处理）。最多等 90s。
        Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(90)
            while self.process === p, case .starting = self.state {
                if await self.probePort(self.port) {
                    self.state = .running(port: self.port)
                    self.log("[dsh-web] 服务已就绪（端口探测）。")
                    return
                }
                if Date() > deadline {
                    self.fail("服务启动 90s 未就绪，详见日志。")
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    // MARK: - 日志与状态机

    /// 服务进程输出 → 行缓冲 → 日志列表；识别就绪行。
    private func ingest(_ text: String) {
        // 后台线程调用；合并可能被截断的行
        var buffer = text
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = buffer[buffer.startIndex..<newline]
            lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if !buffer.isEmpty { lines.append(buffer) }

        let ready = lines.contains { $0.contains("dsh web: http://127.0.0.1:\(port)") }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for line in lines where !line.isEmpty {
                self.log(line)
            }
            if ready, case .starting = self.state {
                self.state = .running(port: self.port)
                self.log("[dsh-web] 服务就绪。")
            }
        }
    }

    /// 追加一行日志（脱敏 → 时间戳 → 容量封顶）。
    ///
    /// 脱敏放在这个唯一入口而不是 `ingest`：应用自己拼的消息也可能带上 URL 或路径，
    /// 只有统一过一遍才能保证缓冲区里不存在未脱敏的行——日志会被用户整段复制出去。
    private func log(_ line: String) {
        logLines.append("[\(timestampFormatter.string(from: Date()))] \(SecretMasker.mask(line))")
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    /// 复用的时间戳格式化器：dsh 日志高峰时每行新建 DateFormatter 会明显拖慢主线程。
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// 进入失败态并保证日志可见（UI 会随 state 自动展开日志面板）。
    ///
    /// 失败文案会显示在界面上、并随截图一起流出，所以同样先脱敏：
    /// `error.localizedDescription` 可能带上完整命令行或 URL。
    private func fail(_ message: String) {
        let safe = SecretMasker.mask(message)
        log("[dsh-web] ❌ \(safe)")
        state = .failed(safe)
    }

    /// 后台持续读取管道数据，按行切分后跳回主线程交给 `ingest`。
    /// 进程退出（EOF）时结束；UTF-8 解码为容错模式（日志可能含多字节中文）。
    private func drain(_ handle: FileHandle) {
        logQueue.async { [weak self] in
            var data = Data()
            while true {
                let chunk = handle.readData(ofLength: 8192)
                if chunk.isEmpty { break } // EOF：进程退出
                data.append(chunk)
                var lines: [String] = []
                while let idx = data.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: data[data.startIndex..<idx], as: UTF8.self))
                    data.removeSubrange(data.startIndex...idx)
                }
                if !lines.isEmpty {
                    let batch = lines.joined(separator: "\n")
                    DispatchQueue.main.async { [weak self] in
                        self?.ingest(batch)
                    }
                }
            }
        }
    }

    // MARK: - 环境解析

    private var homeDir: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// 依次查找 node：nvm 最新版本 → Homebrew → 系统路径。
    private func resolveNode() -> URL? {
        let nvmDir = homeDir.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvmDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ).sorted(by: { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da > db
        }) {
            for v in versions {
                let node = v.appendingPathComponent("bin/node")
                if FileManager.default.isExecutableFile(atPath: node.path) { return node }
            }
        }
        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// 在 npx 缓存中定位 dsh 启动入口（取最新 mtime）。
    private func resolveBootJS() -> URL? {
        let cache = homeDir.appendingPathComponent(".npm/_npx")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        var best: (url: URL, date: Date)? = nil
        for entry in entries {
            let candidate = entry.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js")
            if FileManager.default.isReadableFile(atPath: candidate.path),
               let date = (try? candidate.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                if best == nil || date > best!.date { best = (candidate, date) }
            }
        }
        return best?.url
    }

    /// 服务进程环境：HOME + node bin 目录 + 基础 PATH。
    private func environment(node: URL) -> [String: String] {
        let nodeBin = node.deletingLastPathComponent().path
        return [
            "HOME": NSHomeDirectory(),
            "PATH": "\(nodeBin):/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
        ]
    }

    /// 探测端口上是否已有 HTTP 服务响应。
    ///
    /// 只回答「有没有 HTTP 服务在响应」，不回答「是不是 dsh」——身份判定由
    /// `DSHProcessIdentity` 按进程命令行核对。
    private func probePort(_ port: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let (_, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
            return true
        }
        return false
    }
}
