import Foundation
import Testing
@testable import DSHWeb

// MARK: - 日志脱敏

/// 日志会被用户直接复制到 issue 里，dsh 的 stdout/stderr 可能带上游 API 的密钥、
/// OAuth 回调里的 code、Cookie 等。这里的用例分两类：
/// - 必须被遮盖的（漏掉就是泄露）
/// - 必须保持原样的（过度遮盖会让日志失去诊断价值）
struct SecretMaskerTests {

    // MARK: 整值型 header

    @Test func masksAuthorizationHeaderValue() {
        let masked = SecretMasker.mask("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc.def")
        #expect(masked == "Authorization: ****")
    }

    @Test func masksCookieHeaderValue() {
        let masked = SecretMasker.mask("Cookie: session=abc123; theme=dark")
        #expect(masked == "Cookie: ****")
    }

    @Test func masksSetCookieHeaderValue() {
        let masked = SecretMasker.mask("set-cookie: sid=9f8e7d; Path=/; HttpOnly")
        #expect(masked == "set-cookie: ****")
    }

    // MARK: URL

    @Test func masksURLUserInfo() {
        let masked = SecretMasker.mask("proxy https://alice:s3cr3t@proxy.example.com:8080/path")
        #expect(masked == "proxy https://****@proxy.example.com:8080/path")
    }

    @Test func masksSensitiveQueryParametersOnly() {
        // OAuth 回调：code/token 要遮盖，state 这类非敏感参数保留，否则看不出回调是否到位
        let masked = SecretMasker.mask("GET /callback?code=4/0Ad&state=xyz&access_token=ya29.a0Af")
        #expect(masked.contains("code=****"))
        #expect(masked.contains("state=xyz"))
        #expect(masked.contains("access_token=****"))
        #expect(masked.contains("4/0Ad") == false)
        #expect(masked.contains("ya29") == false)
    }

    // MARK: 命名字段

