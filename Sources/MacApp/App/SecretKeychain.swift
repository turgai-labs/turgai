import Foundation
import Security
import TurgaiClient
import TurgaiPersistence

/// Why the Keychain didn't give Turgai its key.
struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus

    var description: String {
        "The Keychain refused Turgai's key: \(SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)")"
    }
}

/// Turgai's key on this Mac: kept in the Keychain, only on this device, made the first time it's
/// asked for.
enum SecretKeychain {
    private static let service = "Turgai"
    private static let account = "secret-key"

    static func secretKey() throws -> SecretKey {
        var item: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ]
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let bytes = item as? Data else { throw KeychainError(status: errSecDecode) }
            return try SecretKey(bytes: bytes)
        case errSecItemNotFound:
            let bytes = SecretKey.newBytes()
            let added: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData: bytes,
            ]
            let status = SecItemAdd(added as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
            return try SecretKey(bytes: bytes)
        case let status:
            throw KeychainError(status: status)
        }
    }
}
