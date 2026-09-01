import AppKit

/// 顶部横带（红绿灯所在那一段）的两段颜色与分界位置，由网页实测后报上来。
///
/// dsh 的界面是分栏的（侧栏一种底色、会话区另一种），横带横跨两栏，
/// 所以画成「左段侧栏色、右段会话区色」，分界取侧栏的右边界。
///
/// 值语义 + 纯解析：颜色是从网页异步到的不可信数据，判空、判范围这些事
/// 应当在一个不需要 AppKit 就能测的地方做完。
struct TopBandColors: Equatable {
    /// sRGB 分量（0–255）。存数值而不是 `NSColor`：便于比较（`onChange` 要它 Equatable）、
    /// 也便于单测。
    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        var nsColor: NSColor {
            NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
        }
    }

    let left: RGB
    let right: RGB
    /// 左右分界的 x（点，横带自身坐标）。
    let split: CGFloat

    /// 解析页面报上来的载荷。任何一处不成形都返回 nil —— 横带于是留在窗口底色上，
    /// 跟没有这条横带之前一模一样（纯观感回退），而不是照一个乱数画出错的颜色。
    static func parse(_ body: Any) -> TopBandColors? {
        guard let payload = body as? [String: Any],
              let left = rgb(payload["left"]),
              let right = rgb(payload["right"]),
              let split = (payload["split"] as? NSNumber)?.doubleValue,
              split.isFinite, split >= 0
        else { return nil }
        return TopBandColors(left: left, right: right, split: CGFloat(split))
    }

    private static func rgb(_ value: Any?) -> RGB? {
        guard let channels = value as? [NSNumber], channels.count == 3 else { return nil }
        let values = channels.map(\.doubleValue)
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 255 }) else { return nil }
        return RGB(red: values[0], green: values[1], blue: values[2])
    }
}
