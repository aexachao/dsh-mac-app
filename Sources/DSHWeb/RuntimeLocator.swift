import Foundation

/// 这次启动用的是哪一份运行时。
///
/// 需要区分是因为两份的失败含义完全不同：捆绑那份跑不起来是**我们**发错了版本，
/// 用户只能等我们修；本机那份跑不起来是他机器上的状态，自己就能修。诊断报告和
/// 失败文案都要据此说不同的话。
enum RuntimeSource: Equatable {
    /// `.app/Contents/Resources/runtime`，由 scripts/vendor-runtime.sh 备进去。
    case bundled
    /// 用户机器上的 node（nvm / Homebrew / 系统）加 npx 缓存里的 dsh。
    case machine
}

/// 解析结果：直接能起、还是得先装、还是连 node 都没有。
enum RuntimePlan: Equatable {
    case ready(node: URL, bootJS: URL, source: RuntimeSource)
    /// 有 node 但没有 dsh，需要先跑 npx 安装（几百 MB，十几分钟）。
    case needsInstall(node: URL)
    /// 两边都没有 node，启动无从开始。
    case noNode
}

/// 捆绑运行时的版本清单，由 vendor 脚本写在 `runtime/manifest.json`。
struct RuntimeManifest: Decodable, Equatable {
    let node: String
    let dsh: String
    let arch: String

    /// 诊断报告与日志里的一行式描述。
    var summary: String { "dsh \(dsh) / node \(node) (\(arch))" }
}

/// 决定用哪一份运行时。
///
/// 判断做成纯函数，因为这里每一条分支错了都表现为「行为不对」而不是编译失败：
/// 无视捆绑那份会让用户白等一次十几分钟的下载；在用户明确要求用自己那份时仍跑捆绑的，
/// 则是他点了开关却什么都没变。
enum RuntimeLocator {

    // MARK: - 与 vendor 脚本的布局约定
    //
    // 这三条相对路径是 scripts/vendor-runtime.sh 与应用之间唯一的接口。改一边忘了改
    // 另一边，后果是捆绑那份永远找不到、静悄悄退回下载路径——不会有任何报错。
    // RuntimeLocatorTests.layoutMatchesTheVendorScript 把它们钉死。

    static let nodeRelativePath = "runtime/node/bin/node"
    static let bootJSRelativePath = "runtime/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js"
    static let manifestRelativePath = "runtime/manifest.json"

    // MARK: - 纯判定

    /// 选出这次启动要用的 node 与 dsh 入口。
    ///
    /// 优先级：
    /// 1. 捆绑那份（完整时）—— 捆绑的全部意义就是让机器上的状态不再影响启动
    /// 2. 本机 node + npx 缓存里的 dsh
    /// 3. 本机 node，dsh 缺失 → 先装
    ///
    /// `preferMachine` 把 1 让给 2：捆绑的 dsh 与用户 `~/.dsh` 里被更新版 dsh 迁移过的
    /// 配置对不上时，这是他不必等我们发版的唯一出路。让位有两处刻意的边界：
    /// - 本机有 node 但没有 dsh 时去**装**，而不是悄悄回到捆绑那份——否则用户点了开关
    ///   却什么都没变，而这恰好是他打开开关时最想避免的情形。
    /// - 本机连 node 都没有时仍然回到捆绑那份：能启动比尊重偏好重要。
    static func plan(
        bundledNode: URL?,
        bundledBootJS: URL?,
        machineNode: URL?,
        machineBootJS: URL?,
        preferMachine: Bool
    ) -> RuntimePlan {
        // 半份捆绑（有 node 没 dsh，或反之）等于没有：拿它去启动只会失败在找不到入口，
        // 而退回本机那份还有机会成功。
        let bundled: (node: URL, bootJS: URL)? = {
            guard let bundledNode, let bundledBootJS else { return nil }
            return (bundledNode, bundledBootJS)
        }()

        if let bundled, !preferMachine {
            return .ready(node: bundled.node, bootJS: bundled.bootJS, source: .bundled)
        }
        if let machineNode {
            if let machineBootJS {
                return .ready(node: machineNode, bootJS: machineBootJS, source: .machine)
            }
            return .needsInstall(node: machineNode)
        }
        if let bundled {
            return .ready(node: bundled.node, bootJS: bundled.bootJS, source: .bundled)
        }
        return .noNode
    }

    // MARK: - 在 .app 里找捆绑的那份

    /// `swift run` 的开发构建没有 `.app` 外壳，`resourceURL` 下不存在 `runtime/`，
    /// 于是这几个查找全部返回 nil，`plan` 自然退回本机路径——日常开发不受捆绑影响。

    static func bundledNode(bundle: Bundle = .main) -> URL? {
        readable(bundle.resourceURL?.appendingPathComponent(nodeRelativePath), executable: true)
    }

    static func bundledBootJS(bundle: Bundle = .main) -> URL? {
        readable(bundle.resourceURL?.appendingPathComponent(bootJSRelativePath), executable: false)
    }

    static func bundledManifest(bundle: Bundle = .main) -> RuntimeManifest? {
        guard let url = readable(bundle.resourceURL?.appendingPathComponent(manifestRelativePath),
                                 executable: false),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RuntimeManifest.self, from: data)
    }

    private static func readable(_ url: URL?, executable: Bool) -> URL? {
        guard let url else { return nil }
        let fm = FileManager.default
        let ok = executable
            ? fm.isExecutableFile(atPath: url.path)
            : fm.isReadableFile(atPath: url.path)
        return ok ? url : nil
    }
}

/// 「改用本机 dsh」偏好（逃生开关）。
///
/// 默认关闭：绝大多数用户永远不需要知道它存在。只有当捆绑的 dsh 与 `~/.dsh` 的配置格式
/// 对不上时，失败界面才把它作为恢复动作推到用户面前。
struct MachineRuntimePreference {

    private static let key = "preferMachineRuntime"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Self.key)
    }

    func set(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.key)
    }
}
