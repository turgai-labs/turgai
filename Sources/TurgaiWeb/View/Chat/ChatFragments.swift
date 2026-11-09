import Elementary
import ElementaryHTMX
import Foundation
import TurgaiModels

struct ChatLiveActivity: HTML, Sendable {
    let text: String

    var body: some HTML {
        div(.id("conversation-activity"), .hx.swapOOB(.outerHTML), .class("chat-activity")) {
            span { text }
            span(.class("thinking-dots"), .init(name: "aria-hidden", value: "true")) {
                span {}
                span {}
                span {}
            }
        }
    }
}

struct ChatLiveActivityClear: HTML, Sendable {
    var body: some HTML {
        div(.id("conversation-activity"), .hx.swapOOB(.outerHTML), .class("chat-activity")) {}
    }
}

/// A turn's reply, in the place shown for the turn: what's typed so far, or what it said.
struct ChatLiveReply: HTML, Sendable {
    let turnID: TurnID
    let content: ChatLiveMessageBody

    var body: some HTML {
        div(
            .id("turn-\(turnID.rawValue.uuidString)"),
            .class("chat-message chat-message-assistant chat-message-live-update"),
            .hx.swapOOB(.outerHTML)
        ) {
            content
        }
    }
}

extension HTML {
    /// The class of `message`'s bubble: the viewer's own on the right, someone else's on the left
    /// with their name, the agent's on the left.
    static func kind(of message: Message) -> String {
        switch (message.role, message.author) {
        case (.user, nil): "chat-message-user"
        case (.user, _?): "chat-message-other"
        case (.assistant, _): "chat-message-assistant"
        }
    }
}

struct ChatLiveMessageBody: HTML, Sendable {
    /// Who wrote it, when it's a person the viewer is shown the name of.
    let author: String?
    let text: String

    init(message: Message) {
        self.author = message.role == .user ? message.author?.name : nil
        self.text = message.text
    }

    init(reply: ReplySoFar) {
        self.author = nil
        self.text = reply.text
    }

    var body: some HTML {
        if let author {
            div(.class("chat-message-author")) { author }
        }
        div(.class("chat-message-content markdown-body")) {
            HTMLRaw(MarkdownRenderer.html(from: text))
        }
    }
}

struct ChatLiveAppendedMessage: HTML, Sendable {
    let message: Message

    var body: some HTML {
        div(.hx.swapOOB(.beforeEnd, "#chat-messages-content")) {
            let id = "message-\(message.id.rawValue.uuidString)"
            div(
                .id(id),
                .class("chat-message \(Self.kind(of: message))"),
                .init(
                    name: "data-conversation-message-id",
                    value: message.id.rawValue.uuidString
                )
            ) {
                ChatLiveMessageBody(message: message)
            }
        }
    }
}

struct ChatLiveEmptyClear: HTML, Sendable {
    var body: some HTML {
        div(.id("chat-empty"), .hx.swapOOB(.delete)) {}
    }
}

struct ChatLiveHistoryMessage: HTML, Sendable {
    let message: Message

    var body: some HTML {
        div(
            .class("chat-message \(Self.kind(of: message))"),
            .init(
                name: "data-conversation-message-id",
                value: message.id.rawValue.uuidString
            )
        ) {
            ChatLiveMessageBody(message: message)
        }
    }
}

struct ChatLiveHistory: HTML, Sendable {
    let messages: [Message]

    var body: some HTML {
        div(
            .id("chat-messages-content"),
            .class("chat-messages-content"),
            .hx.swapOOB(.outerHTML, "#chat-messages-content")
        ) {
            if messages.isEmpty {
                div(.class("chat-empty"), .id("chat-empty")) {
                    p { "No messages yet. Say hello." }
                }
            } else {
                for message in messages {
                    ChatLiveHistoryMessage(message: message)
                }
            }
        }
    }
}

struct ChatLiveError: HTML, Sendable {
    let message: String

    var body: some HTML {
        ChatLiveAppendedMessage(
            message: Message(id: .init(), role: .assistant, text: message, at: Date())
        )
    }
}

