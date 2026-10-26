# Access

Agreed: who may read what, who may write it, and who decides.

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
2. **Who may read it, and who may write it.** Each actor keeps this with it, journaled. A new one is its maker's alone; whoever can write it shares it. There's no owner, and nobody overrides it.
3. **The check.** The receiving side checks what the actor allows for the call, reading or writing, before the target runs: the call passes if the scope of whoever started the chain is allowed, or if the object calling it directly is. Otherwise it's a request on behalf of whoever started the chain. It's one place in the actor system, and it covers every actor on every node.

### Who the chain starts with

- **Whoever asked.** Bob asks his agent, the agent calls the planner, and the planner adds to Ann's calendar: Bob needs access at every step. The agent and the planner act for him, and can't do more than he can. If Cat asks the planner, it's checked against Cat.
- **A person** starts it through their participant actor, in the group they came in through.
- **Something running on its own,** such as a timer firing or an object's own task, starts with whoever made it.
- **Objects can be allowed too.** The room's calendar lets the shared booking object read it. Anyone books through the booking object, which checks for clashes, and its own right is what the calendar checks. Bob isn't allowed on the calendar, so he can't book on it directly.

### Groups, scope, reading and writing

- **Two levels, writing including reading:** reading it is using it, calling its actions; writing it is changing it, its code, its name, removing it, and who may do what. Who can see it exists is visibility, a separate question.
- **A new object is its maker's alone:** only they read and write it, until they share it. Dad's object for adults stays his. One Turgai makes itself, such as the Mac's or a demo's, is read by everyone.
- **Whoever can write it shares it:** with everyone, a group, a group's admins, a person, or an object. A group's admins have no say over a member's object unless it's shared with them. A role, such as a family's kids, is a group too; someone joining a group gets its access, and someone leaving loses it.
- **The call carries its scope:** who started it, the group they came in through, and their role there. Bob writes in the family chat, so the call starts as "Bob, in the family, as a parent", put on by the group where he came in. The check compares that with what the actor allows, and never asks anyone. In another chat, Bob isn't in the family for that call. A role changed applies from the next call; a timer or an object's own task gets its group's current role when it starts.

```
family calendar, made by Ann, shared
  read:   family             → events(from:to:), add(event:)
  write:  family's admins    → its code, its name, who may read it
```

### Requests

A request is a call, and so is the answer. Nothing is special.

- **A kid's agent tries to use something it may not read:** a request on the kid's behalf, to whoever can write it.
- **One of them allows it:** a call that changes what it allows, a write. Their call carries their scope, so it passes the check like any other call.
- **Someone outside asks,** such as Cat from the school: the same, to whoever can write it. The answer lets Cat, or the school's teachers, read it.
- **Whoever can write it asks themselves:** they answer it themselves. It's still a request and an answer, so it's journaled like any change.

**Once or always.**

- **Once** runs what's waiting, and nothing after. What the thing allows doesn't change.
- **Always** changes what the thing allows, for that participant or their group, until whoever can write it takes it back.

**Waiting doesn't stop the chat.**

- The call returns at once, truthfully: it asked the family's parents. The agent says so and the turn ends.
- The request holds the waiting call, not the agent. When it's allowed, the request runs the call itself, with the original scope, and the result arrives in the conversation as a message that starts a turn. A refusal arrives the same way.
- A quick answer, such as an admin answering themselves, goes the same way: the result is just the next message.

**One request per person, thing and level.** The kid asking ten times is one request. The same call again (same arguments, compared as values) joins the waiting one; different calls wait under it too, and the parents see one request with a count. The answer covers them all. Asking again after a refusal opens a new request.

**It survives its node.** A request is its own virtual, event-sourced actor: asked, then allowed or refused, then ran.

- Died while waiting: it replays to asked, and waits.
- Died after allowed, before the call ran: it replays to allowed, and runs it.
- Died while the call ran: ran was never recorded, so it runs again. The call is at least once: one that sends or pays carries its own id, so its provider can tell a repeat.

### The Mac

The Mac's services (calendar, contacts, screen) go through two layers:

1. **Ours:** what the service allows, and a request to whoever can write it, as above.
2. **macOS's own consent:** macOS asks once whether Turgai, the app, may use the calendar or the screen. Only someone at that Mac can answer it, in the system dialog. Until then the call can't run, and the reply says it's waiting for the Mac.

macOS allows the app, not a person, and has no once: allowed lasts until switched off in System Settings (checked on macOS 27.2). Once it has, who may use the Mac's services is only ours to say, and our once applies only to our layer.

An admin at the Mac answers both, one after the other, on the same screen: ours in the Mac app, then the system dialog. Answering from elsewhere, ours is done there and macOS's waits for someone at the Mac.

That's B, what the actor allows, rather than A, where holding a reference is the right. "Who may call this" is a value that can be shown, journaled, revoked, and asked for.

### Outside services

Someone else's API (Google, GitHub, an MCP server) comes in through the ToolsAPI as an actor, and allows reading and writing like any other.

- **Now:** manual approval only. A call without access is a request, to whoever can write the service.
- **Later, with the first service that has its own auth:** an admin connects it once, through the service's own OAuth, and its token is kept with the actor. Agents never see it.
- **No tokens of our own.** Inside, the call chain already says who's calling.

## Trust

The stamp is only as good as the node that sends it.

- **Now:** every node is ours, so the stamp is trustworthy. Steps 1–4 can be built without waiting.
- **Later, in SDA:**
  - **mTLS**, so only our nodes can join. Today any process that reaches the port can join, and claim any caller.
  - **A node speaks only for its own actors.** The receiving side also checks that the stamped caller lives on the sending node. mTLS proves which node is talking, not which actor.

Nothing built on 1–4 changes when these land.

## Open

- **Who writes Turgai's own objects,** such as the Mac's services: whoever set the Mac up, rather than everyone.

## Order

1. Stamp the caller on every call, the same on every node.
2. What each actor allows: read, write; a new one its maker's alone; changed by whoever can write it.
3. The check on the receiving side.
4. The ToolsAPI: offering a tool as a distributed actor.
5. Requests and answers, and macOS's consent on the Mac.
6. In SDA: mTLS, and a node speaking only for its own actors.