    @Test func masksQuotedJSONSecretField() {
        let masked = SecretMasker.mask(#"{"model":"deepseek","api_key":"sk-liveabcdefghijklmn"}"#)
        #expect(masked.contains(#""api_key":"****""#))
        // 非敏感字段不受影响
        #expect(masked.contains(#""model":"deepseek""#))
        #expect(masked.contains("sk-live") == false)
    }

    @Test func masksYAMLStyleSecretField() {
        let masked = SecretMasker.mask("  refresh_token: 1//0eabcdefg")
        #expect(masked == "  refresh_token: ****")
    }

    @Test func masksCommandLineSecretArgument() {
        let masked = SecretMasker.mask("node bin.js --api-key=abc123xyz --port 3080")
        #expect(masked.contains("--api-key=****"))
        // 端口这类可诊断信息必须保留
        #expect(masked.contains("--port 3080"))
    }

    @Test func keepsGenericCodeFieldOutsideURLs() {
        // 裸 `code:` 太常见（退出码、状态码），只在 URL 查询参数与 JSON 引号形式里遮盖
        #expect(SecretMasker.mask("exit code: 1") == "exit code: 1")
        #expect(SecretMasker.mask("error code: ENOENT") == "error code: ENOENT")
    }

    // MARK: 启发式模式

    @Test func masksSKStyleKeyKeepingRecognizablePrefix() {
        let masked = SecretMasker.mask("using key sk-abcdefghijklmnopqrst for provider")
        #expect(masked.contains("sk-****"))
        #expect(masked.contains("abcdefghij") == false)
        #expect(masked.contains("for provider"))
    }

    @Test func masksBearerTokenOutsideHeaderForm() {
        let masked = SecretMasker.mask("retrying with Bearer eyJhbGciOiJIUzI1NiJ9")
        #expect(masked == "retrying with Bearer ****")
    }

    @Test func masksBasicCredentials() {
        let masked = SecretMasker.mask("auth=Basic YWxpY2U6czNjcjN0")
        #expect(masked.contains("Basic ****"))
        #expect(masked.contains("YWxpY2U") == false)
    }

    @Test func masksLongOpaqueTokenKeepingThreeCharPrefix() {
        // 40 位字母数字串：疑似密钥/哈希，保留 3 位前缀便于区分两次运行是否同一个值
        let token = "AbCdEf0123456789abcdef0123456789abcdefgh"
        let masked = SecretMasker.mask("value \(token) end")
        #expect(masked == "value AbC**** end")
    }

    // MARK: 必须保持原样

    @Test func preservesLocalServiceURL() {
        let line = "dsh web: http://127.0.0.1:3080"
        #expect(SecretMasker.mask(line) == line)
    }

    @Test func preservesOwnStatusLines() {
        let line = "[dsh-web] 服务进程已启动 (PID 12345)"
        #expect(SecretMasker.mask(line) == line)
    }

    @Test func preservesNodeAndCachePaths() {
        // npx 缓存目录哈希只有 16 位，不该被长串规则命中；路径分隔符也不能被吃掉
        let line = "[dsh-web] 使用 Node: /Users/me/.nvm/versions/node/v24.13.0/bin/node"
        #expect(SecretMasker.mask(line) == line)
        let cache = "/Users/me/.npm/_npx/1e7f6d9597241db0/node_modules/@deepseek-ai/dsh/lib/bin.js"
        #expect(SecretMasker.mask(cache) == cache)
    }

    @Test func preservesShortHexIdentifiers() {
        let line = "commit 5aff65a build 23"
        #expect(SecretMasker.mask(line) == line)
    }

    @Test func preservesEmptyAndWhitespaceInput() {
        #expect(SecretMasker.mask("") == "")
        #expect(SecretMasker.mask("   ") == "   ")
    }

    // MARK: 真实日志形态

    @Test func masksProviderKeyInsideJSONErrorPayload() {
        // 上游 401 时最常见的一行：报错正文里回显了整把密钥
        let line = #"{"error":{"message":"Incorrect API key provided: sk-abcdefghijklmnop","type":"invalid_request_error"}}"#
        let masked = SecretMasker.mask(line)
        #expect(masked.contains("sk-****"))
        #expect(masked.contains("abcdefghij") == false)
        // 错误类型是主要诊断线索，必须留下
        #expect(masked.contains("invalid_request_error"))
    }

    @Test func preservesPlainAPIEndpointLine() {
        let line = "POST https://api.deepseek.com/v1/chat/completions 401"
        #expect(SecretMasker.mask(line) == line)
    }

    @Test func overMasksInlineHeaderObjectByDesign() {
        // 已知的过度遮盖：header 规则一路遮到行尾，同一行后面的 content-type 一起丢掉。
        // 这是刻意选择——Cookie 值本身含 `;`/`=`，按分隔符切只会漏遮。用例把这个
        // 取舍固定下来，避免以后被当成 bug「修」成按分隔符截断。
        let line = "headers: { authorization: 'Bearer sk-abcdefghijklmnop', 'content-type': 'application/json' }"
        let masked = SecretMasker.mask(line)
        #expect(masked == "headers: { authorization: ****")
        #expect(masked.contains("sk-") == false)
    }

    // MARK: 性质

    @Test func isIdempotent() {
        let samples = [
            "Authorization: Bearer abc.def.ghi",
            "Cookie: sid=1234567890abcdef",
            #"{"api_key":"sk-liveabcdefghijklmn"}"#,
            "GET /cb?code=4/0Ad&state=xyz",
            "https://alice:s3cr3t@proxy.example.com/p",
            "value AbCdEf0123456789abcdef0123456789abcdefgh end",
        ]
        for sample in samples {
            let once = SecretMasker.mask(sample)
            #expect(SecretMasker.mask(once) == once, "重复脱敏应稳定：\(sample)")
        }
    }

    @Test func maskingNeverGrowsSecretsBack() {
        // 兜底性质：脱敏后不应残留任何 20 位以上的字母数字串
        let noisy = "k1=ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 k2=sk-abcdefghijklmnopqrstuv"
        let masked = SecretMasker.mask(noisy)
        let survivors = masked.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 20 }
        #expect(survivors.isEmpty, "残留长串: \(survivors)")
    }
}
