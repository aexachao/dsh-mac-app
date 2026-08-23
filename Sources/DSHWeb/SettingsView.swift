import SwiftUI

/// 设置界面：界面语言切换（菜单栏文案），切换后重启应用生效。
struct SettingsView: View {
    @AppStorage("appLanguage") private var languageRaw = ""
    @State private var showRestartAlert = false
    @State private var previousLanguage: AppLanguage = .zh

    private var language: Binding<AppLanguage> {
        Binding(
            get: { MenuBuilder.current },
            set: { newValue in
                previousLanguage = MenuBuilder.current
                languageRaw = newValue.rawValue // 先写入；取消时回滚
                showRestartAlert = true
            }
        )
    }

    var body: some View {
        Form {
            Picker("界面语言", selection: language) {
                Text("简体中文").tag(AppLanguage.zh)
                Text("English").tag(AppLanguage.en)
            }
            .pickerStyle(.menu) // 下拉选择样式

            Text("当前生效：\(effectiveLabel)（切换后需重启应用生效）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 340)
        .alert("重启应用以生效？", isPresented: $showRestartAlert) {
            Button("取消", role: .cancel) { languageRaw = previousLanguage.rawValue }
            Button("立即重启") { persistAndRestart() }
        } message: {
            Text("界面语言将在重启后生效。应用会先停止服务再自动重新启动。")
        }
    }

    private var effectiveLabel: String {
        MenuBuilder.current == .zh ? "简体中文" : "English"
    }

    /// 保存偏好并重启应用（服务随应用退出而停止，重启后自动拉起）。
    /// 用独立 shell 延迟重启：`sleep 1 && open` —— 等旧进程完全退出
    /// 后再启动新实例，避免 open 对运行中实例只激活不重启的问题。
    private func persistAndRestart() {
        // 1) 同步语言到 dsh 服务（~/.dsh/settings.yaml 的 locale.preference）
        let home = NSHomeDirectory()
        MenuBuilder.writeLocalePreference(
            nodePath: MenuBuilder.resolveNodePath(home: home),
            settingsPath: home + "/.dsh/settings.yaml",
            yamlPath: home + "/.dsh/profiles/web/node_modules/yaml/dist/index.js",
            language: MenuBuilder.current
        )
        // 2) 偏好已写入 languageRaw；延迟重启应用（服务随之重启并读取新语言）
        let bundle = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1 && open \"\(bundle)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

}
