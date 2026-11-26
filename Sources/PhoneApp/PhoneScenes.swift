#if os(iOS)
    import ComposableArchitecture
    import SwiftUI

    /// Turgai on an iPhone: a client of a server it's told the address of, then signed in to.
    public struct TurgaiPhoneScenes: Scene {
        @State private var store = PhoneFeature.store()

        public init() {}

        public var body: some Scene {
            WindowGroup {
                PhoneRoot(store: store)
            }
        }
    }
#endif
