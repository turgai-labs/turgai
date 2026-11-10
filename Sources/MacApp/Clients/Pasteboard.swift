import AppKit
import ComposableArchitecture

/// The general pasteboard, for copying text.
@DependencyClient
struct Pasteboard: Sendable {
    var copy: @Sendable (_ text: String) async -> Void
}

extension Pasteboard: DependencyKey {
    static let liveValue = Pasteboard(copy: { text in
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    })
}

extension DependencyValues {
    var pasteboard: Pasteboard {
        get { self[Pasteboard.self] }
        set { self[Pasteboard.self] = newValue }
    }
}
