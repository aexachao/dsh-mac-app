import SwiftUI

/// 主界面：正常运行时为纯 WebView（无任何遮挡）；
/// 仅在启动中/失败时显示状态栏；日志侧栏可在菜单中随时开关。
struct ContentView: View {
    @State private var server = ServerManager.shared
    @State private var app = AppState.shared

    var body: some View {
        VStack(spacing: 0) {
            if needsHeader {
                header
                Divider()
            }
            HStack(spacing: 0) {
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
        })
        .onAppear {
            server.start()
            app.webController.beginUserActivity()
            // 兜底：初始状态即就绪（.external/.running）时 onChange 不会触发，这里补一次
            loadIfReady()
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
                Label(app.showLogs ? "隐藏日志" : "日志", systemImage: "terminal")
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
        case .starting: "正在启动服务…"
        case .running: "服务运行中 · 127.0.0.1:\(server.port)"
        case .external: "已在运行（外部实例）· 127.0.0.1:\(server.port)"
        case .failed(let message): "启动失败：\(message)"
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
                Text("正在启动 Harness 服务…")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("首次启动可能需要下载依赖，可通过菜单「Harness → 日志」查看进度。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.red)
                Text("服务启动失败")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                HStack(spacing: 12) {
                    Button("查看日志") { app.showLogs = true }
                        .buttonStyle(.bordered)
                    Button("重试") { server.restart() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 日志面板：标题栏 + 关闭按钮 + 等宽字体内容、自动滚动到底部。
/// 面板自带关闭按钮，保证头部隐藏（运行中）时日志也能收起。
struct LogView: View {
    let lines: [String]
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("日志", systemImage: "terminal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("收起日志 (⌘⇧L)")
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
