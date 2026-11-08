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

    /// A message's background, as the web's: its signal color, 78% of it over the surface.
    static let bubbleYours = Color(light: 0xF6D26C, dark: 0xC4AF5E)
    static let bubbleAgent = Color(light: 0x5786ED, dark: 0x628AD2)
    static let bubbleSomeoneElse = Color(light: 0xF37F74, dark: 0xCB6D66)
    /// Text on yellow and coral: the light theme's ink in both, which the dark one's isn't readable on.
    static let inkOnSignal = Color(light: 0x20313D, dark: 0x20313D)

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

/// Turgai's geometry for working screens: a coral block tilted into the top right corner and a
/// yellow square at the right edge, low down, each mostly past the window's edge. They sit at the
/// edges, out of the reading path and out from under the panel on the left, and cut off as no
/// message ever is, so they're never read as one.
struct WorkingField: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color.turgaiCanvas
                Rectangle()
                    .fill(Color.signalCoral.opacity(0.28))
                    .frame(width: 360, height: 170)
                    .rotationEffect(.degrees(-9))
                    .position(x: size.width - 70, y: 30)
                Rectangle()
                    .fill(Color.signalYellow.opacity(0.55))
                    .frame(width: 96, height: 96)
                    .rotationEffect(.degrees(14))
                    .position(x: size.width - 14, y: size.height - 200)
            }
        }
        .ignoresSafeArea()
    }
}
