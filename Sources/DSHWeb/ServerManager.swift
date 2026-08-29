import Foundation
import Observation

/// 服务运行状态。
enum ServerState: Equatable {
    case starting          // 已启动进程，等待就绪
    case running(port: Int) // 就绪，WebView 可加载
    case external(port: Int) // 启动前端口已被占用（外部实例），直接连接
    case failed(FailureCause) // 启动失败或运行中退出（带分类与可操作的下一步）
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
    /// 最近一次启动的健康判定结果（界面与安全模式都读它）。
    private(set) var health: StartupHealth.Outcome = .pending
    /// 本次是否以安全模式启动（界面据此显示横幅）。
    private(set) var isSafeMode = false
    /// 安全模式本次停用的插件 id（界面列给用户看，让他知道少了什么）。
    private(set) var disabledPlugins: [String] = []

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
    /// 日志落盘。内存缓冲区随进程消失，而「打开就退出」这类问题只能靠落盘回看。
    private let logFile: LogFileSink
    /// 本次启动的健康观察；nil 表示当前没有自己启动的进程在观察窗口内。
    private var observation: StartupHealth.Observation?
    private let healthPolicy: StartupHealth.Policy
    private let streak: UnhealthyStreakStore
    /// 「下次以安全模式启动」的持久化开关。
    private let safeMode: SafeModeStore

    // MARK: - 启动入口

    /// 日志落盘目标可注入，便于单测用临时目录。
    init(
        logFile: LogFileSink = LogFileSink(),
        healthPolicy: StartupHealth.Policy = .standard,
        streak: UnhealthyStreakStore = UnhealthyStreakStore(),
        safeMode: SafeModeStore = SafeModeStore()
    ) {
        self.logFile = logFile
        self.healthPolicy = healthPolicy
        self.streak = streak
        self.safeMode = safeMode
    }

    /// 应用启动时调用：先看默认端口上是否已有 dsh 服务，再决定接管还是自己启动。
    ///
    /// 安全模式下不接管外部实例：那个实例是带着全部插件跑起来的，接管它等于绕过安全
    /// 模式——界面会显示「已停用插件」，而实际上什么都没停用。
    func start() {
        guard process == nil else { return }
        log("[dsh-web] 启动中…")
        Task {
            if !shouldUseSafeMode, await adoptExternalService(on: PortStrategy.defaultPort) { return }
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
            fail(.nodeMissing)
            return
        }
        guard let chosen = PortStrategy.firstAvailable(from: PortStrategy.defaultPort, isAvailable: LocalPort.isFree) else {
            fail(.portExhausted(from: PortStrategy.defaultPort, scanned: PortStrategy.scanLimit))
            return
        }
        if chosen != PortStrategy.defaultPort {
            log("[dsh-web] 端口 \(PortStrategy.defaultPort) 已被占用，本次改用 \(chosen)。")
        }
        port = chosen
        log("[dsh-web] 使用 Node: \(node.path)")
        let overlay = prepareSafeModeIfNeeded()
        Task {
            // 优化：缓存里已有 dsh 启动入口时直接使用，跳过 npx 网络检查（省 3-5s）
            if let boot = self.resolveBootJS() {
                self.spawnServer(node: node, bootJS: boot, overlay: overlay)
                return
            }
            log("[dsh-web] 未找到 dsh 缓存，先通过 npx 安装…")
            let ok = await self.ensurePackage(node: node)
            guard ok else { return } // fail 已由 ensurePackage 处理
            guard let boot = self.resolveBootJS() else {
                self.fail(.bootJSMissing)
                return
            }
            self.spawnServer(node: node, bootJS: boot, overlay: overlay)
        }
    }

