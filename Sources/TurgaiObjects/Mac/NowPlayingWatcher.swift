import AppKit
import Foundation
import Synchronization

/// What's playing on this Mac, as it changes, in whichever app plays it.
///
/// It's read from MediaRemote, the private framework behind Control Center's Now Playing,
/// which answers only Apple's own processes since macOS 15.4. So `osascript`, which is one,
/// runs a script that listens to it and prints a line for each change, read here.
enum NowPlayingWatcher {
    /// What's playing now, then each change, until the task reading it is cancelled. If the
    /// script stops, it starts again.
    static func changes() -> AsyncStream<NowPlaying?> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    await run { continuation.yield($0) }
                    try? await Task.sleep(for: .seconds(2))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs the script once, passing on each line it prints, until it ends or the task is
    /// cancelled, which ends it.
    private static func run(_ heard: (NowPlaying?) -> Void) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        await withTaskCancellationHandler {
            for await line in lines(of: output.fileHandleForReading) {
                guard let read = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)) else { continue }
                heard(read.nowPlaying)
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// Each line `pipe` gives, until it closes, read as it comes. Not `FileHandle.bytes`: its
    /// reads in a process share one reader, so waiting here for the next change would hold up
    /// every other read, a journal's replay among them.
    private static func lines(of pipe: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let pending = Mutex(Data())
            pipe.readabilityHandler = { pipe in
                let data = pipe.availableData
                guard !data.isEmpty else {
                    pipe.readabilityHandler = nil
                    let rest = pending.withLock { $0 }
                    if !rest.isEmpty { continuation.yield(String(decoding: rest, as: UTF8.self)) }
                    continuation.finish()
                    return
                }
                let complete = pending.withLock { buffer -> [String] in
                    buffer.append(data)
                    guard let last = buffer.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
                    let lines = buffer[buffer.startIndex..<last].split(
                        separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
                    buffer = Data(buffer[buffer.index(after: last)...])
                    return lines.map { String(decoding: $0, as: UTF8.self) }
                }
                for line in complete { continuation.yield(line) }
            }
            continuation.onTermination = { _ in pipe.readabilityHandler = nil }
        }
    }

    /// One line the script prints.
    private struct Line: Decodable {
        let app: String?
        let playing: Bool
        let title: String?
        let artist: String?
        let album: String?
        let artwork: String?

        /// Nothing plays when no app does.
        var nowPlaying: NowPlaying? {
            guard let app else { return nil }
            return NowPlaying(app: Self.name(of: app), title: title, artist: artist, album: album, artworkURL: Self.webAddress(artwork), isPlaying: playing)
        }

        /// The artwork's identifier when it's a web address: Apple Music gives one, other apps may
        /// give something else.
        private static func webAddress(_ identifier: String?) -> String? {
            guard let identifier, let url = URL(string: identifier), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                url.host != nil
            else { return nil }
            return identifier
        }

        /// An app's name, from its bundle identifier.
        private static func name(of bundle: String) -> String {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return bundle }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
    }

    /// Prints what's playing, then again on each of MediaRemote's change notifications, which
    /// it delivers to the main queue: delivered elsewhere, the handler doesn't run. It ends once
    /// the process that started it is gone.
    private static let script = #"""
        ObjC.import('Foundation');
        $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
        ObjC.bindFunction('MRMediaRemoteRegisterForNowPlayingNotifications', ['void', ['id']]);
        ObjC.bindFunction('getppid', ['int', []]);
        const Request = $.NSClassFromString('MRNowPlayingRequest');
        const output = $.NSFileHandle.fileHandleWithStandardOutput;

        function text(value) { return value.isNil() ? null : value.js; }

        function print() {
          const item = Request.localNowPlayingItem;
          const info = item.nowPlayingInfo;
          const metadata = item.metadata;
          const field = (key) => info.isNil() ? null : text(info.valueForKey(key));
          const line = JSON.stringify({
            app: text(Request.localNowPlayingPlayerPath.client.bundleIdentifier),
            playing: Request.localIsPlaying,
            title: field('kMRMediaRemoteNowPlayingInfoTitle'),
            artist: field('kMRMediaRemoteNowPlayingInfoArtist'),
            album: field('kMRMediaRemoteNowPlayingInfoAlbum'),
            artwork: metadata.isNil() ? null : text(metadata.artworkIdentifier),
          });
          output.writeData($(line + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
        }

        ObjC.registerSubclass({
          name: 'TurgaiNowPlayingWatcher',
          methods: { 'changed:': { types: ['void', ['id']], implementation: function () { print(); } } },
        });
        const watcher = $.TurgaiNowPlayingWatcher.alloc.init;
        for (const name of ['kMRMediaRemoteNowPlayingInfoDidChangeNotification',
                            'kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification',
                            'kMRMediaRemoteNowPlayingApplicationDidChangeNotification']) {
          $.NSNotificationCenter.defaultCenter.addObserverSelectorNameObject(watcher, 'changed:', name, $());
        }
        $.MRMediaRemoteRegisterForNowPlayingNotifications($.NSOperationQueue.mainQueue.underlyingQueue);
        print();
        while ($.getppid() !== 1) {
          $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(5));
        }
        """#
}
