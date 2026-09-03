import Foundation

/// 拼给 node 的 dsh 启动参数（纯函数，与进程无关，便于单测固定）。
///
/// 参数形式由 dsh 那侧的约束决定：
/// - 用 `--profile web` 而不是 `dsh web` 子命令。后者只是前者的别名，且拒收父级参数
///   （`web takes none of parent --profile, --patch, …`），而端口与安全模式 overlay
///   都必须从父级参数传进去。
/// - **顺序有意义：启动器自己的参数（`--profile` / `--patch`）必须全部排在 profile 那个
///   app 的参数（`--port` / `--no-open`）之前。** dsh 的启动器一碰到第一个它不认识的
///   参数，就把余下的整段转交给被引导的 app —— `--patch` 排在 `--port` 后面时便落到
///   不认识它的那一侧，dsh 报 `error: unknown option '--patch'` 并 exit 1。
///   overlay 之所以是组合链的最后一层，是 `--patch` 本身的语义
///   （`extra patch-list overlay applied after the profile layer`）决定的，
///   跟它在命令行上的位置无关 —— 把它往后放并不会让它「更优先」，只会让它进不去。
/// - `--no-open` 必须常驻。dsh 默认会自己打开系统浏览器
///   （`dsh web: opening the default browser; pass --no-open to disable`），
///   而应用窗口本身就是那个界面，不加这个参数等于每次启动都白送用户一个浏览器标签页。
enum ServerArguments {

    static func spawn(bootJS: String, port: Int, overlay: String?) -> [String] {
        var arguments = [bootJS, "--profile", "web"]
        if let overlay {
            arguments += ["--patch", overlay]
        }
        arguments += ["--port", String(port), "--no-open"]
        return arguments
    }
}
