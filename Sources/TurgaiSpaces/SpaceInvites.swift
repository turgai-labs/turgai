import Crypto
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What an invite's link carries, which lets one person in: no one keeps it, only its hash.
public struct SpaceInviteToken: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// The token `written`, as a link or a person gives it.
    public init(_ written: String) {
        self.rawValue = written.trimmed()
    }

    /// A new token: 32 random bytes, as letters a link can carry.
    public static func new() -> Self {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return Self(
            bytes.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: ""))
    }

    /// Its hash, as the space keeps it.
    public var hash: SpaceInviteHash {
        SpaceInviteHash(
            rawValue: SHA256.hash(data: Data(rawValue.utf8)).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }
                .joined())
    }

    public var description: String { rawValue }
}
