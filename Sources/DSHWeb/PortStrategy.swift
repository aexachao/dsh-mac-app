import Foundation

/// dsh 服务的端口选择策略。
///
/// 早期实现把 3080 当成既定事实：`ServerManager.port` 硬编码 3080，启动命令又不传
/// `--port`，等于假设 dsh 的默认端口永远是它。实际上 3080 只是组合配置里的默认值
/// （`port: !!js ctx.webStartup.port ?? 3080`），用户改配置或端口被别的程序占用时，
/// 应用的探测、就绪判定和 WebView 地址会一起错。
///
/// 现在的做法：由应用先挑一个确定空闲的端口，再用 `--port` 显式告诉 dsh。
/// 端口冲突时向后退让，而不是抢占。
enum PortStrategy {

    /// dsh 组合配置中的默认监听端口。优先沿用它，保持用户既有的访问习惯。
    static let defaultPort = 3080

    /// 端口被占用时向后扫描的最大次数。
    static let scanLimit = 32

    /// TCP 端口上限。
    private static let maxPort = 65_535

    /// 从 `preferred` 开始向后寻找第一个可用端口。
    /// - Parameters:
    ///   - preferred: 首选端口。
    ///   - limit: 最多尝试多少个端口。
    ///   - isAvailable: 端口可用性判定（注入以便单测，生产传 `LocalPort.isFree`）。
    /// - Returns: 第一个可用端口；扫完 `limit` 个仍无空闲则为 nil。
    static func firstAvailable(
        from preferred: Int,
        limit: Int = scanLimit,
        isAvailable: (Int) -> Bool
    ) -> Int? {
        for offset in 0..<max(limit, 1) {
            let candidate = preferred + offset
            guard candidate <= maxPort else { return nil }
            if isAvailable(candidate) { return candidate }
        }
        return nil
    }
}

/// 本地端口占用判定。
///
/// 用「能否绑定」而不是「HTTP 是否响应」来判断空闲：dsh 启动到能响应 HTTP 之间有
/// 数十秒窗口，用 HTTP 探测会把正在启动的服务误判为空闲端口。
enum LocalPort {

    /// 127.0.0.1 上的该端口当前是否可绑定（即空闲）。
    static func isFree(_ port: Int) -> Bool {
        guard port > 0, port <= 65_535 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // SO_REUSEADDR：仅让 TIME_WAIT 残留不影响判定，仍无法绑定正在 LISTEN 的端口。
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        return bound == 0
    }
}
