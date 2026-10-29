import DistributedCluster
import EventSourcing
import Foundation
import Testing
import VirtualActors

@testable import TurgaiApplication

/// A channel keeps what its provider's service tells it, through a reference to it, as the
/// service on the node reaches it: received through `executeDistributedTarget`.
@Suite(.serialized)
struct ChannelTests {
    @Test(.timeLimit(.minutes(1)))
    func aChannelKeepsTheCursorItsServiceTellsIt() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("channel", store: store, hostsVirtualActors: true) { node in
            let configuration = ChannelConfiguration<TelegramProvider>(
                id: UUID(), label: "Bot", enabled: true, agentRouting: .defaultProfile,
                provider: TelegramChannelConfig())
            let channel = try await TelegramChannel.resolve(on: node, configuration: configuration)
            try await channel.replaceConfiguration(configuration)
            try await channel.emitProviderEvent(ProviderEvent(.cursorAdvanced(7)))
            guard case .active(_, let state) = try await channel.currentState() else {
                Issue.record("the channel isn't active")
                return
            }
            #expect(state.cursor == .after(7))
        }
    }
}
