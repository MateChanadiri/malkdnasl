import SwiftUI
import UIKit

// MARK: - Brand style (startup colour + matching app icon)

enum BrandStyle: String, CaseIterable, Identifiable {
    case red, orange, green, blue, violet, black
    var id: String { rawValue }

    static let key = "brandStyle"
    static var current: BrandStyle { BrandStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .red }

    var name: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .green: "Green"
        case .blue: "Blue"
        case .violet: "Violet"
        case .black: "OLED"
        }
    }
    var color: Color {
        switch self {
        case .red: Color(hex: "#FF3B5C")
        case .orange: Color(hex: "#FF7A1A")
        case .green: Color(hex: "#18B56A")
        case .blue: Color(hex: "#2F6BFF")
        case .violet: Color(hex: "#7C4DFF")
        case .black: Color.black
        }
    }
}
