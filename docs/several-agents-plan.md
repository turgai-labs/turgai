# Several agents in a conversation

Agreed: a conversation can have several agents. Each has its own inbox, one is the default, and a message goes to the default or to the agents it names. Built after `one-exchange-plan.md`, whose run updates and reply links already carry each agent's turn.

## Today

A conversation refuses a second agent (`ConversationRefusal.oneAgentForNow`, `ConversationState.adding`), because the rest assumes one:

- **One inbox.** `ConversationState.inbox` holds the messages waiting and the one being answered, so one turn runs at a time across the conversation.
- **"The" agent is any agent.** `Conversation.agent()` returns `state.agents.first`, and `agents` is a `Set`: with two, which one is unspecified. Past turns are read from it (`turns(askedBy:)`), and a reply with no answering agent is put down to it.
- **Who answers is yes or no.** `ConversationState.answers(_:)` says whether *the* agent answers a message: when it's said to no one, or to an agent among others.
- **The edge decides for the conversation.** It makes each message's turn id (`turnID: .init()` in `PublicChatRoutes.say`, Telegram, schedules) and looks up the one answering agent's model (`TurgaiConnections`, `answeringAgent()`), so one message can only start one turn.
- **The app follows one turn.** `ChatFeature.State.turn` is one: one reply typed, one "Thinking…".

## The design

**A default agent, stored.** The conversation starts with its agent as its default (`.started(in:answeredBy:)`), and the default can be changed (`.defaultAgentChosen`). It's a fact of the conversation, not the first of a set. The default doesn't leave while it's the default.

**An inbox per agent.** `ConversationState.inboxes: [AgentProfileID: AgentInbox]`, each as `AgentInbox` is now: one message answered at a time, the rest waiting. One agent's turn doesn't hold another's up. What waits on an access request is its agent's, as `PendingConversationMessage.agentRole` already says.

**Routing.** `ConversationState.answering(_ message:) -> [AgentProfileID]`:

- said to no one: the default agent;
- said to agents, by `@`, with people or without: those agents;
- said only to people: none, and it's kept as said, as now.

**The conversation names its turns.** One message can start several turns, one per agent, so the edge stops making turn ids. The conversation makes one per agent it routes to, and stamps it on the command, as it stamps dates (`.receive(message:, turns: [AgentProfileID: TurnID])`).

**Each agent's own model.** The conversation reads each answering agent's model snapshot from its profile when it starts the turn, instead of the edge passing one (`TurnConfiguration` goes).

**Replies are credited to their agent.** `replyQueued` comes from an agent's inbox, so its author is that agent, never a guess.

**The app follows turns by id.** `ChatFeature.State.turns`, by turn id: each with its phase, activity and reply so far, patched by the turn events' `turnID`. Each agent typing shows as its own row, named, until it's said. `@` suggests the space's agents beside its people, and mentioning one not in the conversation brings it in, as for people.

## What changes

**Domain**, `TurgaiDomain/Conversation.swift`:

1. `ConversationState`: `defaultAgent`, `inboxes`; `answering(_:)` replaces `answers(_:)`; `oneAgentForNow` goes.
2. `.started(in:answeredBy:)` and `.defaultAgentChosen(AgentProfileID)`; `.inbox(AgentProfileID, AgentInboxEvent)`.
3. `ConversationAction.receive(message:, turns:)`; `modelCompleted` and `modelFailed` find their inbox by turn.

**Application:**

1. `Conversation.send` routes, makes a turn id per answering agent, and resolves each agent's model; `agent()` goes, and `turns(askedBy:)` reads every agent's.
2. The edges (`PublicChatRoutes`, Telegram, `Schedule`) send messages without turn ids.
3. `TurgaiConnections.answeringAgent()` goes.

**Mac app:** turns in flight by id in `ChatFeature`; agents in `@` suggestions, from the space's agents.

**Data:** conversations' journals reset, as with any changed stored shape until data is kept.
