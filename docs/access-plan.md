# Access

Agreed: who may find what, who may call it, and who decides.

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
2. **Who may find it, read it, and write it.** Each actor keeps this with it, journaled. It belongs to the group it was made in, and that group's admins change it. There's no owner.
3. **Each action reads or writes.** The actor's own code says which. For objects, that's the authority attributes in object code. For a tool or an agent, whoever offers it through the ToolsAPI says it.
4. **The check.** The receiving side checks what the actor allows for the action, read or write, before the target runs: the call passes if the scope of whoever started the chain is allowed, or if the object calling it directly is. Otherwise it's a request on behalf of whoever started the chain. It's one place in the actor system, and it covers every actor on every node.

### Who the chain starts with

- **Whoever asked.** Bob asks his agent, the agent calls the planner, and the planner adds to Ann's calendar: Bob needs access at every step. The agent and the planner act for him, and can't do more than he can. If Cat asks the planner, it's checked against Cat.
- **A person** starts it through their participant actor, in the group they came in through.
- **Something running on its own,** such as a timer firing or an object's own task, starts with whoever made it.
- **Objects can be allowed too.** The room's calendar allows the shared booking object to write it. Anyone books through the booking object, which checks for clashes, and its own right is what the calendar checks. Bob isn't allowed on the calendar, so he can't write to it directly.

### Groups, scope, read and write

- **A group has members and admins:** a family, a team, a chat. A role, such as a family's kids, is a group too. Everything belongs to the group it was made in; made alone, that's your group of one.
- **An actor allows read or write,** to groups or to participants. Finding is coarse: everyone, or only some. Something that can be found but not used is what a request is made from.
- **The call carries its scope:** who started it, the group they came in through, and their role there. Bob writes in the family chat, so the call starts as "Bob, in the family, as a parent", put on by the group where he came in. The check compares that with what the actor allows, and never asks anyone. In another chat, Bob isn't in the family for that call. A role changed applies from the next call; a timer or an object's own task gets its group's current role when it starts.

```
family calendar, the family's
  found by:  family
  read:      family.kids       → events(from:to:)
  write:     family.parents    → add(event:), remove(event:)
```

### Requests

A request is a call, and so is the answer. Nothing is special.

- **A kid's agent tries to add an event:** not allowed, so it's a request on the kid's behalf, to the family's admins, the parents.
- **A parent allows it:** a call that changes what the calendar allows. It carries "in the family, as an admin", so it passes the check like any other call.
- **Someone outside asks,** such as Cat from the school: the same, to the admins of the group the thing belongs to. The answer allows Cat, or the school's teachers.

### The Mac

The Mac and its services (calendar, contacts, screen) belong to the group that set the Mac up. Using them goes through two layers:

1. **Ours:** a request to that group's admins, as above.
2. **macOS's own consent:** macOS asks once whether Turgai, the app, may use the calendar or the screen. Only someone at that Mac can answer it, in the system dialog. Until then the call can't run, and the reply says it's waiting for the Mac.

macOS allows the app, not a person. Once it has, who may use the Mac's services is only ours to say.

That's B, what the actor allows, rather than A, where holding a reference is the right. "Who may call this" is a value that can be shown, journaled, revoked, and asked for.

### Outside services

Someone else's API (Google, GitHub, an MCP server) comes in through the ToolsAPI as an actor, and allows read or write like any other.

- **Now:** manual approval only. A call without access is a request, to the admins of the group the service belongs to.
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

Nothing, for now.

## Order

1. Stamp the caller on every call, the same on every node.
2. What each actor allows, changed by its group's admins; actions marked read or write; the call's scope put on by the group it starts in.
3. The check on the receiving side.
4. The ToolsAPI: offering a tool as a distributed actor.
5. Requests and answers, and macOS's consent on the Mac.
6. In SDA: mTLS, and a node speaking only for its own actors.
