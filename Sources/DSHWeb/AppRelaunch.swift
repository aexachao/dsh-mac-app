import AppKit

/// 应用自重启（改语言后需要整个应用重来一遍）。
///
/// 为什么要绕 `/bin/sh`：`open` 对一个还在运行的实例只会激活、不会重启，所以必须等
/// 旧进程真正消失之后再 `open`。等待方式是轮询 `kill -0 <pid>` 而不是固定 `sleep`：
/// 单实例锁随进程结束才释放，旧进程退得慢一点，新实例就会判定「已有实例在运行」
/// 然后自己退出——用户看到的是「切换语言后应用直接没了」。
enum AppRelaunch {

    /// 轮询间隔（秒）与最多轮询次数：10 s 后无论旧进程是否还在都去 `open`，
    /// 卡死一个不肯退的进程不该换来一个永远不重启的应用。
    private static let tickSeconds = "0.1"
    private static let defaultMaxTicks = 100

    /// 拼出重启用的 shell 命令（纯函数，便于单测）。
    static func command(bundlePath: String, pid: pid_t, maxTicks: Int = defaultMaxTicks) -> String {
        let quoted = "\"\(escapeForDoubleQuotes(bundlePath))\""
        return "i=0; while kill -0 \(pid) 2>/dev/null && [ $i -lt \(maxTicks) ]; "
            + "do sleep \(tickSeconds); i=$((i+1)); done; open \(quoted)"
    }

    /// 启动等待进程，然后退出自己。
    @MainActor
    static func restart() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command(bundlePath: Bundle.main.bundlePath, pid: getpid())]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// 双引号内需要转义的只有反斜杠与双引号本身（`$` 与反引号不出现在 bundle 路径里，
    /// 但顺手也转掉，避免以后被别处复用时踩到）。
    private static func escapeForDoubleQuotes(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if character == "\\" || character == "\"" || character == "$" || character == "`" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
