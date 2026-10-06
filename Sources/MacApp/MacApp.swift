import AppKit
import ComposableArchitecture
import SwiftUI

/// The Mac app: a skylark in the menu bar that runs all of Turgai in this process,
/// with windows for the chat and the live list of objects. The app bundle and its
/// `@main` entry point live in `Clients/Mac`.
public struct TurgaiScenes: Scene {
    @State private var runtime = Runtime()
    /// The app's state, shared by the chat and the turns window, so both follow one connection.
    @State private var app = Store(initialState: AppFeature.State()) {
        AppFeature()
    }

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            MenuContent(runtime: runtime)
        } label: {
            Image(nsImage: .menuBarSkylark)
        }

        Window("Turgai", id: WindowID.chat) {
            RootView(store: app)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 720)

        Window("Objects", id: WindowID.objects) {
            ObjectsWindow(objects: runtime.objects)
        }
        .defaultSize(width: 420, height: 560)

        Window("Turns", id: WindowID.turns) {
            TurnsView(store: app.scope(state: \.chat, action: \.chat))
        }
        .defaultSize(width: 560, height: 640)
    }
}

enum WindowID {
    static let chat = "chat"
    static let objects = "objects"
    static let turns = "turns"
}

private struct ObjectsWindow: View {
    @State private var store: StoreOf<ObjectsFeature>

    init(objects: ObjectsClient) {
        _store = State(
            initialValue: Store(initialState: ObjectsFeature.State()) {
                ObjectsFeature()
            } withDependencies: {
                $0.objects = objects
            })
    }

    var body: some View {
        ObjectsView(store: store)
    }
}

private struct MenuContent: View {
    let runtime: Runtime
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(status)
        Divider()
        Button("Open Chat") { open(WindowID.chat) }
            .keyboardShortcut("o")
        Button("Objects") { open(WindowID.objects) }
            .keyboardShortcut("l")
        Divider()
        Button("Quit Turgai") { runtime.quit() }
            .keyboardShortcut("q")
            .disabled(runtime.status == .stopping)
    }

    private var status: String {
        switch runtime.status {
        case .running: "Turgai is running"
        case .stopping: "Turgai is stopping…"
        case .stopped(let reason): "Turgai stopped: \(reason)"
        }
    }

    private func open(_ id: String) {
        DockPresence.shared.windowOpening()
        openWindow(id: id)
        NSApplication.shared.activate()
        // Activation from a menu bar item can be refused while another app is
        // frontmost; bring the window itself forward once SwiftUI has made it.
        Task { @MainActor in
            let window = NSApplication.shared.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true }
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
        }
    }
}

/// Like Docker: in the Dock while a window is open, menu bar only otherwise. A
/// menu-bar-only app can't reliably bring its windows forward, so a window opened
/// from the menu would stay behind the frontmost app until clicked again.
@MainActor
private final class DockPresence {
    static let shared = DockPresence()

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            // Menus and the menu bar extra close windows too; only ours count.
            guard let closing = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard closing.canBecomeMain else { return }
                Self.shared.windowClosing(closing)
            }
        }
    }

    func windowOpening() {
        NSApplication.shared.setActivationPolicy(.regular)
        // An app launched menu bar only doesn't load its Dock icon, so the tile
        // would be blank; hand it the bundle's icon.
        NSApplication.shared.applicationIconImage = NSImage(named: NSImage.applicationIconName)
    }

    private func windowClosing(_ closing: NSWindow) {
        let othersOpen = NSApplication.shared.windows.contains {
            $0 !== closing && $0.isVisible && $0.canBecomeMain
        }
        if !othersOpen { NSApplication.shared.setActivationPolicy(.accessory) }
    }
}

extension NSImage {
    /// The skylark at menu bar size, tinted by the system like any status item.
    fileprivate static let menuBarSkylark: NSImage = {
        let image = Bundle.module.image(forResource: "Skylark") ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}
