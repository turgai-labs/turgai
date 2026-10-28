import AnyLanguageModel
import Hail
import TurgaiDomain
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A Telegram chat, as the model reads it: the attachments of its messages, got through the bot
/// the chat is with. Public web resources are got with ``Http``.
@Tool("telegram")
public struct Telegram: Sendable {
    /// The channel the chat is in: its bot's.
    let chat: ChannelID
    let files: TelegramFiles

    public init(chat: ChannelID, files: TelegramFiles) {
        self.chat = chat
        self.files = files
    }

    @Command(
        "fetch_attachment", description: "Fetch an attachment of a message in this chat, by the attachment_id it's listed with.")
    public func fetchAttachment(_ input: TelegramAttachment) throws -> AttachmentEffect {
        AttachmentEffect(attachment: AttachmentID(rawValue: input.attachmentID), chat: chat, files: files)
    }

    /// The file, as it is.
    public func render(_ file: ToolData) -> ToolOutput { .data(file) }
}

@Generable
public struct TelegramAttachment: Sendable {
    public let attachmentID: String
}

/// Reading an attachment of the chat it was sent in, through the bot that chat is with.
public struct AttachmentEffect: ScopedEffect, Sendable {
    public let name = "attachment"
    public let attachment: AttachmentID
    let chat: ChannelID
    let files: TelegramFiles

    public static func run(in token: borrowing EffectToken<AttachmentEffect>) async throws -> ToolData {
        let (attachment, chat, files) = token.withConfiguration { ($0.attachment, $0.chat, $0.files) }
        return try await files.file(attachment, in: chat)
    }
}

/// Each running Telegram bot's files, by the channel its chats are in.
public actor TelegramFiles {
    public typealias Download = @Sendable (_ fileID: String) async throws -> TelegramFileData

    private var downloads: [ChannelID: Download] = [:]

    public init() {}

    /// The bot whose chats are in `channel`, running: their files are got through it.
    public func register(_ channel: ChannelID, _ download: @escaping Download) {
        downloads[channel] = download
    }

    /// The bot whose chats are in `channel`, stopped.
    public func unregister(_ channel: ChannelID) {
        downloads[channel] = nil
    }

    /// Whether a running bot's chats are in `channel`.
    public func serves(_ channel: ChannelID) -> Bool {
        downloads[channel] != nil
    }

    /// The file `attachment` is, in a chat in `channel`.
    public func file(_ attachment: AttachmentID, in channel: ChannelID) async throws -> ToolData {
        guard let download = downloads[channel] else { throw NoTelegramBot(channel: channel) }
        let file = try await download(attachment.rawValue)
        return ToolData(body: file.body, contentType: file.contentType)
    }
}

/// No bot whose chats are in the channel is running.
public struct NoTelegramBot: Error, Sendable, Equatable, CustomStringConvertible {
    public let channel: ChannelID

    public var description: String { "this chat's Telegram bot isn't running" }
}
