import AnyLanguageModel
import Hail
import TurgaiDomain
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A Telegram chat, as the model reads it: the attachments of its messages, got through the
/// chat's connection. Public web resources are got with ``Http``.
@Tool("telegram")
public struct Telegram: Sendable {
    /// How a file of the chat is got: its connection's.
    let fetch: ConnectionRun.Fetch

    public init(fetch: @escaping ConnectionRun.Fetch) {
        self.fetch = fetch
    }

    @Command(
        "fetch_attachment",
        description: "Fetch an attachment of a message in this chat, by the attachment_id it's listed with.")
    public func fetchAttachment(_ input: TelegramAttachment) throws -> AttachmentEffect {
        AttachmentEffect(attachment: AttachmentID(rawValue: input.attachmentID), fetch: fetch)
    }

    /// The file, as it is.
    public func render(_ file: ToolData) -> ToolOutput { .data(file) }
}

@Generable
public struct TelegramAttachment: Sendable {
    public let attachmentID: String
}

/// Reading an attachment of the chat it was sent in, through the chat's connection.
public struct AttachmentEffect: ScopedEffect, Sendable {
    public let name = "attachment"
    public let attachment: AttachmentID
    let fetch: ConnectionRun.Fetch

    public static func run(in token: borrowing EffectToken<AttachmentEffect>) async throws -> ToolData {
        let (attachment, fetch) = token.withConfiguration { ($0.attachment, $0.fetch) }
        return try await fetch(attachment)
    }
}
