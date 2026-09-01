import SwiftUI
import Combine

/// 主界面：正常运行时为纯 WebView（无任何遮挡）；
/// 仅在启动中/失败时显示状态栏；日志侧栏可在菜单中随时开关。
struct ContentView: View {
    @State private var server = ServerManager.shared
    @State private var app = AppState.shared

    /// 标题栏高度，也就是 `NSHostingView` 给内容加的 safeArea 顶部内边距。
    /// 由窗口实测得到（见 `WindowChrome.titlebarHeight`），不写死常量。
    @State private var titlebarHeight: CGFloat = 0

    /// 拖拽条挂在窗口的 contentView 上（不在 SwiftUI 布局里），所以要留着窗口引用。
    @State private var window: NSWindow?

    private var language: AppLanguage { MenuBuilder.current }

    var body: some View {
        VStack(spacing: 0) {
            if server.isSafeMode {
                SafeModeBanner(
                    disabled: server.disabledPlugins,
                    onExit: { server.exitSafeMode() }
                )
                Divider()
            }
            if needsHeader {
                header
                Divider()
            }
            HStack(spacing: 0) {
                // 网页整体留在标题栏**下方**（不加 `ignoresSafeArea`）：红绿灯那条横带里
                // 于是不可能有任何页面内容，拖拽条整条通吃鼠标事件也就不会抢走页面的点击。
                // 此前网页铺到 y=0、靠 `#root` 的 padding-top 让位，推得动的只有 `#root`
                // 的子元素，而 dsh 右上角那两个图标是 `position: fixed`（相对视口定位），
                // padding 根本推不动它们 —— 它们留在横带里，点击被拖拽条吃掉。
                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if app.showLogs {
                    Divider()
                    LogView(lines: server.logLines) {
                        app.showLogs = false
                    }
                }
            }
        }
        .background(WindowAccessor { window in
            WindowChrome.apply(window)
            self.window = window
            titlebarHeight = WindowChrome.titlebarHeight(of: window)
        })
        .onAppear {
            server.start()
            app.webController.beginUserActivity()
            // 兜底：初始状态即就绪（.external/.running）时 onChange 不会触发，这里补一次
            loadIfReady()
            syncTopBand()
        }
        .onChange(of: titlebarHeight) { _, _ in
            syncTopBand()
        }
        .onChange(of: isImmersive) { _, _ in
            syncTopBand()
        }
        // 页面实测到的两段颜色（换主题、折叠侧栏都会变）
        .onChange(of: app.topBand) { _, _ in
            syncTopBand()
        }
        // 标题栏高度不是常量：进入全屏后标题栏收起，实测值变成 0，
        // 横带与拖拽条都得跟着归零，否则窗口顶上多出一条画错色的横带。
        .onReceive(chromeChanges) { note in
            guard let changed = note.object as? NSWindow, changed == window else { return }
            titlebarHeight = WindowChrome.titlebarHeight(of: changed)
        }
        .onChange(of: server.webURL) { _, url in
            guard let url else { return }
            NSLog("[dsh-web] 加载页面: %@", url.absoluteString)
            app.webController.load(url)
        }
        .onChange(of: server.state) { _, state in
            // 启动失败时自动展开日志面板，让用户看到原因
            if case .failed = state { app.showLogs = true }
            if case .running = state { loadIfReady() }
        }
    }

    /// 就绪时加载页面（幂等：WebView 重复 load 同一 URL 无副作用）。
    private func loadIfReady() {
        guard let url = server.webURL else { return }
        NSLog("[dsh-web] 加载页面: %@", url.absoluteString)
        app.webController.load(url)
    }

    /// 正常运行（含外部实例）时隐藏状态栏。
    private var needsHeader: Bool {
        switch server.state {
        case .starting, .failed: true
        case .running, .external: false
        }
    }

    /// 网页可以铺满到窗口顶部的条件：上方没有我们自己的东西。
    /// 有状态栏或安全模式横幅时，横带上方那一段不再是网页，实测的颜色也就不该画上去。
    private var isImmersive: Bool {
        Self.isImmersive(needsHeader: needsHeader, isSafeMode: server.isSafeMode)
    }

    static func isImmersive(needsHeader: Bool, isSafeMode: Bool) -> Bool {
        !needsHeader && !isSafeMode
    }

    /// 横带的高度与颜色只有这一个出口。
    ///
    /// 高度始终等于标题栏实测高度 —— 拖拽条得一直在，不然红绿灯右边那段窗口拖不动；
    /// 颜色只在网页确实顶在最上面时才画，否则横带露出窗口底色（跟加这条横带之前一样）。
    private func syncTopBand() {
        WindowChrome.setBandHeight(titlebarHeight, on: window)
        WindowChrome.setBandColors(isImmersive ? app.topBand : nil, on: window)
        // 拿到窗口引用、或高度变化之后让页面补量一次：这些时刻页面自己收不到任何事件
        app.webController.measureTopBand()
    }

    /// 可能改变标题栏实测高度的窗口事件。
    private var chromeChanges: AnyPublisher<Notification, Never> {
        let center = NotificationCenter.default
        return Publishers.MergeMany(
            center.publisher(for: NSWindow.didResizeNotification),
            center.publisher(for: NSWindow.didEnterFullScreenNotification),
            center.publisher(for: NSWindow.didExitFullScreenNotification)
        ).eraseToAnyPublisher()
    }

