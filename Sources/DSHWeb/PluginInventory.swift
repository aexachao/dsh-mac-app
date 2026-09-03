import Foundation

/// 一个插件：`id` 是它在 dsh 层级栈里的标识，`bundle` 是发现它的那份 patch 所属的 npm 包，
/// `name` 是这个条目自己声明的包名（patch 行上写了 `name:` 才有）。
///
/// 三者都要留着：禁用要用 id，判断「能不能禁」优先看 `name`、没有才退回 `bundle`
/// —— 两者不是一回事，原因见 `PluginInventory.isFirstParty(_:)`。
struct PluginRef: Equatable, Hashable, Sendable {
    let id: String
    let bundle: String
    let name: String?

    init(id: String, bundle: String, name: String? = nil) {
        self.id = id
        self.bundle = bundle
        self.name = name
    }
}

/// patch 文件里的一个条目：`id` 加上它自己声明的包名（写了 `name:` 才有）。
///
/// 两个字段必须一起读出来。第三方 bundle 的 patch 里合法地存在「重新配置一个已有条目」
/// 的行，那个条目可以是第一方的；只读 id 就分不清「这是它自己的插件」和「它在改别人的
/// 插件」，而这两者在安全模式下的处置正好相反。
struct PatchEntry: Equatable, Sendable {
    let id: String
    let name: String?
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

