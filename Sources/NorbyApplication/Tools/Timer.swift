import DistributedCluster
import DurableWorkflows
import Hail
import NorbyDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Durable one-shot timer domain and its scoped capability.
public struct Timer: ScopedEffect, Sendable {
    public typealias Output = Result

    public let name = "timer"
    public let operation: Operation

    public enum Operation: Sendable {
        case create(trigger: Trigger, request: Request)
        case replace(id: WorkflowID, trigger: Trigger, request: Request)
        case cancel(id: WorkflowID)
        case list(conversationID: ConversationID)
    }

    public enum Result: Sendable {
        case scheduled(id: WorkflowID, action: DeferredAction.Kind, replaced: Bool)
        case cancelled
        case listed([Info])
    }

    public init(operation: Operation) {
        self.operation = operation
    }

    public struct Request: Codable, Sendable {
        public let ownerID: NorbyDomain.UserID
        public let conversationID: ConversationID
        public let participantID: ParticipantID
        public let author: MessageAuthor?
        public let action: DeferredAction
        public let capabilities: ChannelCapabilities
        public let agentDirectoryID: AgentDirectoryID
        public let agentRole: String
        public let snapshotPolicy: AgentSnapshotPolicy

        public init(
            ownerID: NorbyDomain.UserID,
            conversationID: ConversationID,
            participantID: ParticipantID,
            author: MessageAuthor? = nil,
            action: DeferredAction,
            capabilities: ChannelCapabilities = .default,
            agentDirectoryID: AgentDirectoryID = "agent-directory",
            agentRole: String = "conversation",
            snapshotPolicy: AgentSnapshotPolicy = .default
        ) {
            self.ownerID = ownerID
            self.conversationID = conversationID
            self.participantID = participantID
            self.author = author
            self.action = action
            self.capabilities = capabilities
            self.agentDirectoryID = agentDirectoryID
            self.agentRole = agentRole
            self.snapshotPolicy = snapshotPolicy
        }
    }

    public struct Input: Codable, Sendable {
        public let fireAt: Date
        public let request: Request

        public init(fireAt: Date, request: Request) {
            self.fireAt = fireAt
            self.request = request
        }
    }

    /// A duration expressed in units meaningful at the tool boundary.
    ///
    /// The model supplies the intent (for example, five minutes). The
    /// application converts it to an absolute instant using its clock.
    public struct RelativeDuration: Codable, Sendable, Equatable {
        public enum Unit: String, Codable, Sendable, Equatable {
            case seconds
            case minutes
            case hours
            case days
            case weeks

            fileprivate var seconds: TimeInterval {
                switch self {
                case .seconds: 1
                case .minutes: 60
                case .hours: 60 * 60
                case .days: 24 * 60 * 60
                case .weeks: 7 * 24 * 60 * 60
                }
            }
        }

        public let amount: Int
        public let unit: Unit

        public init(amount: Int, unit: Unit) {
            self.amount = amount
            self.unit = unit
        }
    }

    /// A one-shot calendar occurrence.
    ///
    /// `offset` moves the current date by calendar components first. The
    /// resulting date is then searched for the next date matching
    /// `matching` in `timeZone`. This keeps the vocabulary open to calendar
    /// concepts without baking phrases such as "tomorrow" or "next Saturday"
    /// into the domain.
    public struct Occurrence: Codable, Sendable, Equatable {
        public let offset: DateComponents
        public let matching: DateComponents
        public let timeZone: TimeZone

        private enum CodingKeys: String, CodingKey {
            case offset
            case matching
            case timeZone = "time_zone"
        }

