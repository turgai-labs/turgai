import AnyLanguageModel
import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import TurgaiApplication
import TurgaiDomain
import TurgaiHail
import TurgaiPersistence
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct ChatPage: HTMLDocument, Sendable {
    enum Presentation: Sendable {
        case publicChat
        case dashboard
    }

    let user: AuthenticatedUser?
    let profile: TurgaiAgentProfile
    let history: [ConversationHistoryEntry]
    let presentation: Presentation

    init(
        user: AuthenticatedUser,
        profile: TurgaiAgentProfile,
        history: [ConversationHistoryEntry]
    ) {
        self.user = user
        self.profile = profile
        self.history = history
        self.presentation = .dashboard
    }

    init(
        user: AuthenticatedUser,
        profile: TurgaiAgentProfile,
        history: [ConversationHistoryEntry],
        presentation: Presentation
    ) {
        self.user = user
        self.profile = profile
        self.history = history
        self.presentation = presentation
    }

    init(profile: TurgaiAgentProfile, history: [ConversationHistoryEntry]) {
        self.user = nil
        self.profile = profile
        self.history = history
        self.presentation = .publicChat
    }

    private struct HistoryItem: Encodable {
        let role: ConversationHistoryRole
        let text: String
        let html: String
    }

    private var historyJSON: String {
        let items = history.map {
            HistoryItem(
                role: $0.role,
                text: $0.text,
                html: MarkdownRenderer.html(from: $0.text)
            )
        }
        guard let data = try? JSONEncoder().encode(items),
            let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return
            json
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
    }

    var title: String { "Turgai — Chat with \(profile.name)" }
    var head: some HTML { TurgaiHead() }

    private var shellClass: String {
        switch presentation {
        case .publicChat: "chat-shell chat-shell-standalone"
        case .dashboard: "app-shell"
        }
    }

    private var socketPath: String {
        switch presentation {
        case .publicChat: "/chat/live"
        case .dashboard: "/chat/\(profile.id)/live"
        }
    }

    var body: some HTML {
        main(.class("app-page chat-app-page")) {
            div(.class(shellClass)) {
                if let user {
                    AppHeader(user: user, section: .bots)
                }
                div(.class("chat-page")) {
                    if case .dashboard = presentation {
                        div(.class("chat-header")) {
                            div(.class("chat-header-main")) {
                                a(.href("/agents/\(profile.id)"), .class("chat-back")) {
                                    "← \(profile.name)"
                                }
                                h1 { "Chat" }
                            }
                            span(.class("chat-model")) { TurgaiModelPresentation.displayName(for: profile.model) }
                        }
                    }
                    section(
                        .class("chat-messages"),
                        .id("chat-messages"),
                        .init(name: "aria-label", value: "Conversation with \(profile.name)")
                    ) {
                        div(.class("chat-messages-content"), .id("chat-messages-content")) {
                            div(.class("chat-empty chat-loading")) {
                                p { "Restoring your conversation…" }
                            }
                        }
                    }
                    form(.id("chat-composer"), .class("liquid-footer chat-composer")) {
                        label(.for("chat-message"), .class("chat-composer-label")) {
                            "Message \(profile.name)"
                        }
                        div(.class("chat-composer-row")) {
                            textarea(
                                .id("chat-message"),
                                .name("message"),
                                .placeholder("Write a message…"),
                                .autocomplete(.off),
                                .init(name: "rows", value: "1"),
                                .required
                            ) {}
                            button(
                                .type(.submit),
                                .class("button button-accent chat-send"),
                                .init(name: "aria-label", value: "Send message")
                            ) {
                                span(.class("chat-send-icon"), .init(name: "aria-hidden", value: "true")) { "↑" }
                            }
                        }
                    }
                }
            }
            HTMLRaw(
                """
                <script>
                (() => {
                    const messages = document.getElementById("chat-messages");
                    const messageContent = document.getElementById("chat-messages-content");
                    const form = document.getElementById("chat-composer");
                    const input = document.getElementById("chat-message");
                    const socketPath = "\(socketPath)";
                    const socketURL = `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}${socketPath}`;
                    const socket = new WebSocket(socketURL);
                    let assistantMessage;

                    const ChatEventType = Object.freeze({
                        history: "history",
                        user: "user",
                        started: "started",
                        partial: "partial",
                        finished: "finished",
                        failed: "failed",
                        progress: "progress",
                        notice: "notice"
                    });

                    const decodeChatEvent = (value) => {
                        if (!value || typeof value !== "object") return null;
                        if (!Object.values(ChatEventType).includes(value.type)) return null;
                        return {
                            type: value.type,
                            html: typeof value.html === "string" ? value.html : null,
                            messages: Array.isArray(value.messages) ? value.messages : []
                        };
                    };

                    const scrollToBottom = () => {
                        requestAnimationFrame(() => {
                            window.scrollTo({
                                top: document.documentElement.scrollHeight,
                                behavior: "auto"
                            });
                        });
                    };

                    const addMessage = (role, text, html = null) => {
                        const message = document.createElement("div");
                        message.className = `chat-message chat-message-${role}`;
                        const tilt = (Math.random() * 4.8 - 2.4).toFixed(2);
                        message.style.setProperty("--chat-tilt", `${tilt}deg`);
                        const content = document.createElement("div");
                        content.className = "chat-message-content markdown-body";
                        if (html) content.innerHTML = html;
                        else content.textContent = text;
                        message.appendChild(content);
                        messageContent.appendChild(message);
                        messageContent.querySelector(".chat-empty")?.remove();
                        scrollToBottom();
                        return message;
                    };

                    const history = \(historyJSON);
                    history.forEach(({ role, text, html }) => addMessage(role, text, html));
                    const emptyState = messageContent.querySelector(".chat-empty");
                    const showReadyState = () => {
                        if (messageContent.querySelector(".chat-message")) return;
                        if (!emptyState) return;
                        emptyState.classList.remove("chat-loading");
                        emptyState.querySelector("p").textContent = "Start a conversation with \(profile.name).";
                    };
                    scrollToBottom();

                    const showThinking = () => {
                        assistantMessage = addMessage("assistant", "");
                        assistantMessage.classList.add("chat-message-thinking");
                        assistantMessage.querySelector(".chat-message-content").innerHTML = `Thinking<span class="thinking-dots" aria-hidden="true"><span></span><span></span><span></span></span>`;
                    };

                    const showAssistantText = (text, html) => {
                        if (!assistantMessage) assistantMessage = addMessage("assistant", "");
                        const wasThinking = assistantMessage.classList.contains("chat-message-thinking");
                        assistantMessage.classList.remove("chat-message-thinking");
                        const content = assistantMessage.querySelector(".chat-message-content");
                        if (html) content.innerHTML = html;
                        else content.textContent = text || "";
                        if (wasThinking) {
                            assistantMessage.style.setProperty("--chat-bubble-animation", "none");
                            void assistantMessage.offsetWidth;
                            assistantMessage.style.removeProperty("--chat-bubble-animation");
                        }
                        scrollToBottom();
                    };

                    socket.addEventListener("message", (event) => {
                        const update = decodeChatEvent(JSON.parse(event.data));
                        if (!update) return;
                        if (update.type === ChatEventType.user) {
                            addMessage("user", "", update.html);
                        } else if (update.type === ChatEventType.history) {
                            if (!messageContent.querySelector(".chat-message")) {
                                update.messages.forEach(({ role, html }) => addMessage(role, "", html));
                            }
                            showReadyState();
                        } else if (update.type === ChatEventType.started) {
                            showThinking();
                        } else if (update.type === ChatEventType.partial) {
                            showAssistantText(update.text, update.html);
                        } else if (update.type === ChatEventType.finished) {
                            showAssistantText(update.text, update.html);
                            assistantMessage = null;
                        } else if (update.type === ChatEventType.failed || update.type === ChatEventType.notice) {
                            addMessage(
                                "assistant",
                                update.text || "The conversation could not be completed.",
                                update.html
                            );
                            assistantMessage = null;
                        }
                        scrollToBottom();
                    });

                    socket.addEventListener("error", () => {
                        if (!emptyState || messageContent.querySelector(".chat-message")) return;
                        emptyState.classList.remove("chat-loading");
                        emptyState.querySelector("p").textContent = "Could not restore this conversation.";
                    }, { once: true });

                    socket.addEventListener("close", () => {
                        if (emptyState && !messageContent.querySelector(".chat-message")) {
                            emptyState.classList.remove("chat-loading");
                            emptyState.querySelector("p").textContent = "Could not restore this conversation.";
                        }
                        input.disabled = true;
                        input.placeholder = "Chat connection closed";
                    });

                    form.addEventListener("submit", (event) => {
                        event.preventDefault();
                        const text = input.value.trim();
                        if (!text || socket.readyState !== WebSocket.OPEN) return;
                        socket.send(JSON.stringify({ text }));
                        input.value = "";
                        input.focus();
                    });

                    input.addEventListener("keydown", (event) => {
                        if (event.key !== "Enter" || event.shiftKey || event.isComposing) return;
                        event.preventDefault();
                        form.requestSubmit();
                    });
                })();
                </script>
                """
            )
        }
    }
}
