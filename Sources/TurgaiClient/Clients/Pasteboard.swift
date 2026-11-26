#if os(macOS)
    import AppKit
#else
    import UIKit
#endif
import ComposableArchitecture

/// The general pasteboard, for copying text.
@DependencyClient
package struct Pasteboard: Sendable {
    package var copy: @Sendable (_ text: String) async -> Void
}

extension Pasteboard: DependencyKey {
    package static let liveValue = Pasteboard(copy: { text in
        await MainActor.run {
            #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            #else
                UIPasteboard.general.string = text
            #endif
        }
    })
}

extension DependencyValues {
    package var pasteboard: Pasteboard {
        get { self[Pasteboard.self] }
        set { self[Pasteboard.self] = newValue }
    }
}
