import Foundation

/// The product name comes from Config/Brand.xcconfig → Info.plist ("BrandName"), so renaming the app
/// is a one-line change. Every user-visible string reads it from here.
nonisolated enum Brand {
    static var name: String { info("BrandName") ?? "Music" }
    static var tagline: String { info("BrandTagline") ?? "Music in your own voice" }

    private static func info(_ key: String) -> String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !v.isEmpty, !v.hasPrefix("$(") else { return nil }
        return v
    }
}