    /// 只认 `id:` 和 `name:` 两个键。bundle patch 是 `- insert:` 下的 `- id:/name:`，
    /// profile patch 是 `- id:/disabled:`——两种形状里 id 行的样子是一样的。
    ///
    /// 分三组：前缀（缩进 + 可能的 `-`，长度就是键所在的列）、键名、值。
    private static let keyLine = try! NSRegularExpression(pattern: #"^(\s*(?:-\s*)?)(id|name):\s*(\S.*)$"#)

    /// patch 文件里的一行键值。
    private struct Key {
        let name: String
        let value: String
        /// 键名所在的列。`name:` 归属哪个 `id:` 全靠这个判断。
        let column: Int
        /// 行首带 `-`，也就是另起一个条目。
        let startsEntry: Bool
    }

    // MARK: - 解析

    /// 从一份 patch YAML 文本里抽出条目，保持出现顺序，**不去重**。
    ///
    /// 手写正则而不是引 YAML 解析器：这里只需要两个键，而项目刻意保持零外部依赖。
    /// 代价是遇到奇异写法（流式序列、锚点）会漏读；漏读的后果是那个插件在安全模式下
    /// 仍然启用，属于保守的失败方向——不会写坏配置。
    ///
    /// `name:` 认列不认顺序：与前一个 `id:` 键**同列**、且行首没有 `-`（有 `-` 就是另
    /// 一个条目了）的那个 `name:`，才是这个条目的名字。这条规则的作用是挡住嵌在
    /// `config:` 里的 `name:` ——它缩进更深，列不同。缩进写法古怪时读不到名字，
    /// 退化成「只有 id」，也就是这条规则加进来之前的行为。
    static func entries(inPatch text: String) -> [PatchEntry] {
        var result: [PatchEntry] = []
        // 正在等 `name:` 的条目：它在 result 里的下标，以及它的 `id:` 所在的列。
        var open: (index: Int, column: Int)?

        for rawLine in text.components(separatedBy: .newlines) {
            guard let key = key(in: stripComment(rawLine)) else { continue }
            guard key.name == "id" else {
                // 同列、且不另起条目的 name:，属于刚才那个 id；只认第一个。
                guard let slot = open, slot.column == key.column, !key.startsEntry else { continue }
                result[slot.index] = PatchEntry(id: result[slot.index].id, name: key.value)
                open = nil
                continue
            }
            result.append(PatchEntry(id: key.value, name: nil))
            open = (index: result.count - 1, column: key.column)
        }
        return result
    }

    /// 从一份 patch YAML 文本里抽出插件 id，保持出现顺序、去重。
    static func ids(inPatch text: String) -> [String] {
        var seen = Set<String>()
        return entries(inPatch: text).map(\.id).filter { seen.insert($0).inserted }
    }

    /// 读出一行里的 `id:` / `name:`；其他键（`disabled:`、`config:` 等）返回 nil。
    private static func key(in line: String) -> Key? {
        guard !line.isEmpty,
              let match = keyLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let prefixRange = Range(match.range(at: 1), in: line),
              let nameRange = Range(match.range(at: 2), in: line),
              let valueRange = Range(match.range(at: 3), in: line)
        else { return nil }
        let value = unquote(String(line[valueRange]).trimmingCharacters(in: .whitespaces))
        guard !value.isEmpty else { return nil }
        let prefix = line[prefixRange]
        return Key(
            name: String(line[nameRange]),
            value: value,
            column: prefix.count,
            startsEntry: prefix.contains("-")
        )
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

    /// npm 包名是否落在第一方 scope 里。
    static func isFirstParty(bundle: String) -> Bool {
        bundle.hasPrefix(firstPartyScope)
    }

    /// 这个条目是否第一方。
    ///
    /// **先看条目自己声明的 `name:`，只有没写时才退回它所在的 bundle。** 两者会不一致，
    /// 而且不是异常写法：第三方 bundle 的 patch 里合法地存在「重新配置一个第一方条目」
    /// 的行——实测 `@linxin666/dsh-perf` 就用
    /// `- id: session-persistence-jsonl` / `name: '@deepseek-ai/dsh-session-persistence-jsonl'`
    /// 给内置的会话持久化插件改了 root 路径。
    ///
    /// 只按 bundle 判定的后果是实测出来的，而且是致命的：安全模式把这个第一方条目一起
    /// 禁掉，`sessionPersistence` 就没人提供了，`dsh-session-checkpoint-policy`、
    /// `dsh-message-feedback`、`dsh-workspace`、`dsh-session-projection-cache` 四个第一方
    /// 插件全部卡在 pending，`dsh-host-apiproxy` 又卡在 `workspaceRegistry` 上，
    /// dsh 报 `plugin tree failed to load` 直接退出——安全模式本身成了启动不了的原因。
    static func isFirstParty(_ plugin: PluginRef) -> Bool {
        isFirstParty(bundle: plugin.name ?? plugin.bundle)
    }

    // MARK: - 扫描目录

    /// 扫描 profile 目录，列出所有能静态发现的插件。
    ///
    /// 全程容错：package.json 读不到、bundle 没装、patch 文件缺失都只是少几条记录，
    /// 不会整体失败。安全模式是最后一道防线，它自己不能因为环境不全而失效。
    static func scan(profileDirectory: URL) -> [PluginRef] {
        var result: [PluginRef] = []
        var index: [String: Int] = [:]

        /// 同一个 id 在多份 patch 里出现时，认第一方的那一次。
        ///
        /// 不能简单先到先得：同一个第一方条目往往被一个第三方 bundle 声明了 `name:`、
        /// 又被另一个只写了 `- id: … / disabled: true`（`@morlay/better-session` 就是这么
        /// 关掉内置持久化插件的），先到先得的结果取决于 `dsh.profile.bundles` 的排列顺序
        /// ——那是用户装插件的顺序，我们无从控制。认第一方是唯一与顺序无关的规则，
        /// 方向也对：宁可漏禁一个第三方插件，不可误禁一个第一方条目。
        func record(_ entry: PatchEntry, bundle: String) {
            let ref = PluginRef(id: entry.id, bundle: bundle, name: entry.name)
            guard let existing = index[entry.id] else {
                index[entry.id] = result.count
                result.append(ref)
                return
            }
            if isFirstParty(ref), !isFirstParty(result[existing]) {
                result[existing] = ref
            }
        }

        for bundle in bundles(in: profileDirectory) {
            let patch = profileDirectory
                .appendingPathComponent("node_modules")
                .appendingPathComponent(bundle)
                .appendingPathComponent(patchFileName)
            guard let text = try? String(contentsOf: patch, encoding: .utf8) else { continue }
            for entry in entries(inPatch: text) {
                record(entry, bundle: bundle)
            }
        }

        // profile 自己的 patch 放在最后：bundle 的归属信息更准确。
        let own = profileDirectory.appendingPathComponent(patchFileName)
        if let text = try? String(contentsOf: own, encoding: .utf8) {
            for entry in entries(inPatch: text) {
                record(entry, bundle: profileSource)
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

    /// 安全模式要禁用的 id：第三方条目，去重后排序。
    ///
    /// 判定走 `isFirstParty(_:)`（条目自己的 `name:` 优先），不是 `isFirstParty(bundle:)`
    /// ——差别不是细节，按 bundle 判会误禁第一方条目并让 dsh 起不来。
    ///
    /// 排序是为了 overlay 的内容稳定——同一套插件每次生成的文件应当逐字节相同，
    /// 用户 diff 它时才看得出「这次和上次到底有没有变」。
    static func thirdPartyIDs(in plugins: [PluginRef]) -> [String] {
        Set(plugins.filter { !isFirstParty($0) }.map(\.id)).sorted()
    }
}
