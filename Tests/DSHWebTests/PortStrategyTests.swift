import Foundation
import Testing
@testable import DSHWeb

// MARK: - 端口分配策略

struct PortStrategyTests {

    @Test func prefersRequestedPortWhenFree() {
        let picked = PortStrategy.firstAvailable(from: 3080) { _ in true }
        #expect(picked == 3080)
    }

    @Test func fallsForwardPastOccupiedPorts() {
        // 3080/3081 被占用 → 退让到 3082，而不是抢占 3080
        let occupied: Set<Int> = [3080, 3081]
        let picked = PortStrategy.firstAvailable(from: 3080) { !occupied.contains($0) }
        #expect(picked == 3082)
    }

    @Test func returnsNilWhenScanLimitExhausted() {
        let picked = PortStrategy.firstAvailable(from: 3080, limit: 4) { _ in false }
        #expect(picked == nil)
    }

    @Test func scanLimitBoundsTheNumberOfProbes() {
        var probed: [Int] = []
        _ = PortStrategy.firstAvailable(from: 3080, limit: 3) { port in
            probed.append(port)
            return false
        }
        #expect(probed == [3080, 3081, 3082])
    }

    @Test func neverProbesBeyondTheTCPPortCeiling() {
        var probed: [Int] = []
        let picked = PortStrategy.firstAvailable(from: 65_534, limit: 8) { port in
            probed.append(port)
            return false
        }
        #expect(picked == nil)
        #expect(probed == [65_534, 65_535])
    }

    // MARK: - 真实端口占用判定

    @Test func detectsOccupiedAndFreedPort() throws {
        let listener = try BoundListener()
        // 自己占住的端口必须判为不可用（否则会把 --port 指向已占用端口）
        #expect(LocalPort.isFree(listener.port) == false)
        listener.shutdown()
        #expect(LocalPort.isFree(listener.port) == true)
    }
}

/// 测试辅助：在 127.0.0.1 上绑定并监听一个由系统分配的端口。
private final class BoundListener {
    let port: Int
    private var fd: Int32
    private var closed = false

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError.failed("socket") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // 让系统挑一个空闲端口
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            close(descriptor)
            throw SocketError.failed("bind/listen")
        }
        var actual = sockaddr_in()
        var actualSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &actualSize)
            }
        }
        guard named == 0 else {
            close(descriptor)
            throw SocketError.failed("getsockname")
        }
        fd = descriptor
        port = Int(UInt16(bigEndian: actual.sin_port))
    }

    func shutdown() {
        guard !closed else { return }
        closed = true
        close(fd)
    }

    deinit { shutdown() }

    enum SocketError: Error { case failed(String) }
}

// MARK: - dsh 进程身份判定

struct DSHProcessIdentityTests {

    @Test func recognizesNpxCachedBootEntry() {
        let cmd = "/Users/me/.nvm/versions/node/v24.13.0/bin/node"
            + " /Users/me/.npm/_npx/1e7f6d9597241db0/node_modules/@deepseek-ai/dsh/lib/bin.js"
            + " --profile web --port 3080"
        #expect(DSHProcessIdentity.isDSHBoot(commandLine: cmd))
    }

    @Test func recognizesNpmBinShim() {
        // 用户从终端跑 `dsh web` 时，ps 看到的是 npm 生成的 bin 链接，不含包路径
        let cmd = "/Users/me/.nvm/versions/node/v24.13.0/bin/node"
            + " /Users/me/.nvm/versions/node/v24.13.0/bin/dsh web"
        #expect(DSHProcessIdentity.isDSHBoot(commandLine: cmd))
    }

    @Test func rejectsUnrelatedNodeServer() {
        // 关键回归：别人的 Node 服务恰好占用同一端口，绝不能被当成 dsh 残留
        let cmd = "/opt/homebrew/bin/node /Users/me/projects/api/server.js --port 3080"
        #expect(DSHProcessIdentity.isDSHBoot(commandLine: cmd) == false)
    }

    @Test func rejectsNonNodeProcess() {
        let cmd = "/usr/bin/python3 -m http.server 3080"
        #expect(DSHProcessIdentity.isDSHBoot(commandLine: cmd) == false)
    }

    @Test func rejectsProcessMerelyMentioningDSH() {
        let cmd = "/usr/bin/grep -r @deepseek-ai/dsh/lib/bin.js /Users/me/src"
        #expect(DSHProcessIdentity.isDSHBoot(commandLine: cmd) == false)
    }

    @Test func rejectsEmptyCommandLine() {
        #expect(DSHProcessIdentity.isDSHBoot(commandLine: "") == false)
        #expect(DSHProcessIdentity.isDSHBoot(commandLine: "   ") == false)
    }

    // MARK: - lsof 输出解析

    @Test func parsesListenerPIDs() {
        let output = "1234\n5678\n"
        #expect(DSHProcessIdentity.parseListenerPIDs(lsofOutput: output) == [1234, 5678])
    }

    @Test func parseListenerPIDsSkipsNoiseAndSystemPIDs() {
        // 空行/非数字要忽略；PID 0 与 1（kernel/launchd）绝不进入待终止列表
        let output = "\n1234\nnot-a-pid\n0\n1\n\n5678\n"
        #expect(DSHProcessIdentity.parseListenerPIDs(lsofOutput: output) == [1234, 5678])
    }

    @Test func parseListenerPIDsDeduplicates() {
        // lsof 对同一进程的多个 fd 会重复输出 PID
        let output = "1234\n1234\n5678\n"
        #expect(DSHProcessIdentity.parseListenerPIDs(lsofOutput: output) == [1234, 5678])
    }
}
