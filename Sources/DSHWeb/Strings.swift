import Foundation

/// 一条文案的两种语言。
///
/// 不用 `.strings` 资源：这个应用的语言由自己的 `appLanguage` 偏好决定，而不是跟随系统
/// 语言，`NSLocalizedString` 那套要靠切换 bundle 才能做到同样的事，得不偿失。
struct LocalizedText: Equatable, Sendable {
    let zh: String
    let en: String

    func value(_ language: AppLanguage) -> String {
        switch language {
        case .zh: zh
        case .en: en
        }
    }
}

/// 界面文案表。
///
/// 集中成一张表的理由很具体：文案散在各视图里写成 `language == .zh ? "…" : "…"` 时，
/// 新加一处只写中文不会有任何报错，英文界面上就出现一块空白或一句中文。这里 `Key`
/// 是 `CaseIterable`、`localized` 是穷尽 `switch`，于是「少写一种语言」编译不过，
/// 「英文位抄了中文」「两种语言占位符不一致」由 `StringsTests` 遍历全部 key 拦下。
///
/// 边界：只收界面上看得见的文案。日志行（`ServerManager`）故意保持单语——日志会被
/// 原样贴进 issue，和 dsh 自己的英文输出并排出现，两种语言混写反而不好 grep 与比对。
/// 失败原因（`FailureCause`）与菜单树（`MenuBuilder`）各自已是完整的双语表，按自己的
/// 领域类型索引，搬过来只是改动风险而没有任何用户可见收益。
enum Strings {

    /// 文案键。
    ///
    /// 按界面区域分组排列，与视图里出现的顺序一致，改文案时好找。
    enum Key: CaseIterable {
        // 顶部状态栏
        case logs
        case hideLogs
        case statusStarting
        case statusRunning
        case statusExternal
        case statusFailed

        // 启动中内容区
        case startingTitle
        case startingHint

        // 日志面板
        case collapseLogsHelp

        // 安全模式
        case safeModeDisabledCount
        case safeModeNothingToDisable
        case safeModeViewList
        case safeModeExit
        case disabledPluginsTitle
        case disabledPluginsHint

        // 设置
        case settingsTitle
        case settingsLanguage
        case settingsEffective
        case restartAlertTitle
        case restartAlertMessage
        case cancel
        case restartNow

        // 单实例
        case instanceRunningTitle
        case instanceRunningDetail
        case instanceRunningHolder
        case ok
    }

    /// 取一条文案的两种语言。
    ///
    /// 穷尽 `switch` 而不是字典：新增 `Key` 忘了给文案时是编译错误，而不是运行时
    /// 才发现取不到值。
    static func localized(_ key: Key) -> LocalizedText {
        switch key {
        case .logs:
            LocalizedText(zh: "日志", en: "Logs")
        case .hideLogs:
            LocalizedText(zh: "隐藏日志", en: "Hide Logs")
        case .statusStarting:
            LocalizedText(zh: "正在启动服务…", en: "Starting the service…")
        case .statusRunning:
            LocalizedText(zh: "服务运行中 · 127.0.0.1:{port}",
                          en: "Service running · 127.0.0.1:{port}")
        case .statusExternal:
            LocalizedText(zh: "已在运行（外部实例）· 127.0.0.1:{port}",
                          en: "Already running (external instance) · 127.0.0.1:{port}")
        case .statusFailed:
            LocalizedText(zh: "启动失败：{reason}", en: "Startup failed: {reason}")

        case .startingTitle:
            LocalizedText(zh: "正在启动 Harness 服务…", en: "Starting the Harness service…")
        case .startingHint:
            LocalizedText(zh: "首次启动可能需要下载依赖，可通过菜单「Harness → 日志」查看进度。",
                          en: "The first launch may need to download dependencies. "
                            + "Track progress under Harness → Logs.")

        case .collapseLogsHelp:
            LocalizedText(zh: "收起日志 (⌘⇧L)", en: "Hide logs (⌘⇧L)")

        case .safeModeDisabledCount:
            LocalizedText(zh: "安全模式：已临时停用 {count} 个第三方插件",
                          en: "Safe mode: {count} third-party plugin(s) temporarily disabled")
        case .safeModeNothingToDisable:
            LocalizedText(zh: "安全模式：未发现可停用的第三方插件",
                          en: "Safe mode: no third-party plugins found to disable")
        case .safeModeViewList:
            LocalizedText(zh: "查看清单", en: "View List")
        case .safeModeExit:
            LocalizedText(zh: "退出安全模式", en: "Exit Safe Mode")
        case .disabledPluginsTitle:
            LocalizedText(zh: "本次停用的插件", en: "Disabled in this session")
        case .disabledPluginsHint:
            LocalizedText(zh: "退出安全模式后它们会重新启用。",
                          en: "They are re-enabled when you exit safe mode.")

        case .settingsTitle:
            LocalizedText(zh: "设置", en: "Settings")
        case .settingsLanguage:
            LocalizedText(zh: "界面语言", en: "Interface Language")
        case .settingsEffective:
            LocalizedText(zh: "当前生效：{language}（切换后需重启应用生效）",
                          en: "In effect: {language} (switching takes effect after a restart)")
        case .restartAlertTitle:
            LocalizedText(zh: "重启应用以生效？", en: "Restart to apply?")
        case .restartAlertMessage:
            LocalizedText(zh: "界面语言将在重启后生效。应用会先停止服务再自动重新启动。",
                          en: "The interface language applies after a restart. "
                            + "The app stops the service, then relaunches itself.")
        case .cancel:
            LocalizedText(zh: "取消", en: "Cancel")
        case .restartNow:
            LocalizedText(zh: "立即重启", en: "Restart Now")

        case .instanceRunningTitle:
            LocalizedText(zh: "Harness 已在运行", en: "Harness is already running")
        case .instanceRunningDetail:
            LocalizedText(zh: "已有一个 Harness 实例{holder}持有单实例锁，但无法切换到它的窗口。"
                            + "请先退出那个实例，再重新打开。",
                          en: "Another Harness instance{holder} holds the single-instance lock, "
                            + "but its window could not be brought forward. "
                            + "Quit that instance first, then reopen.")
        case .instanceRunningHolder:
            LocalizedText(zh: "（进程 {pid}）", en: " (process {pid})")
        case .ok:
            LocalizedText(zh: "好", en: "OK")
        }
    }

    /// 取一条文案并填入占位符。
    ///
    /// 用 `{name}` 命名占位符而不是 `String(format:)` 的 `%@`/`%d`：格式符与参数类型
    /// 对不上会直接崩，而漏填一个命名占位符只是让 `{port}` 原样留在屏幕上——一眼就
    /// 能发现并修掉，代价也只是一次难看的显示。
    static func text(
        _ key: Key,
        _ language: AppLanguage,
        substituting values: [String: String] = [:]
    ) -> String {
        var result = localized(key).value(language)
        for (name, value) in values {
            result = result.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return result
    }
}
