import SwiftUI

// What the app and the widget extension share: the WreckBox colours and type.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

enum Y2K {
    static let peach = Color(hex: 0xEFAF86)
    static let lilac = Color(hex: 0xBB96DA)
    static let blue = Color(hex: 0xA9C8F0)
    static let smartColors = [blue, peach, lilac]
    static let smart = LinearGradient(colors: smartColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    static let text = Color.white.opacity(0.94)
    static let text2 = Color.white.opacity(0.66)
    static let text3 = Color.white.opacity(0.46)
    static let drawerColor = Color(hex: 0x131218)

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Urbanist", size: size).weight(weight) }
    static func dot(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .custom("Doto", size: size).weight(weight) }

    /// The dot displays: lilac → light blue → peach by height.
    static func dotColor(_ h: Double) -> Color {
        let stops: [(Double, Double, Double)] = [(0.733, 0.588, 0.855), (0.663, 0.784, 0.941), (0.937, 0.686, 0.525)]
        let (a, b, t) = h < 0.5 ? (stops[0], stops[1], h * 2) : (stops[1], stops[2], (h - 0.5) * 2)
        return Color(red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t)
    }
}

/// The Y2K widget's point grid — the same numbers as the Android widget (wb_widget.xml / PlayerWidget.Geo).
enum Geo {
    static let width: CGFloat = 400
    static let G: CGFloat = 14
    static let bodyH: CGFloat = 204
    static let dial: CGFloat = 124
    static let top: CGFloat = 44
    static let lcdH: CGFloat = 104
    static let seekT: CGFloat = 158
    static let seekH: CGFloat = 6
    static let tabGap: CGFloat = 6
    static let drawerH: CGFloat = 176
    static let dialEnd: CGFloat = 22
    static let lcdRight: CGFloat = 170
    static let slabT: CGFloat = 36
    static let slabB: CGFloat = 178
    static let podR: CGFloat = 80
    static var lcdW: CGFloat { width - lcdRight - G }
    static var dialCY: CGFloat { top + dial / 2 }
    static var dialCX: CGFloat { width - dialEnd - dial / 2 }
    static let tabs: [CGFloat] = [88, 76, 84]
    static var tabsEnd: CGFloat { G + tabs.reduce(0, +) + 2 * tabGap }
    /// The small widget's design square.
    static let mini: CGFloat = 170
}