    // MARK: - 顶部状态栏（仅启动中/失败时显示）

    private var header: some View {
        HStack(spacing: 12) {
            statusDot
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                app.showLogs.toggle()
            } label: {
                Label(Strings.text(app.showLogs ? .hideLogs : .logs, language), systemImage: "terminal")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 9, height: 9)
    }

    private var statusColor: Color {
        switch server.state {
        case .starting: .orange
        case .running, .external: .green
        case .failed: .red
        }
    }

    private var statusText: String {
        switch server.state {
        case .starting:
            Strings.text(.statusStarting, language)
        case .running:
            Strings.text(.statusRunning, language, substituting: ["port": String(server.port)])
        case .external:
            Strings.text(.statusExternal, language, substituting: ["port": String(server.port)])
        case .failed(let cause):
            Strings.text(.statusFailed, language, substituting: ["reason": cause.title(language)])
        }
    }

    // MARK: - 内容区（三态）

    @ViewBuilder
    private var contentArea: some View {
        switch server.state {
        case .running, .external:
            WebView(controller: app.webController)
        case .starting:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(Strings.text(.startingTitle, language))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(Strings.text(.startingHint, language))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let cause):
            FailureView(cause: cause) { action in
                perform(action)
            }
        }
    }

    /// 执行失败态上的恢复动作。
    ///
    /// 动作是数据（`RecoveryAction`），执行留在视图层：`FailureCause` 因此保持纯粹，
    /// 分类规则可以在单测里跑而不需要 AppKit。
    private func perform(_ action: FailureCause.RecoveryAction) {
        switch action {
        case .retry:
            server.restart()
        case .viewLogs:
            app.showLogs = true
        case .exportDiagnostics:
            MenuActions.shared.exportDiagnostics()
        case .useMachineRuntime:
            // 开关立即生效：`ServerManager.launchServer()` 每次都重读这个偏好。
            MachineRuntimePreference().set(true)
            server.restart()
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .reveal(let path):
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
        }
    }
}

/// 安全模式横幅：连续启动失败后插件被停用了，用户必须一眼看到「现在的界面不完整」。
///
/// 三态之外单独一层，运行中也常驻显示：安全模式下界面看起来是正常的，只是少了插件——
/// 如果不提示，用户会以为插件坏了，转头去插件那边找问题。
struct SafeModeBanner: View {
    let disabled: [String]
    var onExit: () -> Void

    @State private var showingList = false

    private var language: AppLanguage { MenuBuilder.current }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.orange)
            Text(title)
                .font(.callout)
            if !disabled.isEmpty {
                Button(Strings.text(.safeModeViewList, language)) {
                    showingList = true
                }
                .buttonStyle(.link)
                .popover(isPresented: $showingList, arrowEdge: .bottom) {
                    DisabledPluginList(ids: disabled)
                }
            }
            Spacer()
            Button(Strings.text(.safeModeExit, language), action: onExit)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private var title: String {
        if disabled.isEmpty {
            return Strings.text(.safeModeNothingToDisable, language)
        }
        return Strings.text(.safeModeDisabledCount, language,
                            substituting: ["count": String(disabled.count)])
    }
}

/// 被停用插件的清单。列出 id 而不是只报个数：用户要凭它判断该卸载哪一个。
struct DisabledPluginList: View {
    let ids: [String]

    private var language: AppLanguage { MenuBuilder.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Strings.text(.disabledPluginsTitle, language))
                .font(.headline)
            Text(Strings.text(.disabledPluginsHint, language))
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(ids, id: \.self) { id in
                        Text(id)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// 失败态内容区：一句「是什么」、一段「为什么」、一排「怎么办」。
///
/// 单独成型而不是塞在 `ContentView` 的 switch 里：失败态是这个应用里信息最密的一屏，
/// 混在三态分支里会让每个分支都难读。
struct FailureView: View {
    let cause: FailureCause
    var onAction: (FailureCause.RecoveryAction) -> Void

    private var language: AppLanguage { MenuBuilder.current }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.red)
            Text(cause.title(language))
                .font(.title2)
                .fontWeight(.semibold)
            Text(cause.detail(language))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 520)
                .padding(.horizontal, 40)
            HStack(spacing: 12) {
                ForEach(Array(cause.actions.enumerated()), id: \.offset) { _, action in
                    Button {
                        onAction(action)
                    } label: {
                        Label(action.label(language), systemImage: action.symbol)
                    }
                    .buttonStyle(action == cause.primaryAction
                                 ? AnyButtonStyle(.borderedProminent)
                                 : AnyButtonStyle(.bordered))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 按钮样式的类型擦除。
///
/// SwiftUI 的 `buttonStyle` 泛型参数无法在三元表达式里混用两种具体样式，
/// 而失败态的按钮要按 `FailureCause.primaryAction` 逐个决定强调程度。
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { configuration in
            AnyView(Button(configuration).buttonStyle(style))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

/// 日志面板：标题栏 + 关闭按钮 + 等宽字体内容、自动滚动到底部。
/// 面板自带关闭按钮，保证头部隐藏（运行中）时日志也能收起。
struct LogView: View {
    let lines: [String]
    var onClose: () -> Void

    private var language: AppLanguage { MenuBuilder.current }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(Strings.text(.logs, language), systemImage: "terminal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(Strings.text(.collapseLogsHelp, language))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: lines.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lines.count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .frame(width: 480)
    }
}
