import Elementary
import ElementaryHTMX
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

struct ChatLiveMessage: HTML, Sendable {
    let message: Message
    let turnID: TurnID?
    let liveUpdate: Bool

    init(message: Message, turnID: TurnID?, liveUpdate: Bool = false) {
        self.message = message
        self.turnID = turnID
        self.liveUpdate = liveUpdate
    }

    var body: some HTML {
        let id =
            turnID.map { "turn-\($0.rawValue.uuidString)" }
            ?? "message-\(message.id.rawValue.uuidString)"
        let role = message.role == .user ? "user" : "assistant"
        let liveUpdateClass = liveUpdate ? " chat-message-live-update" : ""
        div(
            .id(id),
            .class("chat-message chat-message-\(role)\(liveUpdateClass)"),
            .hx.swapOOB(.outerHTML)
        ) {
            ChatLiveMessageBody(message: message)
        }
    }
}

struct ChatLiveMessageBody: HTML, Sendable {
    let message: Message

    var body: some HTML {
        div(.class("chat-message-content markdown-body")) {
            HTMLRaw(MarkdownRenderer.html(from: message.text))
        }
    }
}

struct ChatLiveAppendedMessage: HTML, Sendable {
    let message: Message

    var body: some HTML {
        div(.hx.swapOOB(.beforeEnd, "#chat-messages-content")) {
            let id = "message-\(message.id.rawValue.uuidString)"
            let role = message.role == .user ? "user" : "assistant"
            div(
                .id(id),
                .class("chat-message chat-message-\(role)"),
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
        let role = message.role == .user ? "user" : "assistant"
        div(
            .class("chat-message chat-message-\(role)"),
            .init(
                name: "data-conversation-message-id",
                value: message.id.rawValue.uuidString
            )
        ) {
            div(.class("chat-message-content markdown-body")) {
                HTMLRaw(MarkdownRenderer.html(from: message.text))
            }
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
            message: Message(id: .init(), role: .assistant, text: message)
        )
    }
}

enum ChatLiveFragment {
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

    static func partial(_ message: Message, turnID: TurnID) -> String {
        ChatLiveMessage(message: message, turnID: turnID, liveUpdate: true).render()
    }

    static func appendedPartial(_ message: Message, turnID: TurnID) -> String {
        ChatLiveEmptyClear().render()
            + div(.hx.swapOOB(.beforeEnd, "#chat-messages-content")) {
                let id = "turn-\(turnID.rawValue.uuidString)"
                div(.id(id), .class("chat-message chat-message-assistant")) {
                    ChatLiveMessageBody(message: message)
                }
            }.render()
    }

    static func completed(_ message: Message, turnID: TurnID) -> String {
        ChatLiveMessage(message: message, turnID: turnID, liveUpdate: true).render()
            + ChatLiveActivityClear().render()
    }

    static func appendedCompleted(_ message: Message, turnID: TurnID) -> String {
        appendedPartial(message, turnID: turnID) + ChatLiveActivityClear().render()
    }

    static func failed(_ message: String) -> String {
        ChatLiveError(message: message).render() + ChatLiveActivityClear().render()
    }

    static func cleared() -> String {
        ChatLiveActivityClear().render()
    }
}
