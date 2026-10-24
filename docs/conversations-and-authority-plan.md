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

### Objects: what can be found, and what can be used

Two rules, kept apart:

- **Visibility** decides only what can be *found*:
  - **Shared** objects are found by everyone, everywhere in the cluster. Made objects and the agents asked as objects are shared, for now.
  - An object **owned** by a person is found only by that person: by their conversation's agent, and by code in objects they own.
  - **An agent asked as an object** works for no one person, so it finds only shared objects.
- **Authority** decides what can be *used*, on every call. Not finding something isn't protection: a reference passed as an argument, or returned by a result, can still be called. So every call is checked: the exact calling party needs a grant from the object's owner, or must be the owner.
  - Beneath that, each call has to carry **who is calling**, in a form that can't be forged. That's mTLS on the cluster, then a caller context on every call. Until then, any local process can call any actor.

**Example.** Ann owns her calendar object, and the shared planner calls `events(from:to:)` on it:

1. The planner has no grant on Ann's calendar, so the call becomes a **request**, asked of Ann, who owns it.
2. Ann allows it. The grant is to the planner exactly: `.action(calendar, events) · read · to: planner · by: Ann`, once or until she revokes it.
3. If Ann gives someone `decide` on her calendar, that person can grant access to others for her, without owning it.

## Open

1. Two actor kinds (room + agent participant), or one?
2. Can a conversation have more than one agent?
3. When B is called by A, does A's lack of a grant limit B? This also covers people asking an agent, and timers and announcements, which have no caller. Ann asking the shared planner is this case: whether the planner's calls run with Ann's grants. For now, a call is checked against the party whose code makes it.
4. Groups: how families and companies own things and decide, beyond "a group is a party".

## Order

1. Settle 1–2, then extract the room and the agent participant from `Conversation` as pure domain values, with the same behaviour.
2. Give the conversation its own id, members and links.
3. Move memory and commands to their owners.
4. Authority: Hail's gate, the requests and grants, then folders and actions, system access through the Mac, and revoking.
