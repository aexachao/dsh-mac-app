import Testing
import Foundation
@testable import DSHWeb

/// 用哪一份运行时（捆绑的还是用户机器上的）。
///
/// 这个判断是捆绑方案的全部风险所在：选错了不会编译失败，而是启动起来行为不对——
/// 要么白白无视捆绑的那份继续等 npx 下载，要么在用户明确要求用自己那份时还是跑捆绑的。
/// 所以做成纯函数，把每条分支钉死。
struct RuntimeLocatorTests {

    // 固定的假路径，只用来区分身份，不碰真实磁盘
    let bundledNode = URL(fileURLWithPath: "/App/Harness.app/Contents/Resources/runtime/node/bin/node")
    let bundledBoot = URL(fileURLWithPath: "/App/Harness.app/Contents/Resources/runtime/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js")
    let machineNode = URL(fileURLWithPath: "/Users/x/.nvm/versions/node/v24.13.0/bin/node")
    let machineBoot = URL(fileURLWithPath: "/Users/x/.npm/_npx/abc/node_modules/@deepseek-ai/dsh/lib/bin.js")

    // MARK: - 默认：捆绑优先

    @Test func prefersBundledRuntimeWhenPresent() {
        // 捆绑的意义就在这一条：机器上有什么都不影响，用我们验证过的那份
        let plan = RuntimeLocator.plan(bundledNode: bundledNode, bundledBootJS: bundledBoot,
                                       machineNode: machineNode, machineBootJS: machineBoot,
                                       preferMachine: false)
        #expect(plan == .ready(node: bundledNode, bootJS: bundledBoot, source: .bundled))
    }

    @Test func fallsBackToMachineRuntimeWhenBundleAbsent() {
        // `swift run` 的开发构建没有 .app 外壳，Resources/runtime 不存在，
        // 这时必须退回今天的行为，否则日常开发直接不能跑
        let plan = RuntimeLocator.plan(bundledNode: nil, bundledBootJS: nil,
                                       machineNode: machineNode, machineBootJS: machineBoot,
                                       preferMachine: false)
        #expect(plan == .ready(node: machineNode, bootJS: machineBoot, source: .machine))
    }

    @Test func treatsHalfInstalledBundleAsAbsent() {
        // 只有 node 没有 dsh（vendor 脚本被打断、或签名时误删）算不完整。
        // 拿半份捆绑去启动会失败在找不到入口，退回本机那份还有机会成功。
        let plan = RuntimeLocator.plan(bundledNode: bundledNode, bundledBootJS: nil,
                                       machineNode: machineNode, machineBootJS: machineBoot,
                                       preferMachine: false)
        #expect(plan == .ready(node: machineNode, bootJS: machineBoot, source: .machine))
    }

    // MARK: - 没有 dsh 时才走安装

    @Test func needsInstallWhenMachineHasNodeButNoDSH() {
        let plan = RuntimeLocator.plan(bundledNode: nil, bundledBootJS: nil,
                                       machineNode: machineNode, machineBootJS: nil,
                                       preferMachine: false)
        #expect(plan == .needsInstall(node: machineNode))
    }

    @Test func bundledRuntimeNeverTriggersAnInstall() {
        // 捆绑齐全时哪怕本机一个 dsh 都没有，也不该去下载——省掉那 14 分钟正是捆绑的目的
        let plan = RuntimeLocator.plan(bundledNode: bundledNode, bundledBootJS: bundledBoot,
                                       machineNode: machineNode, machineBootJS: nil,
                                       preferMachine: false)
        #expect(plan == .ready(node: bundledNode, bootJS: bundledBoot, source: .bundled))
    }

    @Test func noNodeWhenNeitherSideHasOne() {
        let plan = RuntimeLocator.plan(bundledNode: nil, bundledBootJS: nil,
                                       machineNode: nil, machineBootJS: nil,
                                       preferMachine: false)
        #expect(plan == .noNode)
    }

    // MARK: - 逃生开关

    @Test func escapeHatchUsesMachineRuntime() {
        // 开关存在的理由：捆绑的 dsh 与用户 ~/.dsh 里被更新版 dsh 迁移过的配置对不上时，
        // 用户得有办法改用自己那份，而不是等我们发版
        let plan = RuntimeLocator.plan(bundledNode: bundledNode, bundledBootJS: bundledBoot,
                                       machineNode: machineNode, machineBootJS: machineBoot,
                                       preferMachine: true)
        #expect(plan == .ready(node: machineNode, bootJS: machineBoot, source: .machine))
    }

    @Test func escapeHatchInstallsRatherThanSilentlyUsingTheBundledCopy() {
        // 用户打开开关的意图是「别用你那份」。本机没有 dsh 时应该去装一份最新的，
        // 而不是悄悄回到捆绑那份——那样用户点了开关却什么都没变。
        let plan = RuntimeLocator.plan(bundledNode: bundledNode, bundledBootJS: bundledBoot,
                                       machineNode: machineNode, machineBootJS: nil,
                                       preferMachine: true)
        #expect(plan == .needsInstall(node: machineNode))
    }

    @Test func escapeHatchStillFallsBackWhenMachineHasNoNode() {
        // 开关开着但机器上根本没有 node：能启动比尊重偏好重要
        let plan = RuntimeLocator.plan(bundledNode: bundledNode, bundledBootJS: bundledBoot,
                                       machineNode: nil, machineBootJS: nil,
                                       preferMachine: true)
        #expect(plan == .ready(node: bundledNode, bootJS: bundledBoot, source: .bundled))
    }

    // MARK: - 与 vendor 脚本的布局约定

    @Test func layoutMatchesTheVendorScript() {
        // 这两条相对路径是 scripts/vendor-runtime.sh 与应用之间唯一的约定。
        // 改脚本忘了改这里（或反过来）的后果是捆绑那份永远找不到，静悄悄退回下载路径。
        #expect(RuntimeLocator.nodeRelativePath == "runtime/node/bin/node")
        #expect(RuntimeLocator.bootJSRelativePath == "runtime/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js")
        #expect(RuntimeLocator.manifestRelativePath == "runtime/manifest.json")
    }

    @Test func manifestParsesWhatTheScriptWrites() throws {
        // 逐字复制 vendor-runtime.sh 里的 heredoc 输出
        let json = Data("""
        {
          "node": "24.20.0",
          "dsh": "0.1.1-rc.2",
          "arch": "arm64"
        }
        """.utf8)
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: json)
        #expect(manifest.node == "24.20.0")
        #expect(manifest.dsh == "0.1.1-rc.2")
        #expect(manifest.arch == "arm64")
    }

    @Test func manifestSummaryReadsAsOneLine() throws {
        let manifest = RuntimeManifest(node: "24.20.0", dsh: "0.1.1-rc.2", arch: "arm64")
        #expect(manifest.summary == "dsh 0.1.1-rc.2 / node 24.20.0 (arm64)")
    }
}
