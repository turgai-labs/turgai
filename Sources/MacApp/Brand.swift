import AppKit
import SwiftUI

/// Turgai's colors, from the web app's `turgai.css`, in light and dark pairs.
extension Color {
    static let turgaiAccent = Color(light: 0xB83B30, dark: 0xC4473C)
    static let turgaiInk = Color(light: 0x20313D, dark: 0xEEF4F3)
    static let turgaiMuted = Color(light: 0x536671, dark: 0xA0B7BF)
    static let turgaiCanvas = Color(light: 0xFFFFFF, dark: 0x09151E)
    static let signalCoral = Color(light: 0xEF5B4D, dark: 0xFF8175)
    static let signalYellow = Color(light: 0xF4C542, dark: 0xF7D66B)
    static let signalBlue = Color(light: 0x2864E8, dark: 0x79A7FF)

    init(light: UInt32, dark: UInt32) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
    }
}

extension NSColor {
    fileprivate convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Image {
    /// The skylark, Turgai's mark: a template image, tinted by its foreground style.
    static let skylark = Image("Skylark", bundle: .module)
}
