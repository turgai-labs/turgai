# Conversations and authority

A plan, not yet agreed. Authority can't be settled until conversations are, because permission requests need to know who is in a conversation, who asked, and who decides.

## Why

Today, four separate mechanisms say what may happen:

- **Hail's `Authority`** allows or denies each effect, synchronously. It can't ask anyone.
- **`ToolApproval`** asks yes or no for user tools, in strings. It asks **whoever is connected to the conversation**. In a group chat, a kid could approve their own request.
- **Calendar, Contacts and Reminders** call `requestAccess` themselves. Only the Mac can show that dialog; from Telegram the call just fails.
- **`FileTool`** has one fixed workspace and no way to ask for another folder.

And `Conversation` does eight jobs at once (below), so there's no place that says who is in a conversation and who decides.

## Conversation today

| | What it does | Where |
|---|---|---|
| A | Its identity *is* one channel's address: a Telegram chat or an app session | `ConversationID(channel:externalAddress:)` |
| B | A durable inbox: duplicate messages dropped, queued while busy, one turn at a time, status, failure, reset | `ConversationState`, the reducer |
| C | Runs the agent: the role picked per turn by channel routing; the Hail agent is `AgentID(role, context: conversation)` | `startModel`, `HailAgentAdapter.peer` |
| D | After a turn: memory extraction, `User.recordObservation` | inside `startModel` |
| E | Delivery: replies kept until a connection takes them, echoes, the agent's phases | `pendingReplies`, `followActivity`, `liveState` |
| F | Live connections | `connections` |
| G | Approvals | `requestApproval` |
| H | Commands: memory, forget, context, diagnostics, reminders, tasks, clear failure, notify | `show…`, `cancel…`, `pause…` |

## The split: by who owns each rule

The shape of swift-chat: a **room** plus **participants**.

1. **`Conversation`, the room.** Its own id, its members, and its messages in order.
   - Events: `joined(Participant)`, `left`, `linked(Link)`, `unlinked`, `said(Message, by: Participant)`.
   - Invariants: only members speak; messages have one order.
   - Its history is what gets delivered. A link catches up from it, so `pendingReplies` goes away.
2. **An agent participant per agent member.** Owns B and C: its inbox, one turn at a time, failure, its configuration.
   - It receives `said` from the room, and its reply is `said(by: .agent)`.
   - It's today's `AgentID(role, context: conversation)` as its own actor.
   - It's separate because two agents in one room must not block each other.
3. **Links**, Telegram and the app. They own F and which Telegram chat is which conversation. A Telegram group is a conversation whose members are its people, plus the agent. People need no actor: their side is links.

Leaving the room:
- **D, memory:** reacts to `said`, in Memory.
- **H, commands:** go to their owners: memory to `User`, tasks and reminders to `Schedule`, context and diagnostics to the agent participant.
- **G, approvals:** replaced by permission requests (below).

Hail is not changed by the split. Hail already runs one turn at a time per agent: it chains turns, and its history refuses a second open turn. The durable inbox, delivery and failure handling are Turgai's policy.

## Authority, after the split

- **Party:** a person or a group. Agents and objects are owned by a party.
- **Resource**, which has an owner:
  - a folder on a device;
  - a service on a device: calendar, contacts, screen, accessibility…;
  - an object's action.
- **Access:** read, change, use, decide (decide = may grant it to others).
- **Grant:** to exactly the party that asked: an agent, an object or a person.
- **Request:** its own aggregate (`open`, `granted`, `refused`, `withdrawn`, `expired`).
  - It's asked of whoever can decide: the owner, or someone holding `decide`.
  - That's worked out from ownership, never configured. A kid is just someone who owns less.
  - It's shown through **the owner's own links**, never to whoever is connected.
- **Hail's gate** gets a third answer, "needs", and waits for the answer; Hail stays generic.
- **An answer within a short window** continues the call in the same turn. Otherwise the call returns "waiting for …", and the later answer arrives as a notice that starts a turn.
- **A device's own consent** (macOS) is one more step before a grant finishes, only possible on that device.
- **The Mac app, the web and Telegram** only render requests, and all three can revoke.
## Open

1. Two actor kinds (room + agent participant), or one?
2. Can a conversation have more than one agent?
3. When B is called by A, does A's lack of a grant limit B? This also covers people asking an agent, and timers and announcements, which have no caller.
4. Groups: how families and companies own things and decide, beyond "a group is a party".

## Order

1. Settle 1–2, then extract the room and the agent participant from `Conversation` as pure domain values, with the same behaviour.
2. Give the conversation its own id, members and links.
3. Move memory and commands to their owners.
4. Authority: Hail's gate, the requests and grants, then folders and actions, system access through the Mac, and revoking.
