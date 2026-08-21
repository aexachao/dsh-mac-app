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
    private(set) var port = 3080

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

    /// 应用启动时调用：先探测端口，再决定接管还是直接连接。
    func start() {
        guard process == nil else { return }
        log("[dsh-web] 启动中…")
        Task {
            if await probePort(port) {
                state = .external(port: port)
                log("[dsh-web] 检测到 127.0.0.1:\(port) 已有服务在运行，直接连接。")
            } else {
                launchServer()
            }
        }
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

    /// 重启：彻底重启 — 停自己的进程、等待端口释放、
    /// 清理占用端口的残留进程，然后启动新服务（保证插件/配置变更生效）。
    func restart() {
        stop()
        state = .starting
        log("[dsh-web] 重新启动（彻底重启，加载最新配置）…")
        Task {
            // 1. 等待自己终止的进程释放端口（最多 5s）
            for _ in 0..<25 {
                if !(await probePort(port)) { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            // 2. 端口仍被占用 → 是外部残留进程，接管并清理
            if await probePort(port) {
                log("[dsh-web] 端口 \(port) 被残留进程占用，清理后重启…")
                killPortOwner(port)
                for _ in 0..<15 {
                    if !(await probePort(port)) { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            launchServer()
        }
    }

    /// 杀掉占用指定端口的进程（lsof 定位 PID）。
    private func killPortOwner(_ port: Int) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        task.arguments = ["-tiTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return }
            let pids = output.split(whereSeparator: \.isNewline).compactMap { Int($0) }
            for pid in pids where pid > 1 {
                log("[dsh-web] 终止残留进程 PID \(pid)")
                kill(pid_t(pid), SIGTERM)
            }
        } catch {
            log("[dsh-web] 清理端口失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 服务进程

    private func launchServer() {
        state = .starting
        guard let node = resolveNode() else {
            fail("找不到 Node.js。请先安装 Node（如 brew install node 或 nvm）。")
            return
        }
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
    private func spawnServer(node: URL, bootJS: URL) {
        let p = Process()
        p.executableURL = node
        p.arguments = [bootJS.path, "web"]
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

    /// 追加一行日志（带时间戳，容量封顶）。
    private func log(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logLines.append("[\(formatter.string(from: Date()))] \(line)")
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    /// 进入失败态并保证日志可见（UI 会随 state 自动展开日志面板）。
    private func fail(_ message: String) {
        log("[dsh-web] ❌ \(message)")
        state = .failed(message)
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

    /// 探测端口是否已有 HTTP 服务响应。
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
