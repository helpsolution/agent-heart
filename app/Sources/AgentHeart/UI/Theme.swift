import SwiftUI

/// Палитра один в один с dashboard.html — приложение должно выглядеть как
/// тот же продукт, а не как его двойник.
enum Theme {
    static let bg       = Color(hex: 0x0F1115)
    static let panel    = Color(hex: 0x171A21)
    static let line     = Color(hex: 0x1E222B)
    static let line2    = Color(hex: 0x232833)
    static let text     = Color(hex: 0xE6E8EB)
    static let muted    = Color(hex: 0x8B94A3)
    static let muted2   = Color(hex: 0x7B8494)
    static let accent   = Color(hex: 0x2B6CB0)
    static let accent2  = Color(hex: 0x8FB3E0)
    static let rowHover = Color(hex: 0x151922)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Форматирование как в анализаторе: 1.83B / 146.2M / 12.4K.
enum Fmt {
    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        if v >= 1e9 { return String(format: "%.2fB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.2fM", v / 1e6) }
        if v >= 1e3 { return String(format: "%.2fK", v / 1e3) }
        return "\(n)"
    }

    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f
    }()

    static func count(_ n: Int) -> String {
        grouped.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func money(_ v: Double, decimals: Int = 2) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        return "$" + (f.string(from: NSNumber(value: v)) ?? String(format: "%.\(decimals)f", v))
    }
}