        public init(
            offset: DateComponents = DateComponents(),
            matching: DateComponents,
            timeZone: TimeZone
        ) {
            self.offset = offset
            self.matching = matching
            self.timeZone = timeZone
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.offset = try container.decode(DateComponents.self, forKey: .offset)
            self.matching = try container.decode(DateComponents.self, forKey: .matching)

            let identifier = try container.decode(String.self, forKey: .timeZone)
            guard let timeZone = TimeZone(identifier: identifier) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .timeZone,
                    in: container,
                    debugDescription: "Invalid IANA timezone: \(identifier)"
                )
            }
            self.timeZone = timeZone
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(offset, forKey: .offset)
            try container.encode(matching, forKey: .matching)
            try container.encode(timeZone.identifier, forKey: .timeZone)
        }
    }

    public enum Trigger: Codable, Sendable, Equatable {
        case after(RelativeDuration)
        case occurrence(Occurrence)

        private enum CodingKeys: String, CodingKey {
            case kind
            case amount
            case unit
            case occurrence
        }

        private enum Kind: String, Codable {
            case after
            case occurrence
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .after:
                self = .after(
                    RelativeDuration(
                        amount: try container.decode(Int.self, forKey: .amount),
                        unit: try container.decode(
                            RelativeDuration.Unit.self,
                            forKey: .unit
                        )
                    )
                )
            case .occurrence:
                self = .occurrence(
                    try container.decode(Occurrence.self, forKey: .occurrence)
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .after(let duration):
                try container.encode(Kind.after, forKey: .kind)
                try container.encode(duration.amount, forKey: .amount)
                try container.encode(duration.unit, forKey: .unit)
            case .occurrence(let occurrence):
                try container.encode(Kind.occurrence, forKey: .kind)
                try container.encode(occurrence, forKey: .occurrence)
            }
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case emptyText
        case invalidRelativeDuration(Int)
        case emptyOccurrence
        case invalidOccurrenceComponent(name: String, value: Int)
        case occurrenceNotFound
    }

    public struct Info: Sendable {
        public let id: WorkflowID
        public let fireAt: Date
        public let action: DeferredAction
        public let status: WorkflowStatus

        public init(
            id: WorkflowID,
            fireAt: Date,
            action: DeferredAction,
            status: WorkflowStatus
        ) {
            self.id = id
            self.fireAt = fireAt
            self.action = action
            self.status = status
        }
    }

    public static func run(
        in token: borrowing EffectToken<Timer>
    ) async throws -> Result {
        let workflows = ActorSystemDependency.current.workflows
        let operation = token.withConfiguration { $0.operation }

        switch operation {
        case .cancel(let id):
            try await cancel(id, workflows: workflows)
            return .cancelled

        case .list(let conversationID):
            return .listed(
                try await list(
                    conversationID: conversationID,
                    workflows: workflows
                )
            )

        case .create(let trigger, let request):
            let now = try await token.withChild(ClockEffect()) { clockToken in
                try await ClockEffect.run(in: clockToken)
            }
            let fireAt = try fireAt(for: trigger, after: now)
            let workflowID = WorkflowID(
                ownerID: request.ownerID,
                conversationID: request.conversationID,
                action: request.action,
                fireAt: fireAt
            )
            try await start(
                id: workflowID,
                fireAt: fireAt,
                request: request,
                workflows: workflows
            )
            return .scheduled(
                id: workflowID,
                action: request.action.kind,
                replaced: false
            )

        case .replace(let existingID, let trigger, let request):
            let now = try await token.withChild(ClockEffect()) { clockToken in
                try await ClockEffect.run(in: clockToken)
            }
            let fireAt = try fireAt(for: trigger, after: now)
            let workflowID = WorkflowID(
                ownerID: request.ownerID,
                conversationID: request.conversationID,
                action: request.action,
                fireAt: fireAt
            )
            try await cancel(existingID, workflows: workflows)
            try await start(
                id: workflowID,
                fireAt: fireAt,
                request: request,
                workflows: workflows
            )
            return .scheduled(
                id: workflowID,
                action: request.action.kind,
                replaced: true
            )
        }
    }

    public static let defaultRetryPolicy = Schedule.defaultRetryPolicy

    public static func validate(_ trigger: Trigger) throws {
        switch trigger {
        case .after(let duration):
            guard duration.amount > 0 else {
                throw Error.invalidRelativeDuration(duration.amount)
            }
        case .occurrence(let occurrence):
            try validate(occurrence.offset)
            try validate(occurrence.matching)
            guard hasComponents(occurrence.offset) || hasComponents(occurrence.matching) else {
                throw Error.emptyOccurrence
            }
        }
    }

    public static func fireAt(for trigger: Trigger, after now: Date) throws -> Date {
        try validate(trigger)
        switch trigger {
        case .after(let duration):
            let fireAt = now.addingTimeInterval(
                TimeInterval(duration.amount) * duration.unit.seconds
            )
            guard fireAt.timeIntervalSince1970.isFinite else {
                throw Error.invalidRelativeDuration(duration.amount)
            }
            return fireAt
        case .occurrence(let occurrence):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = occurrence.timeZone

            guard let anchor = calendar.date(byAdding: occurrence.offset, to: now) else {
                throw Error.occurrenceNotFound
            }

            let searchStart: Date
            if hasDateComponents(occurrence.offset) {
                searchStart =
                    calendar
                    .startOfDay(for: anchor)
                    .addingTimeInterval(-1)
            } else {
                searchStart = anchor
            }

            if !hasComponents(occurrence.matching) {
                return anchor
            }
            guard
                let fireAt = calendar.nextDate(
                    after: searchStart,
                    matching: occurrence.matching,
                    matchingPolicy: .nextTime,
                    repeatedTimePolicy: .first,
                    direction: .forward
                )
            else {
                throw Error.occurrenceNotFound
            }
            return fireAt
        }
    }

    private static func validate(_ components: DateComponents) throws {
        let ranges: [(String, Int?, ClosedRange<Int>)] = [
            ("month", components.month, 1...12),
            ("day", components.day, 1...31),
            ("hour", components.hour, 0...23),
            ("minute", components.minute, 0...59),
            ("second", components.second, 0...59),
            ("nanosecond", components.nanosecond, 0...999_999_999),
            ("weekday", components.weekday, 1...7),
            ("quarter", components.quarter, 1...4),
            ("week_of_month", components.weekOfMonth, 1...6),
            ("week_of_year", components.weekOfYear, 1...53),
        ]
        if let invalid = ranges.first(where: { _, value, range in
            guard let value else { return false }
            return !range.contains(value)
        }) {
            throw Error.invalidOccurrenceComponent(
                name: invalid.0,
                value: invalid.1 ?? 0
            )
        }
    }

    private static func hasComponents(_ components: DateComponents) -> Bool {
        [
            components.era,
            components.year,
            components.month,
            components.day,
            components.hour,
            components.minute,
            components.second,
            components.nanosecond,
            components.weekday,
            components.weekdayOrdinal,
            components.quarter,
            components.weekOfMonth,
            components.weekOfYear,
            components.yearForWeekOfYear,
        ].contains { $0 != nil }
    }

    private static func hasDateComponents(_ components: DateComponents) -> Bool {
        [
            components.era,
            components.year,
            components.month,
            components.day,
            components.weekday,
            components.weekdayOrdinal,
            components.quarter,
            components.weekOfMonth,
            components.weekOfYear,
            components.yearForWeekOfYear,
        ].contains { $0 != nil }
    }

    private static func start(
        id: WorkflowID,
        fireAt: Date,
        request: Request,
        retryPolicy: RetryPolicy? = Self.defaultRetryPolicy,
        workflows: WorkflowActions
    ) async throws {
        guard !request.action.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.emptyText
        }

        try await workflows.startTimer(
            id,
            Input(fireAt: fireAt, request: request),
            retryPolicy
        )
    }

    private static func cancel(
        _ id: WorkflowID,
        workflows: WorkflowActions
    ) async throws {
        try await workflows.cancelTimer(id)
    }

    private static func list(
        conversationID: ConversationID,
        workflows: WorkflowActions
    ) async throws -> [Info] {
        let descriptions = try await workflows.listTimers()
        let decoder = JSONDecoder()
        return descriptions.compactMap { description in
            guard case .running = description.status,
                let inputData = description.inputData,
                let input = try? decoder.decode(Input.self, from: inputData),
                input.request.conversationID == conversationID
            else {
                return nil
            }
            return Info(
                id: description.id,
                fireAt: input.fireAt,
                action: input.request.action,
                status: description.status
            )
        }
        .sorted { $0.fireAt < $1.fireAt }
    }

    fileprivate static func messageID(for workflowID: WorkflowID) -> MessageID {
        MessageID(rawValue: norbyDeterministicUUID("message:\(workflowID.rawValue)"))
    }

    fileprivate static func turnID(for workflowID: WorkflowID) -> NorbyDomain.TurnID {
        NorbyDomain.TurnID(rawValue: norbyDeterministicUUID("turn:\(workflowID.rawValue)"))
    }
}

