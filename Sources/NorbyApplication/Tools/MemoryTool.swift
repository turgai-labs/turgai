import Hail
import NorbyDomain
import NorbyMemory

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The concrete capability for applying one validated memory proposal.
///
/// The model-facing ``MemoryTool`` constructs this effect; execution is kept
/// here so the dependency is visibly tied to the memory effect rather than a
/// broad coordination capability.
public struct MemoryEffect: ScopedEffect, Sendable {
    public typealias Output = String

    public let name = "memory"
    public let input: MemoryTool.Input
    public let userID: NorbyDomain.UserID
    public let observation: MemoryObservation
    public let expectedGeneration: MemoryGeneration?

    public init(
        input: MemoryTool.Input,
        userID: NorbyDomain.UserID,
        observation: MemoryObservation,
        expectedGeneration: MemoryGeneration?
    ) {
        self.input = input
        self.userID = userID
        self.observation = observation
        self.expectedGeneration = expectedGeneration
    }

    public static func run(
        in token: borrowing EffectToken<MemoryEffect>
    ) async throws -> String {
        let effect = token.withConfiguration { $0 }
        try validate(effect.input)
        let proposal = try proposal(from: effect.input, observation: effect.observation)
        let user = try await ActorSystemDependency<MemoryEffect>.current.virtualActors.resolveUser(effect.userID)
        let update = try await user.applyMemoryProposal(
            proposal,
            observation: effect.observation,
            expectedGeneration: effect.expectedGeneration
        )
        switch (update.newFactCount, update.updatedFactCount) {
        case (0, 0):
            return "No memory was changed."
        case (let newCount, 0):
            return newCount == 1
                ? "Noted down 1 fact."
                : "Noted down \(newCount) facts."
        case (0, let updatedCount):
            return updatedCount == 1
                ? "Updated 1 existing fact."
                : "Updated \(updatedCount) existing facts."
        default:
            return "Noted down \(update.newFactCount) facts and updated \(update.updatedFactCount) existing facts."
        }
    }

    fileprivate static func validate(_ input: MemoryTool.Input) throws {
        guard !input.predicate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.missingArgument("predicate")
        }
        guard !input.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.missingArgument("value")
        }
        guard !input.supportingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.missingArgument("supporting_text")
        }
        guard input.confidence.isFinite, (0...1).contains(input.confidence) else {
            throw ToolError.invalidArgument("confidence", value: String(input.confidence))
        }
        guard input.importance.isFinite, (0...1).contains(input.importance) else {
            throw ToolError.invalidArgument("importance", value: String(input.importance))
        }

        switch input.operation {
        case .add:
            guard input.factID == nil else {
                throw ToolError.invalidArgument("fact_id", value: "fact_id is only used for revise")
            }
        case .revise:
            guard let factID = input.factID,
                !factID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ToolError.missingArgument("fact_id")
            }
        }
    }

    fileprivate static func proposal(
        from input: MemoryTool.Input,
        observation: MemoryObservation
    ) throws -> MemoryProposal {
        let predicate = input.predicate.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = input.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let supportingText = input.supportingText.trimmingCharacters(in: .whitespacesAndNewlines)

        let memoryValue: MemoryValue
        switch input.valueKind {
        case .text:
            memoryValue = .text(value)
        case .person:
            memoryValue = .person(value)
        case .place:
            memoryValue = .place(value)
        case .date:
            guard let date = ISO8601DateFormatter().date(from: value) else {
                throw ToolError.invalidArgument("value", value: value)
            }
            memoryValue = .date(date)
        case .preference:
            guard let preference = Bool(value) else {
                throw ToolError.invalidArgument("value", value: value)
            }
            memoryValue = .preference(preference)
        }

        guard let namespace = MemoryNamespace(rawValue: input.namespace.rawValue),
            let stability = MemoryStability(rawValue: input.stability.rawValue)
        else {
            throw ToolError.invalidArgument("namespace", value: input.namespace.rawValue)
        }
        let candidate = FactCandidate(
            namespace: namespace,
            predicate: predicate,
            value: memoryValue,
            evidence: [observation.id],
            supportingText: supportingText,
            confidence: input.confidence,
            importance: input.importance,
            stability: stability,
            observedAt: observation.observedAt
        )

        switch input.operation {
        case .add:
            return .add(candidate)
        case .revise:
            guard let factID = input.factID,
                let uuid = UUID(uuidString: factID)
            else {
                throw ToolError.invalidArgument("fact_id", value: input.factID ?? "")
            }
            return .revise(
                factID: MemoryFactID(rawValue: uuid),
                candidate: candidate
            )
        }
    }
}

/// Lets the model propose a durable user-specific memory update.
///
/// It is scoped to the current user and observation by the application
/// composition root, then applies proposals through Norby's memory actor.
@Tool
public struct MemoryTool {
    public enum Operation: String, Codable, Sendable, Equatable, CaseIterable {
        case add
        case revise
    }

    public enum Namespace: String, Codable, Sendable, Equatable, CaseIterable {
        case profile
        case preference
        case relationship
        case project
        case environment
    }

