import AppKit

// AppKit 手动入口：完全掌控菜单栏与窗口生命周期。
// 不使用 SwiftUI App 协议 —— SwiftUI 会持续重建默认菜单并覆盖
// 我们的自定义菜单（中英文切换无法稳定生效）。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
