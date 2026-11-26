import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Turgai's colors, from the web app's `turgai.css`, in light and dark pairs.
extension Color {
    package static let turgaiAccent = Color(light: 0xB83B30, dark: 0xC4473C)
    package static let turgaiInk = Color(light: 0x20313D, dark: 0xEEF4F3)
    package static let turgaiMuted = Color(light: 0x536671, dark: 0xA0B7BF)
    package static let turgaiCanvas = Color(light: 0xFFFFFF, dark: 0x09151E)
    package static let signalCoral = Color(light: 0xEF5B4D, dark: 0xFF8175)
    package static let signalYellow = Color(light: 0xF4C542, dark: 0xF7D66B)
    package static let signalBlue = Color(light: 0x2864E8, dark: 0x79A7FF)
    /// Each signal's deep shade, for its lines and text on the surface: dark enough to read in the
    /// light theme, the signal itself in the dark one.
    package static let signalCoralDeep = Color(light: 0xB8402F, dark: 0xFF8175)
    package static let signalYellowDeep = Color(light: 0x8C6A00, dark: 0xF7D66B)
    package static let signalBlueDeep = Color(light: 0x1747AD, dark: 0x79A7FF)

    /// A message's background, as the web's: its signal color, 78% of it over the surface.
    package static let bubbleYours = Color(light: 0xF6D26C, dark: 0xC4AF5E)
    package static let bubbleAgent = Color(light: 0x5786ED, dark: 0x628AD2)
    package static let bubbleSomeoneElse = Color(light: 0xF37F74, dark: 0xCB6D66)
    /// Text on yellow and coral: the light theme's ink in both, which the dark one's isn't readable on.
    package static let inkOnSignal = Color(light: 0x20313D, dark: 0x20313D)

    package init(light: UInt32, dark: UInt32) {
        #if os(macOS)
            self.init(
                nsColor: NSColor(name: nil) { appearance in
                    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    return NSColor(
                        srgbRed: Self.red(isDark ? dark : light), green: Self.green(isDark ? dark : light),
                        blue: Self.blue(isDark ? dark : light), alpha: 1)
                })
        #else
            self.init(
                uiColor: UIColor { traits in
                    let hex = traits.userInterfaceStyle == .dark ? dark : light
                    return UIColor(red: Self.red(hex), green: Self.green(hex), blue: Self.blue(hex), alpha: 1)
                })
        #endif
    }

    private static func red(_ hex: UInt32) -> CGFloat { CGFloat((hex >> 16) & 0xFF) / 255 }
    private static func green(_ hex: UInt32) -> CGFloat { CGFloat((hex >> 8) & 0xFF) / 255 }
    private static func blue(_ hex: UInt32) -> CGFloat { CGFloat(hex & 0xFF) / 255 }
}

extension Image {
    /// The skylark, Turgai's mark: a template image, tinted by its foreground style.
    package static let skylark = Image("Skylark", bundle: .module)
}

#if os(macOS)
    extension NSImage {
        /// The skylark, as AppKit draws it, such as in the menu bar.
        package static var skylark: NSImage { Bundle.module.image(forResource: "Skylark") ?? NSImage() }
    }
#endif

/// How a stamp leans, as the web's do: up to 2.4° either way, the same for the same seed. A long
/// stamp leans less, so its ends lift no further apart than a short one's.
package struct Lean: Equatable {
    /// How far its ends may lift apart, in points.
    private static let mostLift: CGFloat = 6

    /// Its angle, for a stamp short enough to take it whole.
    package let degrees: Double

    package init(degrees: Double) {
        self.degrees = degrees
    }

    /// The lean the web works out for `seed`: between −2.4° and 2.4°.
    package init(seed: String) {
        let hash = seed.utf16.reduce(Int32(0)) { hash, unit in (hash &<< 5) &- hash &+ Int32(unit) }
        degrees = Double(Int(hash.magnitude % 49) - 24) / 10
    }

    /// Its angle across `width`: its own, or less, so its ends lift no more than `mostLift` apart.
    package func angle(across width: CGFloat) -> Angle {
        let most = Angle.radians(asin(min(1, Self.mostLift / max(width, 1))))
        return .degrees(min(abs(degrees), most.degrees) * (degrees < 0 ? -1 : 1))
    }
}

/// Turgai's stamp, behind what it marks: a nearly square block of `color`, leaning by `lean`.
package struct StampBackground: View {
    package let color: Color
    package let lean: Lean

    package init(color: Color, lean: Lean) {
        self.color = color
        self.lean = lean
    }

    package var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 3).fill(color).rotationEffect(lean.angle(across: geometry.size.width))
        }
    }
}

extension SpaceHue {
    /// Its signal color.
    package var color: Color {
        switch self {
        case .coral: .signalCoral
        case .yellow: .signalYellow
        case .blue: .signalBlue
        }
    }

    /// Its lines and text on the surface: its deep shade.
    package var deep: Color {
        switch self {
        case .coral: .signalCoralDeep
        case .yellow: .signalYellowDeep
        case .blue: .signalBlueDeep
        }
    }

    /// Text on a stamp of it: the light theme's ink on coral and yellow, white on blue.
    package var ink: Color {
        switch self {
        case .coral, .yellow: .inkOnSignal
        case .blue: .white
        }
    }
}

/// A stamp's outline, leaning by `lean`, in `color`: a stamp not filled in.
package struct StampOutline: View {
    package let color: Color
    package let lean: Lean

    package init(color: Color, lean: Lean) {
        self.color = color
        self.lean = lean
    }

    package var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(color, lineWidth: 1.5)
                .rotationEffect(lean.angle(across: geometry.size.width))
        }
    }
}

/// Turgai's geometry for working screens: a block in the shown space's color, tilted into the top
/// right corner and cut off by it; a yellow square and a blue bar on the left, which the panel's
/// glass blurs into itself.
package struct WorkingField: View {
    package let hue: SpaceHue

    package init(hue: SpaceHue) {
        self.hue = hue
    }

    package var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color.turgaiCanvas
                Rectangle()
                    .fill(hue.color)
                    .frame(width: 320, height: 150)
                    .rotationEffect(.degrees(-9))
                    .position(x: size.width - 60, y: 24)
                Rectangle()
                    .fill(Color.signalYellow.opacity(0.55))
                    .frame(width: 112, height: 112)
                    .rotationEffect(.degrees(14))
                    .position(x: 56, y: 248)
                Rectangle()
                    .fill(Color.signalBlue.opacity(0.22))
                    .frame(width: 280, height: 80)
                    .rotationEffect(.degrees(7))
                    .position(x: 140, y: size.height - 152)
            }
            .animation(.easeInOut(duration: 0.3), value: hue)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// A form laid out in columns, labels beside their fields, where there's room for it: on a
    /// phone, grouped.
    package func columnsFormStyle() -> some View {
        #if os(macOS)
            formStyle(.columns)
        #else
            formStyle(.grouped)
        #endif
    }
}

extension View {
    /// A field for what's typed exactly as it's meant: a username, an address, a model's name, an
    /// id. Nothing in it is corrected, nor, on a phone, capitalized.
    package func typedVerbatim() -> some View {
        #if os(iOS)
            textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
            autocorrectionDisabled()
        #endif
    }
}
