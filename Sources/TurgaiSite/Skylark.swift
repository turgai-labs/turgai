import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The brand's skylark as a shape the page can fill with points.
struct Skylark {
    enum Failure: Error {
        case missingPath
        case unsupportedCommand(Character)
        case missingCoordinates(Character)
        case iconRendering
    }

    /// The mark's path data, for drawing it inline.
    let pathData: String
    private let shape: CGPath

    /// Rasterize the existing mark on an opaque white background for browsers and iOS home screens.
    func writeIcon(size: Int, to output: URL) throws {
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.iconRendering }
        let side = CGFloat(size)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // SVG's y axis runs downwards. Keep a margin so home-screen masks cannot clip the bird.
        context.translateBy(x: side * 0.1, y: side * 0.9)
        context.scaleBy(x: side * 0.8 / 1024, y: -side * 0.8 / 1024)
        context.setFillColor(CGColor(srgbRed: 7 / 255, green: 7 / 255, blue: 7 / 255, alpha: 1))
        context.addPath(shape)
        context.drawPath(using: .eoFill)
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.iconRendering }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.iconRendering }
    }

    /// Reads the first `d` attribute of the brand SVG. The mark uses absolute `M`, `L`, `C` and `Z`.
    init(svg: String) throws {
        guard let start = svg.range(of: " d=\""),
            let end = svg[start.upperBound...].firstIndex(of: "\"")
        else { throw Failure.missingPath }
        pathData = String(svg[start.upperBound..<end])
        shape = try Self.path(pathData)
    }

    /// Points inside the mark on a hexagonal grid, in 0...1, the first grid that yields at least `count`.
    func points(atLeast count: Int) -> [Point] {
        var points: [Point] = []
        for step in stride(from: 40.0, through: 12, by: -2) {
            points = grid(step: step).filter { shape.contains(CGPoint(x: $0.x, y: $0.y), using: .evenOdd) }
                .map { Point(x: $0.x / 1024, y: $0.y / 1024) }
            if points.count >= count { break }
        }
        return points
    }

    private func grid(step: Double) -> [Point] {
        var points: [Point] = []
        for (row, y) in stride(from: step / 2, to: 1024, by: step * 0.866).enumerated() {
            let first = (row.isMultiple(of: 2) ? 0 : step / 2) + step / 4
            for x in stride(from: first, to: 1024, by: step) {
                points.append(Point(x: x, y: y))
            }
        }
        return points
    }

    private static func path(_ d: String) throws -> CGPath {
        let path = CGMutablePath()
        for (command, numbers) in try commands(d) {
            switch (command, numbers.count) {
            case ("M", 2): path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
            case ("L", 2): path.addLine(to: CGPoint(x: numbers[0], y: numbers[1]))
            case ("C", 6):
                path.addCurve(
                    to: CGPoint(x: numbers[4], y: numbers[5]),
                    control1: CGPoint(x: numbers[0], y: numbers[1]),
                    control2: CGPoint(x: numbers[2], y: numbers[3])
                )
            case ("Z", 0): path.closeSubpath()
            case ("M", _), ("L", _), ("C", _), ("Z", _): throw Failure.missingCoordinates(command)
            default: throw Failure.unsupportedCommand(command)
            }
        }
        return path
    }

    /// Splits path data into commands with their numbers; an implicit repeat of `C` or `L` becomes its own command.
    private static func commands(_ d: String) throws -> [(Character, [Double])] {
        var result: [(Character, [Double])] = []
        var command: Character?
        var numbers: [Double] = []
        var token = ""
        func flushNumber() {
            if let value = Double(token) { numbers.append(value) }
            token = ""
        }
        func flushCommand() {
            guard let current = command else { return }
            let arity = ["M": 2, "L": 2, "C": 6, "Z": 0][current] ?? numbers.count
            if arity == 0 || numbers.isEmpty {
                result.append((current, numbers))
            } else {
                for chunk in stride(from: 0, to: numbers.count, by: arity) {
                    result.append((current, Array(numbers[chunk..<min(chunk + arity, numbers.count)])))
                }
            }
            numbers = []
        }
        for character in d {
            if character.isLetter && character != "e" {
                flushNumber()
                flushCommand()
                command = character
            } else if character == " " || character == "," {
                flushNumber()
            } else if character == "-" && !token.isEmpty && token.last != "e" {
                flushNumber()
                token = "-"
            } else {
                token.append(character)
            }
        }
        flushNumber()
        flushCommand()
        return result
    }
}
