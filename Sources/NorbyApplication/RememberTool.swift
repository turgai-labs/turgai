import DistributedCluster
import Foundation
import Hail
import NorbyDomain
import NorbyMemory

/// Lets the model add or revise a durable, user-specific memory. The tool is
/// scoped to a user and the source conversation turn by the application
/// composition root; Hail only sees a normal per-turn tool.
public struct MemoryTool: Tool {
    public enum Operation: String, Codable, Sendable, Equatable, CaseIterable {
        case add
        case revise
    }

    public enum ValueKind: String, Codable, Sendable, Equatable, CaseIterable {
        case text
        case person
        case place
        case date
        case preference
    }

    public struct Input: Codable, Sendable {
        public let operation: Operation
        public let factID: String?
        public let namespace: MemoryNamespace
        public let predicate: String
        public let value: String
        public let valueKind: ValueKind
        public let confidence: Double
        public let importance: Double
        public let stability: MemoryStability

        private enum CodingKeys: String, CodingKey {
            case operation
            case factID = "fact_id"
            case namespace
            case predicate
            case value
            case valueKind = "value_kind"
            case confidence
            case importance
            case stability
        }

        public init(
            operation: Operation = .add,
            factID: String? = nil,
            namespace: MemoryNamespace,
            predicate: String,
            value: String,
            valueKind: ValueKind = .text,
            confidence: Double = 0.9,
            importance: Double = 0.5,
            stability: MemoryStability = .mutable
        ) {
            self.operation = operation
            self.factID = factID
            self.namespace = namespace
            self.predicate = predicate
            self.value = value
            self.valueKind = valueKind
            self.confidence = confidence
            self.importance = importance
            self.stability = stability
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.operation = try container.decodeIfPresent(Operation.self, forKey: .operation) ?? .add
            self.factID = try container.decodeIfPresent(String.self, forKey: .factID)
            self.namespace = try container.decode(MemoryNamespace.self, forKey: .namespace)
            self.predicate = try container.decode(String.self, forKey: .predicate)
            self.value = try container.decode(String.self, forKey: .value)
            self.valueKind = try container.decode(ValueKind.self, forKey: .valueKind)
            self.confidence = try container.decode(Double.self, forKey: .confidence)
            self.importance = try container.decode(Double.self, forKey: .importance)
            self.stability = try container.decode(MemoryStability.self, forKey: .stability)
        }
    }

    public let name = "memory"
    public let description =
        "Add or revise a durable, user-specific fact established by the conversation. Use add for a new fact and revise with the exact fact_id shown in memory context when correcting an existing fact. Do not store one-off task parameters, secrets, credentials, or sensitive information."

    private let actorSystem: ClusterSystem
    private let userID: NorbyDomain.UserID
    private let observation: MemoryObservation

    public init(
        actorSystem: ClusterSystem,
        userID: NorbyDomain.UserID,
        observation: MemoryObservation
    ) {
        self.actorSystem = actorSystem
        self.userID = userID
        self.observation = observation
    }

    public var schema: LLMToolSchema {
        LLMToolSchema(
            type: "function",
            function: LLMToolSchema.FunctionSchema(
                name: name,
                description: description,
                parameters: LLMToolSchema.ParameterSchema(
                    type: "object",
                    properties: [
                        "namespace": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "Memory category.",
                            enumValues: MemoryNamespace.allCases.map(\.rawValue)
                        ),
                        "operation": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "Use add for a new fact or revise to correct the fact identified by fact_id.",
                            enumValues: Operation.allCases.map(\.rawValue)
                        ),
                        "fact_id": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "The existing memory fact ID. Required for revise; omit for add.",
                            enumValues: nil
                        ),
                        "predicate": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "A short stable property name, for example name, home, or likes.",
                            enumValues: nil
                        ),
                        "value": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "The value to remember.",
                            enumValues: nil
                        ),
                        "value_kind": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "How to interpret the value.",
                            enumValues: ValueKind.allCases.map(\.rawValue)
                        ),
                        "confidence": LLMToolSchema.PropertySchema(
                            type: "number",
                            description: "Confidence from 0 to 1.",
                            enumValues: nil
                        ),
                        "importance": LLMToolSchema.PropertySchema(
                            type: "number",
                            description: "Importance from 0 to 1.",
                            enumValues: nil
                        ),
                        "stability": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "How likely the fact is to change.",
                            enumValues: MemoryStability.allCases.map(\.rawValue)
                        ),
                    ],
                    required: ["operation", "namespace", "predicate", "value", "value_kind", "confidence", "importance", "stability"]
                )
            )
        )
    }

    public func effect(for input: Input) throws -> CoordinationEffect {
        _ = try proposal(from: input)
        return CoordinationEffect(subsystem: "memory", action: input.operation.rawValue)
    }

    public func execute(
        input: Input,
        token: borrowing EffectToken<CoordinationEffect>
    ) async throws -> String {
        _ = token
        let proposal = try proposal(from: input)
        let user = try await User.resolve(on: actorSystem, userID: userID)
        let update = try await user.applyMemoryProposal(
            proposal,
            observation: observation
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

    private func proposal(from input: Input) throws -> MemoryProposal {
        let predicate = input.predicate.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = input.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !predicate.isEmpty else {
            throw ToolError.missingArgument("predicate")
        }
        guard !value.isEmpty else {
            throw ToolError.missingArgument("value")
        }

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

        let candidate = FactCandidate(
            namespace: input.namespace,
            predicate: predicate,
            value: memoryValue,
            evidence: [],
            confidence: input.confidence,
            importance: input.importance,
            stability: input.stability,
            observedAt: observation.observedAt
        )

        switch input.operation {
        case .add:
            guard input.factID == nil else {
                throw ToolError.invalidArgument("fact_id", value: "fact_id is only used for revise")
            }
            return .add(candidate)
        case .revise:
            guard let factID = input.factID, !factID.isEmpty else {
                throw ToolError.missingArgument("fact_id")
            }
            guard let uuid = UUID(uuidString: factID) else {
                throw ToolError.invalidArgument("fact_id", value: factID)
            }
            return .revise(
                factID: MemoryFactID(rawValue: uuid),
                candidate: candidate
            )
        }
    }
}

/// Source compatibility for callers that still refer to the old name.
public typealias RememberTool = MemoryTool
