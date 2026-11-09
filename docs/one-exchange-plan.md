# One exchange, one record

Proposed, not agreed. A message and the agent's reply to it are kept by the conversation and by the agent, each under its own turn id, and nothing links the two. The missing ⓘ on past replies comes from that. This plan links them, without passing ids down: the agent says which of its turns answered, and the conversation keeps that with the reply.

## One exchange today

You send "What's the weather?" in the Mac app.

1. **The edge** makes a turn id, `539be24d`, and sends the message to the conversation (`PublicChatRoutes.say`, `turnID: .init()`).
2. **The conversation** journals `inbox(.turnStarted)` with the message and the turn id, then asks its agent participant to answer (`ConversationDecision(.receive, in:)`).
3. **The agent participant** hands the message to Hail (`HailConversationPeer.run`).
4. **Hail's agent** opens a turn of its own, `a840aa0c` (`Agent.run`, `case .received: TurnID()`), journals `history.received` with it, and tells the caller only that the input was received: the `received` run update has no id.
5. **Hail** runs the model and journals each step: `history.called`, `history.resulted`.
6. **The participant** passes each step on live, in its scope, under `539be24d` (`AgentParticipant.follow` → `publishLive(.step)`).
7. **Hail** journals `history.replied` and closes its turn.
8. **The conversation** journals `replyQueued` with the reply, then `inbox(.turnCompleted)`, under `539be24d`.
9. **The app**, live, shows the reply with ⓘ: everything it saw came in the participant's scope, under `539be24d`.

You reopen it later. The app gets past turns from Hail's history (`Conversation.turns` → `AgentParticipant.turns` → `peer.history()`), each under Hail's id. No reply says `a840aa0c`, so there's no ⓘ.

## What breaks

- **Past steps can't be found.** Live, the caller's scope ties them to the reply. Afterwards, nothing does: the conversation never learns which of Hail's turns answered.
- **Old steps would disappear anyway.** Past turns are read from the agent's working history, which compaction folds into a summary (`AgentHistory.folding`). After compaction, the ⓘ would go even with a link, though Hail's journal still has every step.

## The design

**The conversation owns what was said**, and its turns: their ids stay its own, made as now.

**The agent owns how it worked**, and its turns: it names them, as now.

**What comes back carries the agent's id.** The `received` run update says which turn it opened, as the journal's `history.received` already does. The participant learns it at the start of its call and keeps it in scope, so a reply and a failure both name the agent's turn, and so do the steps before a failure.

**The conversation keeps the link** with whatever ends its turn: the reply (`replyQueued`) or the failure (`turnFailed`) says which agent turn it came from. That's the conversation's own fact.

**Past turns come from the agent's journal**, not its working history: a projection by turn id, as Hail's request records already are, so compaction never takes a turn's steps away. The server reads it and gives each turn under the conversation's id, through the link, so the app matches past replies exactly as it does live.

**A crash reruns.** If the server stops after the agent answered but before the conversation kept the reply, the conversation asks again, as its `.resume` does now, and the agent closes the cut-off turn, as `interruptedTurns: .close` does now. The agent hears the question twice. The window is small, and that's acceptable.

## What changes

**Hail**, committed, merged into `turgai-integration`, pushed, then norby's pin moved:

1. `AgentRunEvent.received` carries the turn's id.
2. A turns projection over the agent's journal, by turn id, with each turn's input, steps, and outcome, compacted or not.

**Turgai:**

1. `HailModelEvent.started` carries the agent's turn id, mapped from `received`.
2. `AgentParticipant` keeps it in the call's scope, and passes it with the completion or the failure (`ConversationModelEvent`).
3. `PendingConversationReply` keeps the agent's turn id; the inbox's `turnFailed` keeps it when the agent had opened one, and none when the turn failed before it did.
4. `ConversationTurns` reads Hail's projection and gives each turn the conversation's id, through those links.

**Data:** conversations' and their agents' journals reset, as with any changed stored shape until data is kept (see `data-compatibility-plan.md`).
