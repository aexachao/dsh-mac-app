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
            Picker(Strings.text(.settingsLanguage, MenuBuilder.current), selection: language) {
                // 语言名各自用自己的语言写，不随界面语言变化（惯例：菜单里永远能认出母语那一项）
                Text("简体中文").tag(AppLanguage.zh)
                Text("English").tag(AppLanguage.en)
            }
            .pickerStyle(.menu) // 下拉选择样式

            Text(Strings.text(.settingsEffective, MenuBuilder.current,
                              substituting: ["language": effectiveLabel]))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 340)
        .alert(Strings.text(.restartAlertTitle, MenuBuilder.current), isPresented: $showRestartAlert) {
            Button(Strings.text(.cancel, MenuBuilder.current), role: .cancel) {
                languageRaw = previousLanguage.rawValue
            }
            Button(Strings.text(.restartNow, MenuBuilder.current)) { persistAndRestart() }
        } message: {
            Text(Strings.text(.restartAlertMessage, MenuBuilder.current))
        }
    }

    private var effectiveLabel: String {
        MenuBuilder.current == .zh ? "简体中文" : "English"
    }

    /// 保存偏好并重启应用（服务随应用退出而停止，重启后自动拉起）。
    /// 重启细节见 `AppRelaunch`：必须等旧进程真正退出，否则会撞上单实例锁。
    private func persistAndRestart() {
        // 1) 同步语言到 dsh 服务（~/.dsh/settings.yaml 的 locale.preference）
        let home = NSHomeDirectory()
        MenuBuilder.writeLocalePreference(
            nodePath: MenuBuilder.resolveNodePath(home: home),
            settingsPath: home + "/.dsh/settings.yaml",
            yamlPath: home + "/.dsh/profiles/web/node_modules/yaml/dist/index.js",
            language: MenuBuilder.current
        )
        // 2) 偏好已写入 languageRaw；重启应用（服务随之重启并读取新语言）
        AppRelaunch.restart()
    }

}
