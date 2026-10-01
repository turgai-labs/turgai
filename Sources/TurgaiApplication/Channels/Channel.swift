import Distributed
import DistributedCluster
import EventSourcing
import TurgaiDomain
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct TelegramChannelConfig: Codable, Hashable, Sendable {
    public var chatIDs: [Int64]

    public init(chatIDs: [Int64] = []) {
        self.chatIDs = chatIDs
    }
}

public enum ChannelAgentRouting: Codable, Hashable, Sendable {
    case defaultProfile
    case profile(String)

    public var profileID: String? {
        switch self {
        case .defaultProfile: nil
        case .profile(let id): id
        }
    }
}

public enum TurgaiChannelError: Error, Equatable, Sendable {
    case invalidLabel
    case invalidToken
    case unknownChannel(UUID)
}

public enum ChannelRuntimeChange: Codable, Sendable, Equatable {
    case configuration
    case providerCredentials
}

public protocol ChannelProvider: Sendable {
    associatedtype Configuration: Codable & Sendable & Equatable & Hashable
    associatedtype State: Codable & Sendable & Equatable & Hashable
    associatedtype Event: Codable & Sendable & Equatable & Hashable
    associatedtype Runtime: Sendable

    static var providerID: String { get }
    static func initialState(configuration: Configuration) -> State
    static func apply(_ event: Event, to state: inout State)
    static func makeRuntime(
        configuration: ChannelConfiguration<Self>,
        state: State,
        actorSystem: ClusterSystem,
        readState: @escaping @Sendable () async throws -> State,
        emit: @escaping @Sendable (Event) async throws -> Void
    ) async throws -> Runtime
    static func run(_ runtime: Runtime) async throws
    static func decideApproval(
        _ request: ChannelApprovalRequest,
        using runtime: Runtime
    ) async throws -> ApprovalDecision
}

public struct ChannelConfiguration<Provider: ChannelProvider>:
    Codable, Identifiable, Hashable, Sendable
{
    public let id: UUID
    public var label: String
    public var enabled: Bool
    public var agentRouting: ChannelAgentRouting
    public var provider: Provider.Configuration

    public init(
        id: UUID,
        label: String,
        enabled: Bool,
        agentRouting: ChannelAgentRouting,
        provider: Provider.Configuration
    ) {
        self.id = id
        self.label = label
        self.enabled = enabled
        self.agentRouting = agentRouting
        self.provider = provider
    }

}

public enum ChannelState<Provider: ChannelProvider>: Codable, Sendable, Equatable {
    case uninitialized
    case active(ChannelConfiguration<Provider>, Provider.State)
    case deleted(ChannelConfiguration<Provider>, Provider.State)
}

public enum ChannelEvent<Provider: ChannelProvider>: Codable, Sendable, Equatable {
    case created(ChannelConfiguration<Provider>)
    case configurationChanged(ChannelConfiguration<Provider>)
    case provider(Provider.Event)
    case deleted
}

public enum TelegramCursor: Codable, Sendable, Equatable, Hashable {
    case beginning
    case after(Int64)

    public var offset: Int64? {
        guard case .after(let value) = self else { return nil }
        return value
    }
}

public enum TelegramChannelEvent: Codable, Sendable, Equatable, Hashable {
    case cursorAdvanced(Int64)
}

public struct TelegramChannelState: Codable, Sendable, Equatable, Hashable {
    public var cursor: TelegramCursor

    public init(cursor: TelegramCursor = .beginning) {
        self.cursor = cursor
    }
}

public enum TelegramProvider: ChannelProvider {
    public typealias Configuration = TelegramChannelConfig
    public typealias State = TelegramChannelState
    public typealias Event = TelegramChannelEvent
    public typealias Runtime = TelegramChannelRuntime

    public static let providerID = "telegram"

    public static func initialState(configuration: Configuration) -> State {
        TelegramChannelState()
    }

    public static func apply(_ event: Event, to state: inout State) {
        switch event {
        case .cursorAdvanced(let offset):
            state.cursor = .after(offset)
        }
    }

}

