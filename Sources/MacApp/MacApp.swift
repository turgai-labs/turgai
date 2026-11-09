import AppKit
import ComposableArchitecture
import SwiftUI

/// The Mac app: a skylark in the menu bar that runs all of Turgai in this process,
/// with a window for the person's conversations and the live objects beside them. The app bundle and its
/// `@main` entry point live in `Clients/Mac`.
public struct TurgaiScenes: Scene {
    @State private var runtime: Runtime
    /// The app's state: the window's sidebar, its conversation on the one connection, and the
    /// runtime's objects.
    @State private var app: StoreOf<AppFeature>

    public init() {
        let runtime = Runtime()
        _runtime = State(initialValue: runtime)
        _app = State(initialValue: AppFeature.store(objects: runtime.objects))
    }

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
        .commands { PanelCommands(store: app) }

        Window("Objects", id: WindowID.objects) {
            ObjectsView(store: app.scope(state: \.objects, action: \.objects))
                .frame(minWidth: 320, minHeight: 400)
        }
        .defaultSize(width: 380, height: 600)

        Window("Profile", id: WindowID.profile) {
            ProfileView(store: app.scope(state: \.profile, action: \.profile))
                .frame(minWidth: 360, minHeight: 420)
        }
        .defaultSize(width: 420, height: 560)
        // Someone else may be signed in by the next launch.
        .restorationBehavior(.disabled)
    }
}

enum WindowID {
    static let chat = "chat"
    static let objects = "objects"
    static let profile = "profile"
}

private struct MenuContent: View {
    let runtime: Runtime
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(status)
        Divider()
        Button("Open Chat") { open(WindowID.chat) }
            .keyboardShortcut("o")
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
