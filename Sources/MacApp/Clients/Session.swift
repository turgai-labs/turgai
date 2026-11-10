import ComposableArchitecture
import Foundation
import TurgaiServer

/// A signed-in session: the server's session cookie and when it expires.
struct Session: Codable, Equatable, Sendable {
    var token: String
    var expiresAt: Date
}

/// Keeps the session between launches.
@DependencyClient
struct SessionStore: Sendable {
    var load: @Sendable () -> Session? = { nil }
    /// Failing to save only means signing in again next launch.
    var save: @Sendable (Session) -> Void
    var clear: @Sendable () -> Void
}

extension SessionStore: DependencyKey {
    /// The session in a file only this user can read, next to the server's data.
    /// The keychain would need a team-signed build to keep it between launches, and
    /// the server's signing secret, which can mint any session, already sits in the
    /// same directory with the same protection.
    static let liveValue: SessionStore = {
        let url = TurgaiServer.defaultDirectory.appendingPathComponent("mac-session.json")
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
    }()
}

extension DependencyValues {
    var sessions: SessionStore {
        get { self[SessionStore.self] }
        set { self[SessionStore.self] = newValue }
    }
}