public typealias TelegramChannel = Channel<TelegramProvider>

public enum ChannelActorError: Error, Codable, Sendable, Equatable {
    case channelIDMismatch
    case invalidLabel
    case deleted
    case notActive
    case providerRuntimeUnavailable
}

@EventSourced
@VirtualActor
public distributed actor Channel<Provider: ChannelProvider> {
    public typealias ActorSystem = ClusterSystem
    public typealias Event = ChannelEvent<Provider>
    public typealias State = ChannelState<Provider>
    public typealias Dependency = Config

    public enum Config: Codable, Sendable {
        case create(ChannelConfiguration<Provider>)
        case existing(UUID)
    }

    public var state: ChannelState<Provider>

    public let snapshotting: Snapshotting<ChannelEvent<Provider>, ChannelState<Provider>> = .every(
        numberOfEvents: 25,
        retention: .keepLast(2)
    )

    private let channelID: UUID
    private enum ProviderRuntimeState {
        case stopped
        case running(UUID, Provider.Runtime, Task<Void, Never>)
    }
    private var providerRuntime: ProviderRuntimeState = .stopped

    public init(actorSystem: ClusterSystem, dependency: Config) async throws {
        self.actorSystem = actorSystem
        let channelID: UUID
        switch dependency {
        case .create(let requested):
            channelID = requested.id
        case .existing(let id):
            channelID = id
        }
        self.channelID = channelID
        self.state = .uninitialized
        try await actorSystem.journal.register(
            actor: self,
            with: Self.persistenceID(for: channelID)
        )
        await restartProviderRuntime()
    }

    public static func actorID(for channelID: UUID) -> VirtualActorID {
        VirtualActorID(rawValue: "channel:\(Provider.providerID):\(channelID.uuidString)")
    }

    public static var persistencePrefix: String {
        "turgai-channel-\(Provider.providerID)-"
    }

    public static func persistenceID(for channelID: UUID) -> PersistenceID {
        "\(persistencePrefix)\(channelID.uuidString)"
    }

    public static func channelID(from persistenceID: String) -> UUID? {
        guard persistenceID.hasPrefix(persistencePrefix) else { return nil }
        return UUID(
            uuidString: String(persistenceID.dropFirst(persistencePrefix.count))
        )
    }

    public static func resolve(
        on actorSystem: ClusterSystem,
        configuration: ChannelConfiguration<Provider>
    ) async throws -> Self {
        try await actorSystem.virtualActors.getActor(
            identifiedBy: actorID(for: configuration.id),
            dependency: Config.create(configuration)
        )
    }

    /// Resolves a channel actor by identity. If no journal exists, the actor
    /// starts uninitialized; an existing actor recovers its event-sourced
    /// configuration.
    public static func resolve(
        on actorSystem: ClusterSystem,
        channelID: UUID
    ) async throws -> Self {
        return try await actorSystem.virtualActors.getActor(
            identifiedBy: actorID(for: channelID),
            dependency: Config.existing(channelID)
        )
    }

    public distributed func currentState() -> ChannelState<Provider> {
        state
    }

    public distributed func replaceConfiguration(
        _ configuration: ChannelConfiguration<Provider>,
        runtimeChange: ChannelRuntimeChange
    ) async throws {
        guard configuration.id == channelID else {
            throw ChannelActorError.channelIDMismatch
        }
        var accepted = configuration
        accepted.label = try Self.validatedLabel(configuration.label)
        switch state {
        case .uninitialized:
            try await emit(event: .created(accepted))
            await restartProviderRuntime()
        case .active(let existing, _):
            guard existing != accepted || runtimeChange == .providerCredentials else { return }
            await stopProviderRuntime()
            do {
                if existing != accepted {
                    try await emit(event: .configurationChanged(accepted))
                }
            } catch {
                await restartProviderRuntime()
                throw error
            }
            await restartProviderRuntime()
        case .deleted:
            throw ChannelActorError.deleted
        }
    }

    public distributed func emitProviderEvent(_ event: Provider.Event) async throws {
        guard case .active = state else {
            throw ChannelActorError.notActive
        }
        try await emit(event: .provider(event))
    }

    public distributed func delete() async throws {
        switch state {
        case .uninitialized:
            throw ChannelActorError.notActive
        case .active:
            await stopProviderRuntime()
            do {
                try await emit(event: .deleted)
            } catch {
                await restartProviderRuntime()
                throw error
            }
        case .deleted:
            return
        }
    }

    public distributed func decideApproval(
        _ request: ChannelApprovalRequest
    ) async throws -> ApprovalDecision {
        guard case .running(_, let runtime, _) = providerRuntime else {
            return .denied
        }
        return try await Provider.decideApproval(request, using: runtime)
    }

    public func shouldDeactivate() async -> Bool {
        switch state {
        case .uninitialized, .deleted:
            return true
        case .active:
            if case .running = providerRuntime { return false }
            return true
        }
    }

    private func restartProviderRuntime() async {
        await stopProviderRuntime()
        guard case .active(let configuration, let providerState) = state,
            configuration.enabled
        else { return }

        let eventSink: @Sendable (Provider.Event) async throws -> Void = { [weak self] event in
            guard let self else { throw ChannelActorError.providerRuntimeUnavailable }
            try await self.emitProviderEvent(event)
        }
        let stateReader: @Sendable () async throws -> Provider.State = { [weak self] in
            guard let self else { throw ChannelActorError.providerRuntimeUnavailable }
            return try await self.providerStateForRuntime()
        }
        let runtime: Provider.Runtime
        do {
            runtime = try await Provider.makeRuntime(
                configuration: configuration,
                state: providerState,
                actorSystem: actorSystem,
                readState: stateReader,
                emit: eventSink
            )
        } catch {
            actorSystem.log.warning(
                "Channel provider runtime could not start",
                metadata: [
                    "provider": .string(Provider.providerID),
                    "channel": .string(channelID.uuidString),
                    "error": .string(String(describing: error)),
                ]
            )
            return
        }

        let generation = UUID()
        let task = Task { [weak self] in
            do {
                try await Provider.run(runtime)
            } catch is CancellationError {
            } catch {
                try? await self?.reportProviderRuntimeFailure(String(describing: error))
            }
            try? await self?.providerRuntimeDidStop(generation)
        }
        providerRuntime = .running(generation, runtime, task)
    }

    private distributed func providerStateForRuntime() throws -> Provider.State {
        guard case .active(_, let providerState) = state else {
            throw ChannelActorError.notActive
        }
        return providerState
    }

    private func stopProviderRuntime() async {
        guard case .running(_, _, let task) = providerRuntime else { return }
        providerRuntime = .stopped
        task.cancel()
        await task.value
    }

    private distributed func providerRuntimeDidStop(_ generation: UUID) {
        guard case .running(let current, _, _) = providerRuntime,
            current == generation
        else { return }
        providerRuntime = .stopped
    }

    private distributed func reportProviderRuntimeFailure(_ message: String) {
        actorSystem.log.warning(
            "Channel provider runtime stopped",
            metadata: [
                "provider": .string(Provider.providerID),
                "channel": .string(channelID.uuidString),
                "error": .string(message),
            ]
        )
    }

    deinit {
        if case .running(_, _, let task) = providerRuntime {
            task.cancel()
        }
    }

    private static func validatedLabel(_ label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else {
            throw ChannelActorError.invalidLabel
        }
        return trimmed
    }

    public func handleEvent(_ event: ChannelEvent<Provider>) {
        switch event {
        case .created(let configuration):
            state = .active(
                configuration,
                Provider.initialState(configuration: configuration.provider)
            )
        case .configurationChanged(let configuration):
            guard case .active(_, let providerState) = state else { return }
            state = .active(configuration, providerState)
        case .provider(let providerEvent):
            guard case .active(let configuration, var providerState) = state else { return }
            Provider.apply(providerEvent, to: &providerState)
            state = .active(configuration, providerState)
        case .deleted:
            guard case .active(var configuration, let providerState) = state else { return }
            configuration.enabled = false
            state = .deleted(configuration, providerState)
        }
    }
}
