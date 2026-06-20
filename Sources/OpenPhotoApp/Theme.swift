import SwiftUI

/// Design tokens — UI-Design/design_handoff_openphoto/README.md. Do not improvise.
enum Theme {
    static let accent = Color(hex: 0xCF5C57)          // warm coral-red
    static let accentHi = Color(hex: 0xD87B76)
    static var accentDim: Color { accent.opacity(0.16) }

    static let windowBG = Color(light: 0xF7F5F2, dark: 0x1B1917)
    static let bg2 = Color(light: 0xF1EEEA, dark: 0x211F1C)
    static let elevated = Color(light: 0xFFFFFF, dark: 0x2A2724)
    static let text = Color(light: 0x211E1B, dark: 0xECE9E4)
    static let textDim = Color(light: 0x6C6862, dark: 0xA39E97)
    static let textFaint = Color(light: 0x9A958D, dark: 0x726D66)
    static let tile = Color(light: 0xE7E3DD, dark: 0x2C2926)
    static let green = Color(light: 0x3F9D5F, dark: 0x5FB47A)
    static let red = Color(light: 0xC0463E, dark: 0xD86A62)
    static let amber = Color(light: 0xB9852A, dark: 0xD8A23E)
    static let blue = Color(light: 0x3F7FBF, dark: 0x6AA3D8)
    static var hairline: Color { Color.primary.opacity(0.09) }

    static let sidebarWidth: CGFloat = 248
    static let folderTreeWidth: CGFloat = 250
    static let inspectorWidth: CGFloat = 332
    static let toolbarHeight: CGFloat = 52
    static let gridGap: CGFloat = 3
    static let cellRadius: CGFloat = 3
    static let cardRadius: CGFloat = 13

    /// Stable, well-spread hues for coloring people on the Face Map (light/dark pairs).
    static let personColors: [(light: UInt32, dark: UInt32)] = [
        (0xCF5C57, 0xE07B76), (0x3F7FBF, 0x6AA3D8), (0x3F9D5F, 0x5FB47A), (0xB9852A, 0xD8A23E),
        (0x8E5BC4, 0xA985D8), (0x2FA39A, 0x4FC4BA), (0xC0463E, 0xD86A62), (0x5F7E2A, 0x86A84E),
        (0xB5547F, 0xD07AA0), (0x4A6FA5, 0x7196C4), (0xA86A33, 0xC78E55), (0x5B8C5A, 0x82B081),
    ]
    /// Deterministic color for a person id; unassigned faces use `personColorUnassigned`.
    static func colorForPerson(_ id: Int64) -> Color {
        let (l, d) = personColors[Int(UInt64(bitPattern: id) % UInt64(personColors.count))]
        return Color(light: l, dark: d)
    }
    static var personColorUnassigned: Color { Color(light: 0xB0AAA1, dark: 0x6E6862) }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
    /// Dynamic light/dark color.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
