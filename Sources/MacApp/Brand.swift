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

/// How a stamp leans, as the web's do: up to 2.4° either way, the same for the same seed. A long
/// stamp leans less, so its ends lift no further apart than a short one's.
struct Lean: Equatable {
    /// How far its ends may lift apart, in points.
    private static let mostLift: CGFloat = 6

    /// Its angle, for a stamp short enough to take it whole.
    let degrees: Double

    init(degrees: Double) {
        self.degrees = degrees
    }

    /// The lean the web works out for `seed`: between −2.4° and 2.4°.
    init(seed: String) {
        let hash = seed.utf16.reduce(Int32(0)) { hash, unit in (hash &<< 5) &- hash &+ Int32(unit) }
        degrees = Double(Int(hash.magnitude % 49) - 24) / 10
    }

    /// Its angle across `width`: its own, or less, so its ends lift no more than `mostLift` apart.
    func angle(across width: CGFloat) -> Angle {
        let most = Angle.radians(asin(min(1, Self.mostLift / max(width, 1))))
        return .degrees(min(abs(degrees), most.degrees) * (degrees < 0 ? -1 : 1))
    }
}

/// Turgai's stamp, behind what it marks: a nearly square block of `color`, leaning by `lean`.
struct StampBackground: View {
    let color: Color
    let lean: Lean

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 3).fill(color).rotationEffect(lean.angle(across: geometry.size.width))
        }
    }
}

extension SpaceHue {
    /// Its signal color.
    var color: Color {
        switch self {
        case .coral: .signalCoral
        case .yellow: .signalYellow
        case .blue: .signalBlue
        }
    }

    /// Text on a stamp of it: the light theme's ink on coral and yellow, white on blue.
    var ink: Color {
        switch self {
        case .coral, .yellow: .inkOnSignal
        case .blue: .white
        }
    }
}

/// A border along the edge of a stamp leaning by `lean`: what's picked.
struct StampBorder: View {
    let lean: Lean

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.turgaiInk, lineWidth: 2)
                .rotationEffect(lean.angle(across: geometry.size.width))
        }
    }
}

/// Turgai's geometry for working screens: a block in the shown space's color, tilted into the top
/// right corner and cut off by it; a yellow square and a blue bar on the left, which the panel's
/// glass blurs into itself.
struct WorkingField: View {
    let hue: SpaceHue

    var body: some View {
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
