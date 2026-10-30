import UIKit

/// Whether the system tab bar is currently minimised. The bar minimises and expands on its own schedule
/// (often well after the scroll that asked for it), so the floating pills follow the bar itself.
@MainActor
enum TabBarProbe {
    private static weak var itemPlatter: UIView?
    /// This is polled many times a second; when the bar isn't found, walking every window again each time is wasted work.
    private static var lastMiss: Date?

    /// nil when the bar can't be inspected (then the scroll direction is used instead).
    static func isMinimized() -> Bool? {
        if let v = itemPlatter, v.window != nil { return v.isHidden || v.alpha < 0.5 }
        if let miss = lastMiss, Date().timeIntervalSince(miss) < 1 { return nil }
        guard let bar = tabBar(),
              let platter = find(in: bar, where: { String(describing: type(of: $0)).contains("ItemPlatter") }) else { lastMiss = Date(); return nil }
        lastMiss = nil
        itemPlatter = platter
        return platter.isHidden || platter.alpha < 0.5
    }

    /// The expanded bar's frame on screen (window coordinates), while it is fully shown; nil otherwise.
    static func expandedFrame() -> CGRect? {
        if itemPlatter?.window == nil { _ = isMinimized() }
        guard let v = itemPlatter, v.window != nil, !v.isHidden, v.alpha > 0.99 else { return nil }
        let f = v.convert(v.bounds, to: nil)
        return f.width > 40 && f.height > 20 ? f : nil
    }

    private static func tabBar() -> UITabBar? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows { if let b = find(in: w, where: { $0 is UITabBar }) as? UITabBar { return b } }
        }
        return nil
    }

    private static func find(in v: UIView, where match: (UIView) -> Bool) -> UIView? {
        if match(v) { return v }
        for s in v.subviews { if let f = find(in: s, where: match) { return f } }
        return nil
    }
}
