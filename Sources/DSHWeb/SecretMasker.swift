import Foundation

/// 日志脱敏：把可能泄密的片段替换成 `****`，再让它进入日志缓冲区。
///
/// 为什么需要：日志面板的内容会被用户直接复制到 issue 或聊天里，而 dsh 的
/// stdout/stderr 是上游进程的原始输出——上游 API 报错时可能带上 `Authorization`
/// 头、OAuth 回调 URL 里的 `code`、配置里的 provider 密钥。应用无法预知这些内容，
/// 只能在写入前统一过一遍。
///
/// 设计取向：**宁可多遮盖，不可漏遮盖**。
/// - 结构清晰的地方（header、URL 查询参数、命名字段）整值替换为 `****`；
/// - 只能靠形状判断的地方（`sk-` 密钥、Bearer/Basic、超长不透明串）保留前 3 位
///   再加 `****`，这样两次运行里的同一个值仍可比对，但泄露量可以忽略。
///
/// 反向约束同样重要：诊断信息不能被吃掉。因此 `code` / `key` / `auth` 这类过于
/// 常见的词只在 URL 查询参数里视为敏感（OAuth 的 `?code=` 确实是凭据），裸写的
/// `exit code: 1`、`--port 3080` 必须原样保留——这些都由单测锁定。
enum SecretMasker {

    /// 统一的遮盖标记。
    private static let redaction = "****"

    /// 一条替换规则：正则 + 模板（`$n` 引用捕获组）。
    private struct Rule {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String) {
            // 模式是源码内的字面量，编译失败属于开发期错误，直接崩比静默失效安全。
            self.regex = try! NSRegularExpression(pattern: pattern)
            self.template = template
        }
    }

    /// 敏感字段名（引号 JSON 形式）。长的排前面，避免短名先匹配后回溯。
    private static let quotedFieldNames = """
    access_token|refresh_token|private_key|client_secret|authorization\
    |credential|session_id|sessionid|id_token|password|api_key|apikey\
    |passwd|session|signature|secret|cookie|token
    """

    /// 敏感字段名（裸值形式 `name: value` / `name=value`）。
    ///
    /// 比引号形式更保守：不含 `auth`、`code`、`key`，它们裸写时几乎都是诊断信息
    /// （`error code:`、`exit code:`），在 URL 查询参数规则里另有覆盖。
    private static let bareFieldNames = """
    access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret\
    |private[_-]?key|api[_-]?key|apikey|session[_-]?id|authorization\
    |credential|password|passwd|signature|secret|token
    """

    /// URL 查询参数名里出现即视为敏感的词根。
    private static let sensitiveQueryMarkers =
        "auth|code|credential|key|passwd|password|secret|session|signature|token"

    /// 规则按顺序应用：结构化的先做，启发式的兜底。
    ///
    /// 顺序不是可选项——先把 `Authorization: Bearer x` 整行遮成 `****`，
    /// 后面的 Bearer 规则就不会再看到它；各规则里的 `(?!\*\*\*\*)` 负向断言保证
    /// 重复脱敏结果稳定（幂等），日志被二次处理时不会层层叠加。
    private static let rules: [Rule] = [
        // 1. 整值型 header：值一律遮到行尾。Cookie 值本身含 `;`、`=`，
        //    按分隔符切开只会漏，所以这里选择整段遮盖。
        Rule(
            //    负向断言必须放在字段名之后、分隔符之前：若放到分隔符之后，正则会把
            //    `\s*` 回退成不含空格的形式来绕过断言，结果把 `X: ****` 改写成 `X:****`。
            #"(?i)\b(set-cookie|cookie|proxy-authorization|authorization)(?!\s*:\s*\*\*\*\*$)(\s*:\s*).+$"#,
            "$1$2\(redaction)"
        ),
        // 2. URL 里的 userinfo（`https://user:pass@host`）。
        Rule(
            #"(?i)([a-z][a-z0-9+.-]*://)[^/\s:@]+(:[^/\s@]*)?@"#,
            "$1\(redaction)@"
        ),
        // 3. 敏感查询参数：只遮参数值，非敏感参数（如 OAuth 的 state）保留，
        //    否则看不出回调有没有正常到达。
        Rule(
            #"(?i)([?&][a-z0-9_.\[\]-]*(\#(sensitiveQueryMarkers))[a-z0-9_.\[\]-]*=)[^&\s"'<>]+"#,
            "$1\(redaction)"
        ),
        // 4. JSON 引号字段：值可能带引号也可能不带（数字/布尔）。
        Rule(
            #"(?i)("(\#(quotedFieldNames))"\s*:\s*)("[^"]*"|[^\s,}\]]+)"#,
            "$1\"\(redaction)\""
        ),
        // 5. 裸值字段：YAML 的 `token: x`、命令行的 `--api-key=x`。
        Rule(
            #"(?i)\b(\#(bareFieldNames))(\s*[:=]\s*)(?!\*\*\*\*)["']?[^\s,;}"']+["']?"#,
            "$1$2\(redaction)"
        ),
        // 6. Bearer / Basic：保留方案名，便于看出是哪种认证在失败。
        Rule(
            #"(?i)\b(bearer|basic)(\s+)(?!\*\*\*\*)[A-Za-z0-9._~+/=-]+"#,
            "$1$2\(redaction)"
        ),
        // 7. `sk-` 形式的密钥：前缀本身就是 3 位可读标识。
        Rule(#"\bsk-[A-Za-z0-9_-]{12,}"#, "sk-\(redaction)"),
        // 8. 兜底：32 位以上连续字母数字串，疑似密钥或哈希。路径、版本号、
        //    npx 缓存目录名（16 位）都短于这个阈值，不会被误伤。
        Rule(
            #"(?<![A-Za-z0-9])([A-Za-z0-9]{3})[A-Za-z0-9]{29,}(?![A-Za-z0-9])"#,
            "$1\(redaction)"
        ),
    ]

    /// 对一行文本做脱敏。纯函数，无副作用，可安全用于任意线程。
    static func mask(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return rules.reduce(text) { partial, rule in
            rule.regex.stringByReplacingMatches(
                in: partial,
                options: [],
                range: NSRange(partial.startIndex..., in: partial),
                withTemplate: rule.template
            )
        }
    }
}
