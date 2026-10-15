import AppKit
import DiscoverableActors
import DistributedCluster
import IOKit.hidsystem

/// The media playing on this machine, in whichever app plays it: what's playing, and the keyboard's
/// media keys.
@Discoverable(events: NowPlayingChanged.self)
public distributed actor MediaControl {
    public typealias ActorSystem = ClusterSystem

    private var current: NowPlaying?
    private var watching: Task<Void, Never>?

    public init(actorSystem: ActorSystem, scope: ObjectScope = .shared) async throws {
        self.actorSystem = actorSystem
        watching = Task { [weak self] in
            for await heard in NowPlayingWatcher.changes() {
                guard let self else { return }
                await self.whenLocal { await $0.hear(heard) }
            }
        }
        let object = try DiscoverableObject.resolve(id: self.id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: scope.receptionistKey)
    }

    deinit {
        watching?.cancel()
    }

    /// What's playing, or null when nothing is.
    public distributed var nowPlaying: NowPlaying? { current }

    /// What it heard is announced only when it differs: one change comes as several notifications.
    private func hear(_ heard: NowPlaying?) async {
        guard heard != current else { return }
        current = heard
        await announce(NowPlayingChanged(nowPlaying: heard))
    }

    /// Play what's paused, or pause what's playing.
    public distributed func playPause() throws {
        try Self.press(NX_KEYTYPE_PLAY)
    }

    /// Skip to the next track.
    public distributed func next() throws {
        try Self.press(NX_KEYTYPE_NEXT)
    }

    /// Go back to the previous track.
    public distributed func previous() throws {
        try Self.press(NX_KEYTYPE_PREVIOUS)
    }

    /// Presses and releases a media key, as the keyboard does: the system passes it to the app
    /// playing now. Posting keys needs the user's permission, asked for the first time.
    private static func press(_ key: Int32) throws {
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            throw MediaControlError.notAllowed
        }
        for state in [0xA, 0xB] {
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                // A key press of the media keys' kind: its key in the top half of `data1`,
                // down (0xA) or up (0xB) below it.
                subtype: 8,
                data1: Int(key) << 16 | state << 8,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// What's playing, in which app.
@Describable
public struct NowPlaying: Codable, Sendable, Equatable {
    /// The app playing it.
    public var app: String
    public var title: String?
    public var artist: String?
    public var album: String?
    /// Whether it's playing now, or paused.
    public var isPlaying: Bool
}

/// What's playing changed: another track, another app, played or paused.
@Describable
public struct NowPlayingChanged: Codable, Sendable, Equatable {
    /// What's playing now, or null when nothing is.
    public var nowPlaying: NowPlaying?
}

public enum MediaControlError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case notAllowed

    public var description: String {
        switch self {
        case .notAllowed:
            "Turgai isn't allowed to press media keys. Allow Turgai in System Settings › Privacy & Security › Device Control and Data Access."
        }
    }
}
