import Foundation

/// 菜单结构诊断日志：写入策略（纯函数）+ 一处落盘。
///
/// 这份日志有存在理由：SwiftUI 会抢 `NSApp.mainMenu`（见 `MenuBuilder` 的双设置与
/// 守护 Timer），只有把每次重建、每次被覆盖时的菜单结构记下来，才能判断某次菜单丢失
/// 是谁干的。但守护 Timer 每 3 秒写一次，写的又是同一份没变过的结构：一台开着不动的
/// 机器上实测把日志写到了 55 MB。诊断价值全在「变化」，重复的那部分只是噪音，并且
/// 挤掉了真正有用的那几行。
///
/// 三条策略：
/// - **周期快照只在结构变了时写**（`Event.dedupes`），事件型（重建、被覆盖）一律写——
///   事件本身就是信息，即使结构与上次相同也要留痕。
/// - **文件有硬上限**，到顶从头重写。诊断的是「刚才发生了什么」，留最近的比留最早的有用。
/// - **位置从 `/tmp` 移到 `~/Library/Logs/Harness`**，与其它日志同一处（仓库规矩：
///   应用写的东西只落在自己的两个目录里）。`/tmp` 还是所有用户共享的固定路径，
///   谁都能预先占住那个文件名。
enum MenuStateLog {

    /// 什么时候记的。原始值就是过去写进文件的 tag，日志格式不变。
    enum Event: String {
        /// 重建后立即设置。
        case rebuildSet = "rebuild-set"
        /// 下一个主队列 tick 上的补设。
        case rebuildDelayed = "rebuild-delayed"
        /// 守护 Timer 发现菜单被换掉了。
        case guardOverride = "guard-override"
        /// 守护 Timer 的周期性快照。
        case tick

        /// 结构与上次相同时是否跳过。只有周期快照跳——它是「现在长这样」的采样，
        /// 采到一模一样的东西写一遍没有任何新信息。
        var dedupes: Bool { self == .tick }
    }

    /// 文件上限。够装几百条快照，足以覆盖一次「菜单突然没了」前后的全过程。
    static let sizeLimit = 256 * 1024

    /// 落盘位置：与服务日志同一个目录，方便一起打包进 issue。
    ///
    /// 文件名故意不带 `LogRotation.filePrefix`（`harness-`）：那套轮转只认自己的文件，
    /// 于是这份日志既不计入 16 MB 目录上限、也不会被它清掉——限长由上面的
    /// `sizeLimit` 自己负责，两套机制互不干扰。
    static var fileURL: URL {
        LogFileSink.defaultDirectory.appendingPathComponent("menu-state.log")
    }

    /// 这一条该不该写。
    static func shouldWrite(_ event: Event, body: String, previousBody: String?) -> Bool {
        guard event.dedupes else { return true }
        return body != previousBody
    }

    /// 追加这一条会不会顶破上限（顶破就从头重写）。
    static func shouldReset(currentSize: Int, incoming: Int, limit: Int = sizeLimit) -> Bool {
        currentSize + incoming > limit
    }

    /// 渲染一条记录。格式沿用原来的 `=== tag ===`，多带一个时间戳——
    /// 去重之后每条都代表一次真实变化，「什么时候变的」就成了关键信息。
    static func entry(_ event: Event, body: String, timestamp: String) -> String {
        "=== \(event.rawValue) \(timestamp) ===\n\(body)\n"
    }

    /// 写入指定文件，必要时先从头重写。
    ///
    /// 每一步 I/O 失败都静默降级为不记录：这是诊断日志，日志目录只读绝不能反过来
    /// 影响菜单本身。
    static func write(_ text: String, to url: URL, limit: Int = sizeLimit) {
        guard let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if shouldReset(currentSize: size, incoming: data.count, limit: limit) {
            let header = "=== menu-state.log 达到上限（\(limit) 字节），从头重写 ===\n"
            try? (header + text).write(to: url, atomically: true, encoding: .utf8)
            return
        }

        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }

    /// 上一次记录的菜单结构（去重的依据）。事件型记录也会更新它——
    /// 重建刚写过的结构，紧接着那次 tick 采到同样的东西就该跳过。
    @MainActor private static var lastBody: String?

    private nonisolated(unsafe) static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// 记一条（去重 + 限长后落盘）。
    @MainActor static func record(_ event: Event, body: String, at date: Date = Date()) {
        guard shouldWrite(event, body: body, previousBody: lastBody) else { return }
        lastBody = body
        write(entry(event, body: body, timestamp: stampFormatter.string(from: date)), to: fileURL)
    }
}
