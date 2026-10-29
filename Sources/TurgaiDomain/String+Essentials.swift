// What Foundation's `NSString` gives a string and FoundationEssentials doesn't, written with the
// standard library alone, so every platform has the same. Only this package's modules see them.

extension StringProtocol {
    /// The string without the whitespace, newlines among it, at its ends.
    package func trimmed() -> String {
        trimmed(while: \.isWhitespace)
    }

    /// The string without the characters `isTrimmed` holds for at its ends.
    package func trimmed(while isTrimmed: (Character) -> Bool) -> String {
        guard let first = firstIndex(where: { !isTrimmed($0) }), let last = lastIndex(where: { !isTrimmed($0) })
        else { return "" }
        return String(self[first...last])
    }

    /// The string with each `%XX` it has read as the byte it encodes, the bytes as UTF-8; `nil`
    /// when an escape isn't two hex digits, or the bytes aren't UTF-8.
    package var percentDecoded: String? {
        var bytes: [UInt8] = []
        var rest = utf8[...]
        while let byte = rest.popFirst() {
            guard byte == UInt8(ascii: "%") else {
                bytes.append(byte)
                continue
            }
            guard let high = rest.popFirst().flatMap(Self.hexValue), let low = rest.popFirst().flatMap(Self.hexValue)
            else { return nil }
            bytes.append(high << 4 | low)
        }
        return String(validating: bytes, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

extension Sequence<UInt8> {
    /// The bytes as lowercase hex, two digits each.
    package var hexString: String {
        map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }
}
