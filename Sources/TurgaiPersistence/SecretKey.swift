import Crypto

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum SecretKeyError: Error, Equatable, Sendable, CustomStringConvertible {
    /// What was given isn't a key: 32 bytes, or those bytes written as base64.
    case notAKey
    /// A sealed secret that doesn't open with this key, as the place it's said to be from.
    case unopenable
    /// The key isn't the one Turgai's database keeps its secrets sealed with.
    case notTheDatabasesKey

    public var description: String {
        switch self {
        case .notAKey: "The secret key isn't 32 bytes written as base64, such as `openssl rand -base64 32` makes."
        case .unopenable: "A kept secret doesn't open with this secret key: it was sealed with another one."
        case .notTheDatabasesKey:
            """
            This secret key isn't the one Turgai's secrets are sealed with. Give Turgai that key, or start \
            over with this one: `turgai forget-secrets` clears every sealed secret, so tokens and API keys \
            are entered again, and everyone signs in again.
            """
        }
    }
}

/// Where a sealed secret is kept, which it's sealed as: it opens only as the place it was sealed
/// for, so one moved to another place doesn't open there.
public struct SecretPlace: Sendable {
    let rawValue: String

    /// The secret kept for `key` in `table`.
    public init(_ table: String, _ key: String) {
        self.rawValue = "\(table):\(key)"
    }
}

/// Turgai's one key, which the platform holds and Turgai's database never does: every secret
/// Turgai keeps is sealed with it.
public struct SecretKey: Sendable {
    /// How many bytes a key is.
    public static let byteCount = 32

    private let key: SymmetricKey

    /// The key that is `bytes`.
    public init(bytes: Data) throws(SecretKeyError) {
        guard bytes.count == Self.byteCount else { throw .notAKey }
        self.key = SymmetricKey(data: bytes)
    }

    /// The key written as base64, as the environment and a systemd credential hold it.
    public init(base64: String) throws(SecretKeyError) {
        guard let bytes = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw .notAKey
        }
        try self.init(bytes: bytes)
    }

    /// New random bytes for a key, for a platform to hold.
    public static func newBytes() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// `secret`, sealed for `place`.
    public func seal(_ secret: String, for place: SecretPlace) throws -> Data {
        let box = try AES.GCM.seal(Data(secret.utf8), using: key, authenticating: Data(place.rawValue.utf8))
        // A box sealed with the default nonce always has its combined form.
        guard let combined = box.combined else { throw SecretKeyError.unopenable }
        return combined
    }

    /// The secret `sealed` for `place`: refused when it wasn't sealed for it, or with this key.
    public func open(_ sealed: Data, for place: SecretPlace) throws(SecretKeyError) -> String {
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            let opened = try AES.GCM.open(box, using: key, authenticating: Data(place.rawValue.utf8))
            return String(decoding: opened, as: UTF8.self)
        } catch {
            throw .unopenable
        }
    }
}
