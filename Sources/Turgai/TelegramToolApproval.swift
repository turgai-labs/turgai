import TurgaiApplication
import TurgaiDomain
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Telegram-backed dynamic consent for user-authored tools.
///
/// The continuation only parks the current live tool invocation. The request
/// is kept in the actor until it resolves, expires, is cancelled, or the
/// Telegram send fails. Callback data contains only an opaque request ID and
/// every callback is checked against the originating chat and user.
actor TelegramToolApproval: ToolApproval {
    private struct Pending {
        let request: ApprovalRequest
        let continuation: CheckedContinuation<ApprovalDecision, Error>
    }

    private let client: TelegramAPIClient
    private var pending: [UUID: Pending] = [:]
    private let expiration: Duration = .seconds(300)

    init(client: TelegramAPIClient) {
        self.client = client
    }

    func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        guard let chatID = Self.chatID(for: request.conversationID) else {
            return .denied
        }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<ApprovalDecision, Error>) in
                pending[id] = Pending(request: request, continuation: continuation)
                Task { [weak self] in
                    await self?.sendRequest(id: id, chatID: chatID, request: request)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.resolve(id: id, decision: .denied)
            }
        }
    }

    /// Handles only the approval callback namespace. Returning true prevents
    /// an approval callback from being interpreted as a user chat message.
    func handle(_ callback: TelegramCallbackQuery) async -> Bool {
        guard let data = callback.data,
            let parsed = Self.parse(data: data)
        else { return false }

        guard let pendingRequest = pending[parsed.id] else {
            return true
        }

        guard let chatID = Self.chatID(for: pendingRequest.request.conversationID),
            callback.message?.chat.id == chatID,
            Self.telegramUserID(from: pendingRequest.request.requesterID) == callback.from.id
        else {
            return true
        }

        resolve(
            id: parsed.id,
            decision: parsed.granted ? .granted : .denied
        )
        return true
    }

    private func sendRequest(
        id: UUID,
        chatID: Int64,
        request: ApprovalRequest
    ) async {
        let command = request.commandSummary
        let directory = request.workingDirectory ?? "(default)"
        let text = [
            "Turgai wants permission to run user tool \(request.toolName).",
            "",
            "Command: \(command)",
            "Working directory: \(directory)",
            "Arguments: \(request.summary)",
        ].joined(separator: "\n")
        let markup = TelegramInlineKeyboardMarkup(
            inlineKeyboard: [
                [
                    TelegramInlineKeyboardButton(
                        text: "Approve",
                        callbackData: Self.callbackData(id: id, granted: true)
                    ),
                    TelegramInlineKeyboardButton(
                        text: "Deny",
                        callbackData: Self.callbackData(id: id, granted: false)
                    ),
                ]
            ]
        )

        do {
            _ = try await client.sendMessageWithMarkup(
                chatID,
                text,
                nil,
                nil,
                markup
            )
            Task { [weak self] in
                try? await Task.sleep(for: self?.expiration ?? .seconds(300))
                await self?.resolve(id: id, decision: .denied)
            }
        } catch {
            resolve(id: id, error: error)
        }
    }

    private func resolve(id: UUID, decision: ApprovalDecision) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(returning: decision)
    }

    private func resolve(id: UUID, error: any Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: error)
    }

    private static func callbackData(id: UUID, granted: Bool) -> String {
        "turgai-approval:\(granted ? "grant" : "deny"):" + id.uuidString
    }

    private static func parse(data: String) -> (id: UUID, granted: Bool)? {
        let parts = data.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "turgai-approval",
            let id = UUID(uuidString: parts[2])
        else { return nil }
        switch parts[1] {
        case "grant": return (id, true)
        case "deny": return (id, false)
        default: return nil
        }
    }

    private static func chatID(for conversationID: String) -> Int64? {
        guard let id = ConversationID(stableKey: conversationID),
            id.channel == ChannelID("telegram")
        else { return nil }
        return Int64(id.externalAddress.rawValue)
    }

    private static func telegramUserID(from requesterID: String) -> Int64? {
        Int64(requesterID.split(separator: ":").last.map(String.init) ?? "")
    }
}