    /// 确保 npx 缓存里已有 @deepseek-ai/dsh（静默安装）。
    ///
    /// 超时给到 20 分钟，不是保守，是量出来的：`@deepseek-ai/dsh@0.1.1-rc.2` 连同 web
    /// profile 的依赖树解出来 283 MB，在 npm 缓存已经预热、网络通畅的机器上从开始解析到
    /// 落盘用了约 14 分钟。原先的 180 s 只够走完依赖解析的开头，也就是说**首次安装必然超时**——
    /// 对一台全新机器上的新用户，这是第一次启动就会撞上的失败。
    private func ensurePackage(node: URL) async -> Bool {
        let timeout: TimeInterval = 1200
        let npx = node.deletingLastPathComponent().appendingPathComponent("npx")
        log("[dsh-web] 检查 dsh 包缓存…")
        // 首次安装是几百 MB 的依赖树，期间界面只显示「启动中」。提前说清量级，
        // 免得用户以为卡死了去强杀进程——npx 装到一半被打断留下的缓存是坏的。
        log("[dsh-web] 首次安装 dsh 需要下载数百 MB 依赖，通常几分钟到十几分钟，请勿退出。")
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
            fail(.npxUnavailable(error.localizedDescription))
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline {
                p.terminate()
                log("[dsh-web] 安装 @deepseek-ai/dsh 超时（\(Int(timeout))s），已终止。")
                fail(.npxTimeout(seconds: Int(timeout)))
                return false
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    /// 以 node 直接运行 dsh 启动入口（单一直接子进程，便于退出清理）。
    ///
    /// 参数形式与其中的约束见 `ServerArguments`。
    private func spawnServer(node: URL, bootJS: URL, overlay: URL? = nil) {
        let p = Process()
        p.executableURL = node
        p.arguments = ServerArguments.spawn(bootJS: bootJS.path, port: port, overlay: overlay?.path)
        p.currentDirectoryURL = homeDir
        p.environment = environment(node: node)

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.process === p else { return }
                self.process = nil
                self.observation?.exitedAt = Date()
                self.observation?.exitStatus = p.terminationStatus
                self.settleHealth()
                // 从日志尾部推断真正的原因：dsh 拒绝启动时会把理由写在退出前的最后几行，
                // 只报 exit code 等于把唯一有用的线索丢掉。
                self.fail(FailureCause.classify(
                    exitStatus: p.terminationStatus,
                    logTail: Array(self.logLines.suffix(Self.classificationTailLines))
                ))
            }
        }

        drain(pipe.fileHandleForReading)

        do {
            try p.run()
        } catch {
            fail(.spawnFailed(error.localizedDescription))
            return
        }
        process = p
        log("[dsh-web] 服务进程已启动 (PID \(p.processIdentifier))")
        beginHealthObservation()

        // 快速就绪：端口可连接即视为就绪（不等 dsh 的完整初始化就绪行，
        // 那要 20-30s；页面由 dsh 前端自己的 loading 处理）。最多等 90s。
        Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.readinessTimeout)
            while self.process === p, case .starting = self.state {
                if await self.probePort(self.port) {
                    self.state = .running(port: self.port)
                    self.log("[dsh-web] 服务已就绪（端口探测）。")
                    return
                }
                if Date() > deadline {
                    self.fail(.readinessTimeout(seconds: Int(Self.readinessTimeout)))
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// 就绪等待上限。dsh 冷启动最慢的一次约 30s，90s 留了三倍余量。
    private static let readinessTimeout: TimeInterval = 90

    /// 分类时回看的日志行数。dsh 退出前的报错通常紧邻末尾，回看太多会把上一次
    /// 启动的报错也算进来。
    private static let classificationTailLines = 40

    // MARK: - 启动健康判定

    /// 开始观察本次启动：记下启动时刻，并起一个轮询判定的任务。
    ///
    /// 用轮询而不是纯事件驱动：判定依赖的三个事实里，「页面加载完成」和「进程退出」都有
    /// 回调，但「存活时长」没有——只有时钟推进才能判出「页面 60s 还没加载完成」。
    ///
    /// 与端口探测的 `.running` 是两套判断，互不替代：探测让界面 2s 就出来，健康判定
    /// 回答的是「这次到底算不算跑起来了」，后者才是安全模式的计数依据。
    private func beginHealthObservation() {
        observation = StartupHealth.Observation(spawnedAt: Date())
        health = .pending
        // 上一轮的观察任务在 observation 落定时就会退出，这里不会长期堆积。
        Task { [weak self] in
            while let self, self.observation != nil {
                self.settleHealth()
                if self.observation == nil { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// WebView 报告页面加载完成。
    ///
    /// 只认第一次：用户手动刷新页面不该把判定窗口重新拉长，否则一个反复刷新的用户
    /// 永远判不出结果。
    func notePageLoaded() {
        guard observation != nil, observation?.pageLoadedAt == nil else { return }
        observation?.pageLoadedAt = Date()
        log("[dsh-web] 页面加载完成。")
        settleHealth()
    }

    /// 有结论就落定，没结论就继续等。
    ///
    /// 幂等：落定后清掉 `observation`。退出回调与轮询任务会同时到达，不清就会重复计数，
    /// 一次失败启动能把连续失败次数推进两三格，安全模式随之误触发。
    private func settleHealth() {
        guard let observation else { return }
        let outcome = StartupHealth.evaluate(observation, now: Date(), policy: healthPolicy)
        guard outcome != .pending else { return }
        self.observation = nil
        health = outcome
        streak.record(outcome)
        switch outcome {
        case .healthy:
            log("[dsh-web] 启动健康判定：正常。")
        case .unhealthy(let reason):
            log("[dsh-web] 启动健康判定：异常 —— \(reason)（连续 \(streak.value) 次）")
        case .pending:
            break
        }
    }

    // MARK: - 安全模式

    /// 本次启动是否应当走安全模式。
    ///
    /// 两个来源：用户手动开的开关（存盘），或连续不健康启动已达阈值。后者才是主路径——
    /// 崩溃循环里用户根本进不到任何界面去手动开。
    private var shouldUseSafeMode: Bool {
        safeMode.isEnabled
            || StartupHealth.shouldEnterSafeMode(streak: streak.value, policy: healthPolicy)
    }

    /// 需要时写出安全模式 overlay，返回要传给 `--patch` 的路径。
    ///
    /// 插件清单静态扫描 profile 目录得来，不经过 dsh：安全模式存在的前提就是 dsh
    /// 起不来，任何依赖它能运行的方案（`--dump-config`）在这里都用不上。
    ///
    /// 写不出 overlay 时返回 nil，正常启动。安全模式是补救手段，它自己失败不该把
    /// 一次本来可能成功的启动也拖掉。
    private func prepareSafeModeIfNeeded() -> URL? {
        guard shouldUseSafeMode else {
            isSafeMode = false
            disabledPlugins = []
            return nil
        }
        // 由连续失败自动触发时把开关存盘：下次启动仍是安全模式，直到用户显式退出。
        if !safeMode.isEnabled {
            safeMode.enable()
            log("[dsh-web] 连续 \(streak.value) 次启动异常，本次进入安全模式。")
        }

        let plugins = PluginInventory.scan(profileDirectory: SafeModeOverlay.profileDirectory)
        let disable = PluginInventory.thirdPartyIDs(in: plugins)
        do {
            let url = try SafeModeOverlay.write(disabling: disable)
            isSafeMode = true
            disabledPlugins = disable
            log("[dsh-web] 安全模式：已停用 \(disable.count) 个第三方插件（overlay: \(url.path)）。")
            if !disable.isEmpty {
                log("[dsh-web] 安全模式停用清单：\(disable.joined(separator: ", "))")
            }
            return url
        } catch {
            log("[dsh-web] 安全模式 overlay 写入失败，本次按正常模式启动：\(error.localizedDescription)")
            isSafeMode = false
            disabledPlugins = []
            return nil
        }
    }

    /// 手动进入安全模式并重启（插件把界面搞坏、但应用还能用时的入口）。
    func enterSafeMode() {
        safeMode.enable()
        log("[dsh-web] 已开启安全模式，正在重启服务…")
        restart()
    }

    /// 退出安全模式并重启。
    ///
    /// 同时清零连续失败计数：不清的话计数仍在阈值上，下次启动会立刻被判回安全模式，
    /// 用户点了「退出」却什么也没变。
    func exitSafeMode() {
        safeMode.disable()
        streak.reset()
        isSafeMode = false
        disabledPlugins = []
        log("[dsh-web] 已退出安全模式，正在重启服务…")
        restart()
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

    /// 追加一行日志（脱敏 → 时间戳 → 容量封顶 → 落盘）。
    ///
    /// 脱敏放在这个唯一入口而不是 `ingest`：应用自己拼的消息也可能带上 URL 或路径，
    /// 只有统一过一遍才能保证缓冲区里不存在未脱敏的行——日志会被用户整段复制出去。
    /// 落盘同样走这里，因此磁盘上的内容与界面上看到的完全一致（都已脱敏）。
    private func log(_ line: String) {
        let entry = "[\(timestampFormatter.string(from: Date()))] \(SecretMasker.mask(line))"
        logLines.append(entry)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
        logFile.append(entry)
    }

    /// 复用的时间戳格式化器：dsh 日志高峰时每行新建 DateFormatter 会明显拖慢主线程。
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// 进入失败态并保证日志可见（UI 会随 state 自动展开日志面板）。
    ///
    /// 失败原因带分类：界面据此给出「怎么办」的按钮，而不是只把一句英文报错糊在屏幕上。
    /// 文案的脱敏由 `FailureCause.detail` 负责（它是唯一的出口），这里再过一遍 `log`
    /// 的脱敏也无害——规则是幂等的。
    private func fail(_ cause: FailureCause) {
        log("[dsh-web] ❌ \(cause.title(.zh))：\(cause.detail(.zh))")
        state = .failed(cause)
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

    // MARK: - 诊断导出

    /// 落盘日志目录（诊断报告与「打开日志目录」都用它）。
    var logDirectory: URL { LogFileSink.defaultDirectory }

    /// 关闭落盘句柄（应用退出前调用；同时保证已入队的行都写完）。
    func closeLogFile() {
        logFile.close()
    }

    /// 采集当前环境并渲染一份诊断报告。
    ///
    /// 先 `flush()` 再读文件清单：不然刚写的行可能还在队列里，报告里的文件列表会缺最新一段。
    /// 报告内容由 `DiagnosticsReport` 统一脱敏，这里只负责采集事实。
    func diagnosticsReport(tailLines: Int = 200, now: Date = Date()) -> String {
        logFile.flush()
        let environment = DiagnosticsReport.Environment(
            appVersion: Self.bundleValue("CFBundleShortVersionString"),
            appBuild: Self.bundleValue("CFBundleVersion"),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture,
            nodePath: resolveNode()?.path,
            bootJSPath: resolveBootJS()?.path,
            port: port,
            state: Self.describe(state),
            language: MenuBuilder.current.rawValue,
            logDirectory: logDirectory.path,
            logFiles: logFile.ownedFileNames(),
            generatedAt: now,
            safeMode: isSafeMode,
            disabledPlugins: disabledPlugins
        )
        return DiagnosticsReport.render(environment: environment, logTail: Array(logLines.suffix(tailLines)))
    }

    /// 状态的可读描述（报告用；不本地化，便于在 issue 里直接匹配代码）。
    private static func describe(_ state: ServerState) -> String {
        switch state {
        case .starting: return "starting"
        case .running(let port): return "running(port: \(port))"
        case .external(let port): return "external(port: \(port))"
        case .failed(let cause): return "failed(\(cause.identifier))"
        }
    }

    private static func bundleValue(_ key: String) -> String {
        Bundle.main.infoDictionary?[key] as? String ?? "unknown"
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
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
