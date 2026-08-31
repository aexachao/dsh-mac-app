import Foundation

/// 一个插件：`id` 是它在 dsh 层级栈里的标识，`bundle` 是把它带进来的 npm 包。
///
/// 两者都要留着：禁用要用 id，判断「能不能禁」要看它来自哪个 bundle。
struct PluginRef: Equatable, Hashable, Sendable {
    let id: String
    let bundle: String
}

/// 静态枚举 profile 里装了哪些插件。
///
/// 为什么不用 `dsh --dump-config`：那要求 dsh 能启动，而这份清单存在的唯一目的
/// 是在「dsh 启动不了」时救场。所以只读磁盘上的文件，不依赖 dsh 能跑。
///
/// 依据 profile 根目录的 `cordis.yml` 自述的组合顺序：先是 `package.json` 里
/// `dsh.profile.bundles` 列出的每个 bundle（各自带一份 `cordis.patch.yml`），
/// 然后是 profile 自己的 `cordis.patch.yml`，最后才是 `--patch` overlay。
enum PluginInventory {

    /// profile 自己的 patch 文件里手写的条目归到这个来源名下。
    ///
    /// 这类 id 来源不明（可能来自一个已经卸载的 bundle），所以按第三方处理。
    static let profileSource = "profile"

    /// 第一方 scope。安全模式必须保留 dsh 自己的插件，否则 Web 界面根本起不来，
    /// 「恢复」也就无从谈起。
    private static let firstPartyScope = "@deepseek-ai/"

    private static let patchFileName = "cordis.patch.yml"

    /// 只认 `id:` 这一个键。bundle patch 是 `- insert:` 下的 `- id:/name:`，
    /// profile patch 是 `- id:/disabled:`——两种形状里 id 行的样子是一样的。
    private static let idLine = try! NSRegularExpression(pattern: #"^\s*(?:-\s*)?id:\s*(\S.*)$"#)

    // MARK: - 解析

    /// 从一份 patch YAML 文本里抽出插件 id，保持出现顺序、去重。
    ///
    /// 手写正则而不是引 YAML 解析器：这里只需要一个键，而项目刻意保持零外部依赖。
    /// 代价是遇到奇异写法（流式序列、锚点）会漏读；漏读的后果是那个插件在安全模式下
    /// 仍然启用，属于保守的失败方向——不会误禁用、更不会写坏配置。
    static func ids(inPatch text: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripComment(rawLine)
            guard !line.isEmpty,
                  let match = idLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line)
            else { continue }
            let id = unquote(String(line[range]).trimmingCharacters(in: .whitespaces))
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }

    /// 去掉整行注释与行尾注释。
    ///
    /// 只在 `#` 前有空白时才当行尾注释：插件 id 里不会有空格，但可能有 `#`。
    private static func stripComment(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#") else { return "" }
        guard let hash = line.range(of: " #") else { return line }
        return String(line[line.startIndex..<hash.lowerBound])
    }

    private static func unquote(_ value: String) -> String {
        for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote) && value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// bundle 是否第一方。
    static func isFirstParty(bundle: String) -> Bool {
        bundle.hasPrefix(firstPartyScope)
    }

    // MARK: - 扫描目录

    /// 扫描 profile 目录，列出所有能静态发现的插件。
    ///
    /// 全程容错：package.json 读不到、bundle 没装、patch 文件缺失都只是少几条记录，
    /// 不会整体失败。安全模式是最后一道防线，它自己不能因为环境不全而失效。
    static func scan(profileDirectory: URL) -> [PluginRef] {
        var result: [PluginRef] = []
        var seen = Set<String>()

        for bundle in bundles(in: profileDirectory) {
            let patch = profileDirectory
                .appendingPathComponent("node_modules")
                .appendingPathComponent(bundle)
                .appendingPathComponent(patchFileName)
            guard let text = try? String(contentsOf: patch, encoding: .utf8) else { continue }
            for id in ids(inPatch: text) where seen.insert(id).inserted {
                result.append(PluginRef(id: id, bundle: bundle))
            }
        }

        // profile 自己的 patch 放在最后：bundle 的归属信息更准确，先到先得。
        let own = profileDirectory.appendingPathComponent(patchFileName)
        if let text = try? String(contentsOf: own, encoding: .utf8) {
            for id in ids(inPatch: text) where seen.insert(id).inserted {
                result.append(PluginRef(id: id, bundle: profileSource))
            }
        }
        return result
    }

    /// 读 `package.json` 的 `dsh.profile.bundles`。
    private static func bundles(in profileDirectory: URL) -> [String] {
        let url = profileDirectory.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String]
        else { return [] }
        return bundles
    }

    // MARK: - 后台扫描

    /// 扫描的时间上限（秒）。正常一次只读十来个小文件，是毫秒级的事；这个上限不是为
    /// 「慢」准备的，是为「永远不返回」准备的。
    static let scanTimeout: TimeInterval = 3

    /// 在后台线程扫描，并且**一定会返回**。
    ///
    /// 为什么非要离开主线程、非要有上限：`node_modules` 里的插件可以是指向任何位置的
    /// 符号链接，而 `~/Documents` 这类目录受 TCC 保护，没授权时 `open()` 既不返回也不
    /// 报错——`try?` 兜得住错误，兜不住阻塞。这段代码原先跑在主线程上，撞上那种路径
    /// 整个应用就冻住：日志面板打不开，⌘Q 也退不掉，用户只剩强制退出这一条路。
    ///
    /// 超时返回 nil 而不是空数组：调用方必须能区分「确实没有插件」和「没扫完」，
    /// 后者不该被写成一份「没有插件需要停用」的 overlay。至于被卡住的那条线程，
    /// 放弃它就是了（见 `Deadline`）。
    static func scanInBackground(
        profileDirectory: URL,
        timeout: TimeInterval = scanTimeout
    ) async -> [PluginRef]? {
        await Deadline.run(timeout: timeout) { scan(profileDirectory: profileDirectory) }
    }

    // MARK: - 待禁用清单

    /// 安全模式要禁用的 id：第三方 bundle 带来的插件，去重后排序。
    ///
    /// 排序是为了 overlay 的内容稳定——同一套插件每次生成的文件应当逐字节相同，
    /// 用户 diff 它时才看得出「这次和上次到底有没有变」。
    static func thirdPartyIDs(in plugins: [PluginRef]) -> [String] {
        Set(plugins.filter { !isFirstParty(bundle: $0.bundle) }.map(\.id)).sorted()
    }
}
