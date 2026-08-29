import Foundation

/// 拼给 node 的 dsh 启动参数（纯函数，与进程无关，便于单测固定）。
///
/// 参数形式由 dsh 那侧的约束决定：
/// - 用 `--profile web` 而不是 `dsh web` 子命令。后者只是前者的别名，且拒收父级参数
///   （`web takes none of parent --profile, --patch, …`），而端口与安全模式 overlay
///   都必须从父级参数传进去。
/// - `--no-open` 必须常驻。dsh 默认会自己打开系统浏览器
///   （`dsh web: opening the default browser; pass --no-open to disable`），
///   而应用窗口本身就是那个界面，不加这个参数等于每次启动都白送用户一个浏览器标签页。
enum ServerArguments {

    static func spawn(bootJS: String, port: Int, overlay: String?) -> [String] {
        var arguments = [bootJS, "--profile", "web", "--port", String(port), "--no-open"]
        if let overlay {
            // overlay 放在最后：组合链里越靠后越优先，「停用第三方插件」必须压过 profile 自己的配置。
            arguments += ["--patch", overlay]
        }
        return arguments
    }
}
