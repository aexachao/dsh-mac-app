import SwiftUI

/// 设置界面：界面语言切换（切换后重启应用生效）、运行时来源（逃生开关）。
struct SettingsView: View {
    @AppStorage("appLanguage") private var languageRaw = ""
    /// 与 `MachineRuntimePreference` 同一个键；这里用 `@AppStorage` 只为让界面随之刷新。
    @AppStorage("preferMachineRuntime") private var preferMachineRuntime = false
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

            Divider().padding(.vertical, 4)

            runtimeSection
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

    /// 运行时来源。
    ///
    /// 先写明内置的是哪个版本，再给开关：不写版本，「改用本机」就是一句没有对照物的
    /// 抽象选项，用户无从判断该不该打开。
    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Strings.text(.settingsRuntimeTitle, MenuBuilder.current))
                .font(.headline)

            if let summary = RuntimeLocator.bundledManifest()?.summary {
                Text(Strings.text(.settingsRuntimeBundled, MenuBuilder.current,
                                  substituting: ["runtime": summary]))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // `swift run` 的开发构建走到这里，用户看到的是事实而不是空白
                Text(Strings.text(.settingsRuntimeNoBundle, MenuBuilder.current))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle(Strings.text(.settingsPreferMachine, MenuBuilder.current),
                   isOn: preferMachineBinding)

            Text(Strings.text(.settingsPreferMachineHint, MenuBuilder.current))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 开关一动就重启服务。
    ///
    /// 不做成「下次启动生效」：用户打开它的时刻，正是当前这一份跑不起来的时刻，
    /// 让他再自己去按一次重启只是多一道他不知道要按的手续。
    private var preferMachineBinding: Binding<Bool> {
        Binding(
            get: { preferMachineRuntime },
            set: { newValue in
                preferMachineRuntime = newValue
                ServerManager.shared.restart()
            }
        )
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