extension WorkflowID {
    /// Stable identity for a one-shot action. The fire date is part of the
    /// identity so moving a timer creates a new workflow rather than trying
    /// to reuse a completed one.
    public init(
        ownerID: NorbyDomain.UserID,
        conversationID: ConversationID,
        action: DeferredAction,
        fireAt: Date
    ) {
        let value = [
            ownerID.rawValue,
            conversationID.stableKey,
            action.kind.rawValue,
            action.content,
            String(fireAt.timeIntervalSince1970),
        ].joined(separator: "\u{1F}")
        self.init(rawValue: "norby-timer-\(norbyDeterministicUUID(value).uuidString)")
    }
}

@Workflow
public struct TimerWorkflow {
    public typealias Activities = TimerActivities
    public typealias Input = Timer.Input
    public typealias Output = DurableVoid

    public init() {}

    public func run(
        input: Input,
        context: WorkflowContext
    ) async throws -> Output {
        try await context.sleep(
            until: input.fireAt,
            summary: "timer"
        )
        return try await context.executeActivity(
            TimerActivities.Activities.Deliver.self,
            input: input.request
        )
    }
}

@ActivityContainer
public struct TimerActivities {
    @Activity
    public func deliver(
        input: Timer.Request,
        context: ActivityContext
    ) async throws -> DurableVoid {
        let conversation = try await Conversation.resolve(
            on: context.system,
            conversationID: input.conversationID,
            capabilities: input.capabilities,
            agentDirectoryID: input.agentDirectoryID,
            agentRole: input.agentRole,
            snapshotPolicy: input.snapshotPolicy
        )

        switch input.action {
        case .notify(let message):
            try await conversation.notify(message)

        case .promptAgent(let instruction):
            let message = InboundMessage(
                id: Timer.messageID(for: context.workflowID),
                conversationID: input.conversationID,
                participantID: input.participantID,
                userID: input.ownerID,
                author: input.author,
                text: instruction,
                receivedAt: Date()
            )
            try await conversation.send(
                message,
                turnID: Timer.turnID(for: context.workflowID),
                capabilities: input.capabilities
            )
        }

        return DurableVoid()
    }
}
