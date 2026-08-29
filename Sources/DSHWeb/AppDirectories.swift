import Foundation

/// 应用自己的目录。
///
/// 单独一层是为了避免第二处 `Library/Application Support/Harness` 拼接——路径散在
/// 两个文件里，改一处漏一处就会写到两个不同的地方去。
enum AppDirectories {

    /// `~/Library/Application Support/Harness`：应用自己写的所有状态都在这里。
    ///
    /// 与 `~/.dsh` 的界限是硬的：那是用户和其它 dsh 版本共享的配置，应用只读不写。
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Harness")
    }
}
