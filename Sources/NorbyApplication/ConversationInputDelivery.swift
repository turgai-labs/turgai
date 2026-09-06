import NorbyDomain

/// Signals that a transient input has been consumed by the application lane.
///
/// Channel adapters use this as their checkpoint boundary. It deliberately
/// lives outside the domain model: acknowledgement is transport coordination,
/// not business state.
public actor ConversationInputReceipt {
    private var outcome: Outcome = .pending
    private var waiter: CheckedContinuation<Bool, Never>?

    private enum Outcome {
        case pending
        case accepted
        case rejected
        case cancelled
    }

    public init() {}

    /// Waits until the application accepts the input, rejects it, or the
    /// delivery is cancelled because its live session went away.
    public func wait() async -> Bool {
        switch outcome {
        case .accepted:
            return true
        case .rejected, .cancelled:
            return false
        case .pending:
            return await withCheckedContinuation { continuation in
                switch outcome {
                case .accepted:
                    continuation.resume(returning: true)
                case .rejected, .cancelled:
                    continuation.resume(returning: false)
                case .pending:
                    waiter = continuation
                }
            }
        }
    }

    public func acknowledge() {
        guard case .pending = outcome else { return }
        outcome = .accepted
        waiter?.resume(returning: true)
        waiter = nil
    }

    /// Rejects the delivery because application handling failed. The caller
    /// must not checkpoint the provider update in this case.
    public func reject() {
        guard case .pending = outcome else { return }
        outcome = .rejected
        waiter?.resume(returning: false)
        waiter = nil
    }

    public func cancel() {
        guard case .pending = outcome else { return }
        outcome = .cancelled
        waiter?.resume(returning: false)
        waiter = nil
    }
}

/// A channel-neutral input plus the checkpoint receipt owned by the adapter.
/// The input itself remains a pure domain value.
public struct ConversationInputDelivery: Sendable {
    public let input: ConversationInput
    public let receipt: ConversationInputReceipt

    public init(
        input: ConversationInput,
        receipt: ConversationInputReceipt
    ) {
        self.input = input
        self.receipt = receipt
    }
}
