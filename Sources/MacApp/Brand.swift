import AppKit
import SwiftUI

/// Turgai's colors, from the web app's `turgai.css`, in light and dark pairs.
extension Color {
    static let turgaiAccent = Color(light: 0xB83B30, dark: 0xC4473C)
    static let turgaiInk = Color(light: 0x20313D, dark: 0xEEF4F3)
    static let turgaiMuted = Color(light: 0x536671, dark: 0xA0B7BF)
    static let turgaiCanvas = Color(light: 0xFFFFFF, dark: 0x09151E)
    static let turgaiAccentSoft = Color(light: 0xFFF0EC, dark: 0x4B2423)
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

/// The skylark and Turgai's name beside it, as the cards show them, smaller.
struct Wordmark: View {
    var body: some View {
        HStack(spacing: 6) {
            Image.skylark
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(Color.turgaiAccent)
            Text("Turgai")
                .font(.system(size: 20, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(Color.turgaiInk)
        }
    }
}

/// Turgai's geometry for working screens, as the web's app pages draw it: a soft accent block tilted
/// at the top right, a faint coral bar at the bottom left, a faint yellow square above it; quiet
/// enough to read over, for the glass to sit on.
struct WorkingField: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let block = CGSize(width: min(672, size.width * 0.64), height: 288)
            ZStack {
                Color.turgaiCanvas
                Rectangle()
                    .fill(Color.turgaiAccentSoft.opacity(0.62))
                    .frame(width: block.width, height: block.height)
                    .rotationEffect(.degrees(-9))
                    .position(x: size.width - block.width / 2, y: 112 + block.height / 2)
                Rectangle()
                    .fill(Color.signalYellow.opacity(0.16))
                    .frame(width: 112, height: 112)
                    .rotationEffect(.degrees(14))
                    .position(x: 56, y: 248)
                Rectangle()
                    .fill(Color.signalCoral.opacity(0.12))
                    .frame(width: 384, height: 80)
                    .rotationEffect(.degrees(7))
                    .position(x: 192, y: size.height - 152)
            }
        }
        .ignoresSafeArea()
    }
}