/// Someone asked the conversation's admins for access; the answer goes back over the socket, and
/// only an admin's counts.
struct ChatLiveAccessRequest: HTML, Sendable {
    let request: AccessRequest

    var body: some HTML {
        div(.hx.swapOOB(.beforeEnd, "#chat-messages-content")) {
            div(
                .id("access-\(request.id.uuidString)"),
                .class("chat-message chat-message-assistant chat-access")
            ) {
                p { strong { "Allow this?" } }
                p(.class("chat-access-request")) { code { request.request } }
                div(.class("chat-access-actions")) {
                    answer(.no, label: "No", style: "button")
                    answer(.once, label: "Once", style: "button")
                    answer(.always, label: "Always", style: "button")
                    answer(.everyone, label: "Everyone", style: "button button-accent")
                }
            }
        }
    }

    private func answer(_ answer: AccessAnswer, label: String, style: String) -> some HTML {
        form(.ws.send, .class("chat-access-answer")) {
            input(.type(.hidden), .name("command"), .value("answer"))
            input(.type(.hidden), .name("id"), .value(request.id.uuidString))
            input(.type(.hidden), .name("answer"), .value(answer.rawValue))
            button(.type(.submit), .class(style)) { label }
        }
    }
}

/// Replaces an answered access request with its answer.
struct ChatLiveAccessAnswered: HTML, Sendable {
    let requestID: UUID
    let answer: AccessAnswer

    var body: some HTML {
        div(
            .id("access-\(requestID.uuidString)"),
            .class("chat-message chat-message-assistant chat-access"),
            .hx.swapOOB(.outerHTML)
        ) {
            p {
                switch answer {
                case .once: "Allowed once."
                case .always: "Allowed from now on."
                case .everyone: "Allowed for everyone here from now on."
                case .no: "Not allowed."
                }
            }
        }
    }
}

enum ChatLiveFragment {
    static func accessRequested(_ request: AccessRequest) -> String {
        ChatLiveEmptyClear().render() + ChatLiveAccessRequest(request: request).render()
    }

    static func accessAnswered(_ requestID: UUID, answer: AccessAnswer) -> String {
        ChatLiveAccessAnswered(requestID: requestID, answer: answer).render()
    }

    static func history(_ messages: [Message]) -> String {
        ChatLiveHistory(messages: messages).render()
    }

    static func accepted(_ message: Message) -> String {
        ChatLiveEmptyClear().render() + ChatLiveAppendedMessage(message: message).render()
    }

    static func started() -> String {
        ChatLiveActivity(text: "Thinking").render()
    }

    static func phase(_ phase: ConversationPhase) -> String {
        ChatLiveActivity(text: phase == .thinking ? "Thinking" : "Writing").render()
    }

    static func status(_ text: String) -> String {
        ChatLiveActivity(text: text).render()
    }

    static func partial(_ reply: ReplySoFar, turnID: TurnID) -> String {
        ChatLiveReply(turnID: turnID, content: ChatLiveMessageBody(reply: reply)).render()
    }

    static func appendedPartial(_ reply: ReplySoFar, turnID: TurnID) -> String {
        appended(ChatLiveMessageBody(reply: reply), turnID: turnID)
    }

    static func completed(_ message: Message, turnID: TurnID) -> String {
        ChatLiveReply(turnID: turnID, content: ChatLiveMessageBody(message: message)).render()
            + ChatLiveActivityClear().render()
    }

    static func appendedCompleted(_ message: Message, turnID: TurnID) -> String {
        appended(ChatLiveMessageBody(message: message), turnID: turnID) + ChatLiveActivityClear().render()
    }

    /// `content` as a turn's reply, after the messages.
    private static func appended(_ content: ChatLiveMessageBody, turnID: TurnID) -> String {
        ChatLiveEmptyClear().render()
            + div(.hx.swapOOB(.beforeEnd, "#chat-messages-content")) {
                div(.id("turn-\(turnID.rawValue.uuidString)"), .class("chat-message chat-message-assistant")) {
                    content
                }
            }.render()
    }

    static func failed(_ message: String) -> String {
        ChatLiveError(message: message).render() + ChatLiveActivityClear().render()
    }

    static func cleared() -> String {
        ChatLiveActivityClear().render()
    }
}
