import ComposableArchitecture
import Foundation

/// A Turgai server, by the address it answers at.
package struct ServerAddress: Codable, Hashable, Sendable {
    package let url: URL

    package init(url: URL) {
        self.url = url
    }

    /// The address `written` names: as written, or, without a scheme, over HTTP. None for what
    /// names no host.
    package init?(written: String) {
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: full), url.host() != nil, ["http", "https"].contains(url.scheme) else {
            return nil
        }
        self.url = url
    }

    /// How it's written to people: its host and port, as it's typed.
    package var shown: String {
        let host = url.host() ?? url.absoluteString
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// The server this Mac runs itself.
    package static let onThisMac = ServerAddress(url: URL(string: "http://127.0.0.1:3333")!)
    /// The cookie a server keeps its sessions in.
    package static let sessionCookie = "turgai_auth"
}

/// A signed-in session: the server it's on, that server's session cookie, and when it expires.
package struct Session: Codable, Equatable, Sendable {
    package var server: ServerAddress
    package var token: String
    package var expiresAt: Date

    package init(server: ServerAddress, token: String, expiresAt: Date) {
        self.server = server
        self.token = token
        self.expiresAt = expiresAt
    }

    /// `request` made as this session, to its server.
    package func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: server.url.appending(path: path))
        request.setValue("\(ServerAddress.sessionCookie)=\(token)", forHTTPHeaderField: "Cookie")
        return request
    }
}

/// Keeps the session between launches.
@DependencyClient
package struct SessionStore: Sendable {
    package var load: @Sendable () -> Session? = { nil }
    /// Failing to save only means signing in again next launch.
    package var save: @Sendable (Session) -> Void
    package var clear: @Sendable () -> Void
}

extension SessionStore: DependencyKey {
    /// The session where only this user's app reads it: on a Mac, in a file only they can read, next
    /// to the server's data, whose signing secret, which can mint any session, sits there with the
    /// same protection (the keychain would need a team-signed build to keep it between launches);
    /// on an iPhone, in the keychain, readable once the phone was first unlocked after starting.
    package static let liveValue: SessionStore = {
        #if os(macOS)
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".turgai", isDirectory: true).appendingPathComponent("mac-session.json")
            return SessionStore(
                load: {
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? JSONDecoder().decode(Session.self, from: data)
                },
                save: { session in
                    guard let data = try? JSONEncoder().encode(session) else { return }
                    try? FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard (try? data.write(to: url, options: .atomic)) != nil else { return }
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                },
                clear: {
                    try? FileManager.default.removeItem(at: url)
                }
            )
        #else
            return SessionStore(
                load: {
                    guard let data = KeychainItem.session.read() else { return nil }
                    return try? JSONDecoder().decode(Session.self, from: data)
                },
                save: { session in
                    guard let data = try? JSONEncoder().encode(session) else { return }
                    KeychainItem.session.write(data)
                },
                clear: {
                    KeychainItem.session.delete()
                }
            )
        #endif
    }()
}

/// Which server the app talks to, as it was chosen: kept between launches, for an app with no
/// server of its own, so it's there before the first screen. Not secret: an address.
@DependencyClient
package struct ServerChoice: Sendable {
    package var load: @Sendable () -> ServerAddress? = { nil }
    package var save: @Sendable (ServerAddress) -> Void
    package var clear: @Sendable () -> Void
}

extension ServerChoice: DependencyKey {
    package static let liveValue: ServerChoice = {
        let key = "turgai.server"
        return ServerChoice(
            load: {
                UserDefaults.standard.string(forKey: key).flatMap(URL.init(string:)).map(ServerAddress.init(url:))
            },
            save: { UserDefaults.standard.set($0.url.absoluteString, forKey: key) },
            clear: { UserDefaults.standard.removeObject(forKey: key) }
        )
    }()
}

#if !os(macOS)
    import Security

    /// One item of the app's own in the keychain, by what it holds.
    private enum KeychainItem: String {
        case session = "session"

        private var query: [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "turgai",
                kSecAttrAccount as String: rawValue,
            ]
        }

        func read() -> Data? {
            var found: AnyObject?
            var asking = query
            asking[kSecReturnData as String] = true
            asking[kSecMatchLimit as String] = kSecMatchLimitOne
            guard SecItemCopyMatching(asking as CFDictionary, &found) == errSecSuccess else { return nil }
            return found as? Data
        }

        /// Failing to keep it only means signing in again next launch.
        func write(_ data: Data) {
            let changed = [kSecValueData as String: data] as CFDictionary
            if SecItemUpdate(query as CFDictionary, changed) == errSecItemNotFound {
                var adding = query
                adding[kSecValueData as String] = data
                adding[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(adding as CFDictionary, nil)
            }
        }

        func delete() {
            SecItemDelete(query as CFDictionary)
        }
    }
#endif

extension DependencyValues {
    package var sessions: SessionStore {
        get { self[SessionStore.self] }
        set { self[SessionStore.self] = newValue }
    }

    package var serverChoice: ServerChoice {
        get { self[ServerChoice.self] }
        set { self[ServerChoice.self] = newValue }
    }
}