    public enum ValueKind: String, Codable, Sendable, Equatable, CaseIterable {
        case text
        case person
        case place
        case date
        case preference
    }

    public enum Stability: String, Codable, Sendable, Equatable, CaseIterable {
        case transient
        case situational
        case mutable
        case stable
    }

    public struct Input: Codable, Sendable {
        public let operation: Operation
        public let factID: String?
        public let namespace: Namespace
        public let predicate: String
        public let value: String
        public let valueKind: ValueKind
        public let supportingText: String
        public let confidence: Double
        public let importance: Double
        public let stability: Stability

        private enum CodingKeys: String, CodingKey {
            case operation
            case factID = "fact_id"
            case namespace
            case predicate
            case value
            case valueKind = "value_kind"
            case supportingText = "supporting_text"
            case confidence
            case importance
            case stability
        }

        public init(
            operation: Operation = .add,
            factID: String? = nil,
            namespace: Namespace,
            predicate: String,
            value: String,
            valueKind: ValueKind = .text,
            supportingText: String,
            confidence: Double = 0.9,
            importance: Double = 0.5,
            stability: Stability = .mutable
        ) {
            self.operation = operation
            self.factID = factID
            self.namespace = namespace
            self.predicate = predicate
            self.value = value
            self.valueKind = valueKind
            self.supportingText = supportingText
            self.confidence = confidence
            self.importance = importance
            self.stability = stability
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.operation = try container.decodeIfPresent(Operation.self, forKey: .operation) ?? .add
            self.factID = try container.decodeIfPresent(String.self, forKey: .factID)
            self.namespace = try container.decode(Namespace.self, forKey: .namespace)
            self.predicate = try container.decode(String.self, forKey: .predicate)
            self.value = try container.decode(String.self, forKey: .value)
            self.valueKind = try container.decode(ValueKind.self, forKey: .valueKind)
            self.supportingText = try container.decode(String.self, forKey: .supportingText)
            self.confidence = try container.decode(Double.self, forKey: .confidence)
            self.importance = try container.decode(Double.self, forKey: .importance)
            self.stability = try container.decode(Stability.self, forKey: .stability)
        }
    }

    public let name = "memory"
    public let description =
        "Add or revise a durable, user-specific fact established by the user's message. supporting_text must be copied from that message, never from an assistant reply or tool result. Use add for a new fact and revise with the exact fact_id shown in memory context when correcting an existing fact. Do not store one-off task parameters, secrets, credentials, or sensitive information."

    private let userID: NorbyDomain.UserID
    private let observation: MemoryObservation
    private let expectedGeneration: MemoryGeneration?

    public init(
        userID: NorbyDomain.UserID,
        observation: MemoryObservation,
        expectedGeneration: MemoryGeneration? = nil
    ) {
        self.userID = userID
        self.observation = observation
        self.expectedGeneration = expectedGeneration
    }

    public var schema: ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            parameters: ToolSchema.object(
                name: "MemoryArguments",
                description: "Arguments for changing one durable memory fact.",
                properties: [
                    .init(name: "namespace", description: "Memory category.", schema: ToolSchema.string(name: "MemoryNamespace", choices: Namespace.allCases.map(\.rawValue))),
                    .init(name: "operation", description: "Use add for a new fact or revise an existing fact.", schema: ToolSchema.string(name: "MemoryOperation", choices: Operation.allCases.map(\.rawValue))),
                    .init(name: "fact_id", description: "Existing fact ID for revise.", schema: ToolSchema.string(name: "MemoryFactID"), isOptional: true),
                    .init(name: "predicate", description: "A short stable property name.", schema: ToolSchema.string(name: "MemoryPredicate")),
                    .init(name: "value", description: "The value to remember.", schema: ToolSchema.string(name: "MemoryValue")),
                    .init(name: "value_kind", description: "How to interpret the value.", schema: ToolSchema.string(name: "MemoryValueKind", choices: ValueKind.allCases.map(\.rawValue))),
                    .init(name: "supporting_text", description: "A short quote from the user's message establishing the fact.", schema: ToolSchema.string(name: "SupportingText")),
                    .init(name: "confidence", description: "Confidence from 0 to 1.", schema: ToolSchema.number()),
                    .init(name: "importance", description: "Importance from 0 to 1.", schema: ToolSchema.number()),
                    .init(name: "stability", description: "How likely the fact is to change.", schema: ToolSchema.string(name: "MemoryStability", choices: Stability.allCases.map(\.rawValue)))
                ]
            )
        )
    }

    public func effect(for input: Input) throws -> MemoryEffect {
        try MemoryEffect.validate(input)
        return MemoryEffect(
            input: input,
            userID: userID,
            observation: observation,
            expectedGeneration: expectedGeneration
        )
    }

    public func run(
        input: Input,
        token: borrowing EffectToken<MemoryEffect>
    ) async throws -> String {
        _ = input
        return try await MemoryEffect.run(in: token)
    }

}
