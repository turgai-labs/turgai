import Foundation
@preconcurrency import MusicKit

extension MusicClient {
    public static let live: MusicClient = {
        let player = MusicPlayerController()

        @Sendable func songs(matching query: String) async throws -> [Song] {
            guard await MusicAuthorization.request() == .authorized else {
                throw MusicError.accessDenied
            }
            var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
            request.limit = 20
            return Array(try await request.response().songs)
        }

        @Sendable func record(_ song: Song) -> MusicSong {
            MusicSong(
                id: song.id.rawValue,
                title: song.title,
                artist: song.artistName,
                album: song.albumTitle,
                duration: song.duration
            )
        }

        return MusicClient(
            search: { query in
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
                return try await musicKit { try await songs(matching: query).map(record) }
            },
            play: { query in
                try await musicKit {
                    let matches = try await songs(matching: query)
                    guard let song = matches.first else { throw MusicError.noMatch(query) }
                    try await player.play(song)
                }
            },
            nowPlaying: { try await musicKit { try await player.nowPlaying() } },
            pause: { await player.pause() },
            next: { try await musicKit { try await player.next() } },
            previous: { try await musicKit { try await player.previous() } }
        )
    }()
}

/// Runs MusicKit work, turning its errors into ``MusicError``: they're thrown from
/// a distributed actor, so they have to be codable to reach the caller's node.
private func musicKit<Value>(_ work: () async throws -> Value) async throws -> Value {
    do {
        return try await work()
    } catch let error as MusicError {
        throw error
    } catch is MusicTokenRequestError {
        throw MusicError.catalogUnavailable
    } catch {
        throw MusicError.failed(error.localizedDescription)
    }
}

private actor MusicPlayerController {
    private let player = ApplicationMusicPlayer.shared

    func play(_ song: Song) async throws {
        player.queue = [song]
        try await player.play()
    }

    func nowPlaying() throws -> MusicNowPlaying? {
        guard let entry = player.queue.currentEntry else { return nil }
        return MusicNowPlaying(
            title: entry.title,
            artist: entry.subtitle ?? "",
            isPlaying: player.state.playbackStatus == .playing
        )
    }

    func pause() { player.pause() }

    func next() async throws { try await player.skipToNextEntry() }

    func previous() async throws { try await player.skipToPreviousEntry() }
}
