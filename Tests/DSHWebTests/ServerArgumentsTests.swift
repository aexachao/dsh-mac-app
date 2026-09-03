import Testing
@testable import DSHWeb

/// 拼给 node 的 dsh 启动参数。
///
/// 这些参数是应用与 dsh 之间唯一的接口，拼错的代价都是「启动看起来成功但行为不对」，
/// 而不是编译错误，所以单独拎出来固定住。
struct ServerArgumentsTests {

    @Test func bootEntryComesFirst() {
        // node 的第一个参数必须是脚本路径，否则 node 会把 --profile 当成自己的参数
        let args = ServerArguments.spawn(bootJS: "/cache/lib/bin.js", port: 3080, overlay: nil)
        #expect(args.first == "/cache/lib/bin.js")
    }

    @Test func usesProfileFormRatherThanTheWebSubcommand() {
        // `dsh web` 是 `--profile web` 的别名，但拒收父级的 --patch/--port，
        // 安全模式 overlay 与显式端口都得从父级参数进去
        let args = ServerArguments.spawn(bootJS: "/cache/lib/bin.js", port: 3080, overlay: nil)
        #expect(args.contains("--profile"))
        #expect(args.contains("web"))
    }

    @Test func passesThePortExplicitly() {
        // 端口由应用先 bind() 挑好再传给 dsh，不能依赖 dsh 自己的默认值
        let args = ServerArguments.spawn(bootJS: "/cache/lib/bin.js", port: 3091, overlay: nil)
        guard let index = args.firstIndex(of: "--port") else {
            Issue.record("缺少 --port")
            return
        }
        #expect(args[args.index(after: index)] == "3091")
    }

    @Test func suppressesTheAutoOpenedBrowser() {
        // dsh 0.1.1-rc.2 起默认会自己打开系统浏览器。应用本身就是那个界面，
        // 再弹一个浏览器窗口等于每次启动都多一个不请自来的标签页。
        let args = ServerArguments.spawn(bootJS: "/cache/lib/bin.js", port: 3080, overlay: nil)
        #expect(args.contains("--no-open"))
    }

    @Test func overlayFlagPrecedesTheProfileAppFlags() {
        // dsh 的启动器一碰到第一个它不认识的参数（`--port` 属于 web app 自己），就把余下的
        // 整段转交给被引导的 app。`--patch` 排在 `--port` 之后就落到不认识它的那一侧，
        // 实测报 `error: unknown option '--patch'` 并 exit 1 —— 安全模式因此一次都没成功过。
        let args = ServerArguments.spawn(bootJS: "/cache/lib/bin.js", port: 3080,
                                        overlay: "/support/Harness/safe-mode.yml")
        guard let patch = args.firstIndex(of: "--patch"),
              let profile = args.firstIndex(of: "--profile"),
              let port = args.firstIndex(of: "--port"),
              let noOpen = args.firstIndex(of: "--no-open") else {
            Issue.record("缺少必需参数：\(args)")
            return
        }
        #expect(args[args.index(after: patch)] == "/support/Harness/safe-mode.yml")
        #expect(patch > profile)
        #expect(patch < port)
        #expect(patch < noOpen)
    }

    @Test func safeModeArgumentOrderIsExact() {
        // 顺序本身就是这里唯一会出错的东西，所以整条命令行逐项钉住
        let args = ServerArguments.spawn(bootJS: "/cache/lib/bin.js", port: 3080,
                                        overlay: "/support/Harness/safe-mode.yml")
        #expect(args == ["/cache/lib/bin.js", "--profile", "web",
                         "--patch", "/support/Harness/safe-mode.yml",
                         "--port", "3080", "--no-open"])
    }

    @Test func omitsPatchWhenNotInSafeMode() {
        // 正常模式下不该出现空的 --patch：dsh 会把它当成缺参数直接报错
        let args = ServerArguments.spawn(bootJS: "/cache/lib/bin.js", port: 3080, overlay: nil)
        #expect(args.contains("--patch") == false)
    }
}
