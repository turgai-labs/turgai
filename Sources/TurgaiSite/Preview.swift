import AVFoundation
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// The image link previews show (Telegram, Slack, iMessage, LinkedIn): a frame of the day sky with the wordmark,
/// drawn at build time so it always matches the site.
enum Preview {
    static let file = SitePath.assets + "preview.jpg"
    static let size = CGSize(width: 1200, height: 630)

    enum Failure: Error {
        case noCanvas
        case noImage
        case notWritten
    }

    static func render(sky video: URL, to output: URL) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        let (frame, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))

        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.noCanvas }

        // the sky, filling the card
        let scale = max(size.width / CGFloat(frame.width), size.height / CGFloat(frame.height))
        let drawn = CGSize(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
        context.draw(frame, in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height))

        // the wordmark, white, as the intro shows it; the label underneath
        let shadow = CGColor(srgbRed: 9 / 255, green: 21 / 255, blue: 30 / 255, alpha: 0.3)
        draw("turgai", size: 230, weight: .bold, tracking: -0.025, centreY: size.height * 0.56, shadow: shadow, in: context)
        let labelShadow = CGColor(srgbRed: 9 / 255, green: 21 / 255, blue: 30 / 255, alpha: 0.55)
        draw("AGENT HARNESS BUILT ON OBJECTS", size: 30, weight: .semibold, tracking: 0.14, centreY: size.height * 0.335, shadow: labelShadow, in: context)

        guard let image = context.makeImage() else { throw Failure.noImage }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.notWritten
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.notWritten }
    }

    /// One line of white text, centred horizontally, its middle at `centreY` (measured from the bottom, as CoreGraphics does).
    private static func draw(_ text: String, size points: CGFloat, weight: NSFont.Weight, tracking: CGFloat, centreY: CGFloat, shadow: CGColor, in context: CGContext) {
        let font = NSFont.systemFont(ofSize: points, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: tracking * points,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 30, color: shadow)
        context.textPosition = CGPoint(x: (size.width - bounds.width) / 2 - bounds.minX, y: centreY - bounds.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
