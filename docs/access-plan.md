# Access

Agreed: who may call what, and who decides. Visibility, what can be *found*, is the next question, and isn't settled here.

## Where it stands

Every decision lives somewhere different, and the one that matters most lives nowhere:

| Decision | Kept |
|---|---|
| Does a user tool need asking before it runs? | the tool's spec file, on the server's disk |
| What may an agent do? | `CompositeAuthority`, hard-coded, built per agent |
| Which tools does an agent have? | nowhere: every agent has every tool |
| May this call run now? | the conversation's memory, not journaled, the answer not kept |
| May this actor be called? | **nowhere: the callee never checks** |

Every check is the caller's. An object on the Mac's node runs whatever reaches it.

## The model

**Everything callable is a distributed actor.** Objects and agents already are. A tool is an API, so it always runs on its provider's side. A tool used only by its own agent stays local, inside that agent. A tool offered to others goes through the **ToolsAPI**, which makes it a distributed actor like any object.

So there's one boundary, the distributed call, and one infrastructure on it:

1. **Who's calling.** The actor system stamps every call with its caller. Code can read it, but never set it, and it's never taken from arguments. CallChain already carries the actor ids.
2. **Who made it.** When an actor is made, the stamp of the call that made it is recorded as its creator.
3. **Who may call it.** Each actor keeps its own list, journaled with it. Only its creator changes it, and changing it is a call too.
4. **The check.** The receiving side checks the stamped caller against the list, before the target runs. It's one place in the actor system, and it covers every actor on every node.

That's B, the actor's own list, rather than A, where holding a reference is the right. With a list, "who may call this" is a value that can be shown, journaled, revoked, and asked to join. That last part is where access requests come in.

## Trust

The stamp is only as good as the node that sends it.

- **Now:** every node is ours, so the stamp is trustworthy. Steps 1–4 can be built without waiting.
- **Later, in SDA:**
  - **mTLS**, so only our nodes can join. Today any process that reaches the port can join, and claim any caller.
  - **A node speaks only for its own actors.** The receiving side also checks that the stamped caller lives on the sending node. mTLS proves which node is talking, not which actor.

Nothing built on 1–4 changes when these land.

## Open

- **Which caller is stamped:** the actor that made the call (the planner object), or who it ultimately acts for (the person at the start of the chain)? This also decides who the creator is when an agent makes an object.
- **Visibility:** what can be found, and by whom, next to who may call.
- **Requests:** asking to join an actor's list, and the creator's answer, built on 3.

## Order

1. Stamp the caller on every call, the same on every node.
2. Record the creator when an actor is made.
3. Each actor's list, and the check on the receiving side.
4. The ToolsAPI: offering a tool as a distributed actor.
5. Requests and answers.
6. In SDA: mTLS, and a node speaking only for its own actors.
