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
2. **Who may find it, read it, write it, and be its admin.** Each actor keeps these lists with it, journaled. Whoever makes it starts as its admin; after that, only the lists say anything. There's no owner.
3. **Each action reads or writes.** The actor's own code says which. For objects, that's the authority attributes in object code. For a tool or an agent, whoever offers it through the ToolsAPI says it.
4. **The check.** The receiving side checks the list for the action's level, before the target runs: the call passes if whoever started the chain is on it, or if the object calling it directly is. Otherwise it's a request on behalf of whoever started the chain. It's one place in the actor system, and it covers every actor on every node.

### Who the chain starts with

- **Whoever asked.** Bob asks his agent, the agent calls the planner, and the planner adds to Ann's calendar: Bob needs access at every step. The agent and the planner act for him, and can't do more than he can. If Cat asks the planner, it's checked against Cat.
- **A person** starts it through their participant actor, in the group they came in through.
- **Something running on its own,** such as a timer firing or an object's own task, starts with whoever made it.
- **Objects can be on lists too.** The room's calendar lists the shared booking object as allowed to write it. Anyone books through the booking object, which checks for clashes, and its own right is what the calendar checks. Bob isn't on the calendar's list, so he can't write to it directly.

### Finding, and three levels

- **Finding is coarse:** everyone, or only some. Something that can be found but not used is what a request is made from.
- **Three levels, each including the one before:**
  - **read:** the actions that read;
  - **write:** the actions that write;
  - **admin:** changes the lists, and answers requests.
- **Lists name people, objects, or groups.** A role, such as a family's kids, is a group too. Someone joining a group gets its access, someone leaving loses it, and the lists that name the group don't change.
- **The call carries its scope.** Bob writes in the family chat: his participant is in the family, so the call starts as "Bob, in the family, as a parent", put on by the group where he came in. The check compares that with its lists, and never asks anyone. In another chat, Bob isn't in the family for that call. A role changed applies from the next call; a timer or an object's own task gets its group's current role when it starts.

```
family calendar
  found by:  family
  read:      family.kids       → events(from:to:)
  write:     family.parents    → add(event:), remove(event:)
  admin:     Ann, Bob
```

A kid's agent reads the calendar. When it tries to add an event, it's a request, and Ann or Bob answers it.

That's B, the actor's own list, rather than A, where holding a reference is the right. With a list, "who may call this" is a value that can be shown, journaled, revoked, and asked to join. That last part is where access requests come in.

### Outside services

Someone else's API (Google, GitHub, an MCP server) comes in through the ToolsAPI as an actor, with lists like any other. They decide who may use it.

- **Now:** manual approval only. A call without access is a request, and the right admins answer it.
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

- **Requests:** asking to join an actor's list, and its admins' answer.

## Order

1. Stamp the caller on every call, the same on every node.
2. Each actor's lists, whoever makes it starting as admin; actions marked read or write; the call's scope put on by the group it starts in.
3. The check on the receiving side.
4. The ToolsAPI: offering a tool as a distributed actor.
5. Requests and answers.
6. In SDA: mTLS, and a node speaking only for its own actors.
