# Turgai: continuity through persistent AI objects

> Draft. A technical essay on the object model behind Hail and Turgai, its implementation, and the questions that remain open.

An agent may spend many model calls on the same task. Between those calls, it needs to keep track of decisions, tool results, and work still in progress. The task may continue after its context window fills or the application restarts. What holds that work together, and what does it mean for the same agent to continue?

Objects offer a useful starting point. An object gives state an owner and exposes operations through which other parts of a system can work with it. Giving that object a persistent identity lets its lifetime extend beyond a running instance. Applied to agents, this provides a way to connect model execution, memory, and recovery while keeping their responsibilities explicit.

## 1. Objects, communication, and continuity

### Giving state an owner

An object gives a name and an interface to a responsibility. Consider an account: its balance matters together with the operations that may change it and the conditions under which those operations are valid. A deposit asks the account to make a transition. The caller does not need to know how the account represents its balance, but it does need to know what a successful deposit means.

```text
 caller                       Account
   |                     +------------------+
   +-- deposit(100) ---->| balance: 500     |
                         | rules: ...       |
                         +--------+---------+
                                  |
                           accepted transition
                                  |
                                  v
                            balance: 600
```
*Figure 1 — An object gives state an owner and defines the operations and rules that may change it.*

This is a useful design abstraction before choosing a language or storage mechanism. It lets us ask who may change a value, who must enforce an invariant, and which facts callers may rely on. Encapsulation makes those decisions local to a responsibility. It does not, by itself, make the account concurrent or persistent; those are additional properties that require their own mechanisms.

### Collaboration and actors

Once responsibilities have owners, a larger operation becomes a collaboration between objects. One object sends another a request and uses its response without taking control of its internal state. The interface describes their relationship, allowing the implementation on either side to evolve. This is also where failures become part of the design: a request may be rejected, delayed, or left with an uncertain outcome, and its caller needs a defined way to proceed.

```text
 +-------------+      request       +-------------+
 | Object A    | -----------------> | Object B    |
 | own state   | <----------------- | own state   |
 +------+------+      result        +-------------+
        |
        | another request
        v
 +-------------+
 | Object C    |
 | own state   |
 +-------------+
```
*Figure 2 — Objects compose through requests and results while retaining separate ownership of state.*

The actor model gives this collaboration an explicit concurrency discipline. Actors process messages, maintain private state, and communicate with other actors. Separate activities can progress without their callers directly coordinating access to shared mutable variables. Reasoning about the system then involves both the transitions within an actor and the messages between actors.

Isolation does not make a collaboration atomic. Two actors may observe events at different times, and a multi-step operation can fail after only some participants have acted. Ordering, acknowledgement, and retry policies still matter. The value of the boundary is that these responsibilities can be assigned and examined instead of being implicit in shared state.

### Continuing after interruption

A running object has an in-memory instance; a durable object also has a logical identity and enough persisted information for another instance to continue its work. These lifetimes need not coincide. An account can remain the same account after a server restarts, provided that its accepted changes survive and subsequent requests refer to the same logical identity.

```text
       before interruption               after recovery
     +--------------------+           +--------------------+
     | instance of A      |           | new instance of A  |
     | accepted work      |           | recovered work     |
     +---------+----------+           +----------+---------+
               |                                 ^
               v                                 |
         persisted information ------------------+
               logical identity: A
```
*Figure 3 — Durability preserves a logical object's continuity across different running instances.*

The difficult question is what continuation means for unfinished work. A recovered object must distinguish an operation that was never accepted, one still in progress, and one completed but not yet acknowledged. Persisting values alone may not preserve those distinctions. The design must identify the decisions that matter and define how external effects can be retried. Objects and message passing have a long history in object-oriented programming and actor systems; durability adds the requirement that their meaning survive the loss of a running instance.

## 2. The LLM as part of a persistent object

### What continues between invocations?

A model invocation receives a finite input and produces output. An agent carrying out a task over several invocations needs continuity around those calls: which task it is working on, what has already happened, which tools it may use, and whether an earlier operation finished. When these responsibilities belong to a persistent object, callers can address that object again without rebuilding its lifecycle from temporary variables.

“Small” here describes the object's responsibility and public interface. Its history may become large, and its implementation may contain substantial machinery. A focused interface can still offer a simple operation such as accepting a request and returning a result, while the object manages the model calls, tool activity, and state transitions required to complete it.

```text
                 request to agent A
                         |
              +----------v-----------+
              | persistent Agent A   |
              | identity and history |
              | task and turn state  |
              | working context      |
              +-----+----------+-----+
                    |          |
                    v          v
                  model      tools
```
*Figure 4 — An agent's identity and recorded work persist around model invocations and tool operations.*

This boundary allows the model to be replaced while preserving the agent's identity and history, although model behaviour and input compatibility still require evaluation. It also separates durable information from the material selected for a particular invocation. The active prompt is a working view of the task. A change to that view, including compaction, need not imply that the agent has become a different object or that its earlier work has ceased to exist.

### Composing agents

A persistent agent can participate in a larger task through the same request-and-result relationship as another object. A coordinator might ask a research agent for evidence and pass the resulting findings to a planning agent. Each specialist can retain the history relevant to its responsibility, while the coordinator owns the decision about how their results contribute to the overall task.

```text
                    +-------------------+
                    | Coordinator       |
                    | task and decisions|
                    +---------+---------+
                              |
                 +------------+------------+
                 |                         |
                 v                         v
       +------------------+      +------------------+
       | Research agent   |      | Planning agent   |
       | evidence         |      | proposed actions |
       | own context      |      | own context      |
       +------------------+      +------------------+
```
*Figure 5 — Separate agents exchange selected results under a coordinator's task policy; their working contexts remain distinct.*

Such a division is useful when responsibilities need different tools, permissions, context, or lifetimes. It also introduces coordination costs, additional model calls, and partial failures. A deterministic operation may be better expressed as an ordinary function or tool. The object model makes agent composition possible, but it does not establish that adding agents improves a task's outcome.

### Memory beyond an agent's context

Memory needs an owner just as task execution does. An agent's working context may contain temporary hypotheses, while a user's lasting preference should remain useful across unrelated tasks. Keeping both in one transcript makes their different lifetimes difficult to express. A separate memory object can retain selected facts and their provenance, then supply relevant material to whichever agent is authorized to use it.

This creates explicit forms of sharing: private agent context, deliberately exchanged task material, and longer-lived personal or application memory. An agent can receive a fact without receiving the entire conversation in which it was learned. The same distinction gives forgetting and correction a place in the design, although implementing them requires policies for derived copies and delayed work as well as the original record.

## 3. Expressing the model in Swift

### Language support for the boundaries

Swift provides direct representations for several parts of this design. Value types describe messages and state transitions, protocols describe capabilities, and actors isolate mutable state. Distributed actors add declared operations and actor identities whose invocation is mediated by an actor system. Together, these features let the agent's interface and concurrency boundary appear in the language model rather than existing only as application conventions.

There are limits to what this establishes. Swift actors may interleave operations when execution suspends, so isolation does not serialize an entire sequence of model and tool calls. A harness still needs an explicit policy for concurrent requests. Structured concurrency helps manage the lifetime of a run and its child tasks, but recovering that run after process failure requires information stored beyond those tasks.

### Virtual identity and persistence

Virtual actors and persistence supply additional runtime behaviour. A virtual-actor system associates a logical identity with an active instance and can activate an instance when that identity is resolved. Persistence allows the instance's state to be reconstructed. These capabilities are built on top of the language facilities; declaring a distributed actor alone does not provide durable activation or recovery.

In an event-sourced design, a journal records accepted state changes and a reducer reconstructs state from those events. A snapshot checkpoints that state so recovery can load it and replay the remaining journal entries. The snapshot reduces reconstruction cost, while the retained journal provides the history. This machinery still needs application rules for incomplete work: replay can reveal that a request was running, but the system must decide whether to retry it, reconcile an external effect, or report failure.

### Supplying capabilities through plugins

A reusable harness needs access to models, tools, storage, and other resources, but different applications make different choices about them. Protocols and plugin interfaces allow those choices to be supplied at defined points. The harness can execute a tool under a supplied authority policy or request a workspace from the host without owning the application's entire permission model or filesystem layout.

```text
       application
       users, memory, delivery, policy
                     |
          supplied capabilities
                     v
       agent harness
       model turns, tools, context
                     |
                     v
       runtime support
       actor identity, isolation, persistence
```
*Figure 6 — Language and runtime facilities support the harness, while application-supplied capabilities determine how it participates in a product.*

The resulting design gives each extension a scope. Replacing a model provider changes how inference is performed; changing a compaction policy changes how context is prepared. Neither change inherently requires a different user identity or delivery lifecycle. Whether those boundaries are useful in practice depends on how they hold up when a real request crosses them.

## 4. A conversation through Hail and Turgai

Consider an illustrative conversation about writing. A user says, “When you edit my drafts, keep British spelling.” Later, they send a draft and ask for a shorter version. After several revisions, they return to the same work following an application restart. This example follows the implemented ownership and execution paths; it is not a recorded test of the model's editing or memory-extraction accuracy.

Hail supplies the persistent agent and the machinery for model turns, tools, and context. Turgai builds the conversation around that agent and associates it with a user. The writing preference, the current editing request, and the model transcript therefore have distinct owners even though they all contribute to the answer.

### Remembering a preference and using it later

Turgai can record the user's statement as an observation in the durable `User` actor. A background extraction pass may propose it as a fact, subject to the memory policy. Once accepted, it can be retrieved for a later request. This distinction matters: receiving a sentence and deciding to retain it as personal memory are separate operations, and extraction is not guaranteed to recognize every useful preference.

When the draft arrives, the `Conversation` actor records and schedules the request. Before the model turn begins, Turgai retrieves relevant user memory and supplies it as reference material. Assuming the preference was accepted and retrieved, the agent receives both the editing request and the British-spelling preference. The preference can also be useful in another conversation because its owner is the user, rather than this particular editing transcript.

```text
 "Keep British spelling"
            |
            v
      User observation --> extraction and policy --> user memory
                                                        |
 "Shorten this draft"                                    |
            |                                           |
            v                                           |
      Conversation -- request + retrieved preference <---+
            |
            v
       Hail Agent --> model --> edited draft
```
*Figure 7 — A remembered preference enters a later turn through user memory, separately from the agent's conversation history.*

### Continuing the same agent's work

The conversation's identity and role determine the identity of its Hail agent. Virtual-actor resolution supplies the corresponding instance, including activation when needed. Hail maintains that agent's transcript and turn state, so a later request to revise the draft addresses the same logical agent. Turgai's adapter invokes it through this operation from the ordinary conversation path:

```swift
let response: String = try await agent.respond(
    input,
    message: input.chatMessage(),
    referenceEntries: input.referenceEntries(),
    inputID: input.inputID
)
```

The message contributes the conversational input, while reference entries carry additional material such as the retrieved preference. Hail runs the model and any requested tools using host-supplied capabilities. Turgai consumes the agent's activity concurrently to display progress, tying the activity consumer to the lifetime of the response operation. Hail explicitly serializes reasoning turns, and Turgai manages the conversation queue, so a second editing request has a defined relationship to work already underway.

The same agent interface is available for more focused work. Turgai's user-tool runner, for example, resolves a child agent in an isolated workspace, sends an instruction, and receives text through `respond`. That supplies a concrete composition mechanism for the multiple-agent arrangement discussed earlier. It does not automatically share the parent transcript or turn every conversation into a team of agents; the caller determines what instruction and material cross the boundary.

### Recovering the edited reply

Suppose Hail finishes the shorter draft and Turgai records the reply, but the process stops before delivery. The conversation's pending reply survives in its journal. After recovery and reconnection, Turgai can deliver that recorded text without generating another version. The transport connection is temporary; the decision that there is a reply waiting to be delivered belongs to the durable conversation.

```text
 edited draft produced
          |
          v
 reply recorded in conversation
          |
          X  process stops
          |
          v
 conversation reconstructed
          |
          v
 recorded draft delivered after reconnection
```
*Figure 8 — A reply recorded before interruption remains deliverable after the running conversation instance has been replaced.*

If the process stops earlier, while the turn is unfinished, Turgai instead recovers outstanding work. For conversation agents it disables Hail's independent interrupted-turn resume so that the conversation controls retry coordination. Hail still owns the transcript and runtime records. This avoids two components independently deciding to restart the same turn, but it does not guarantee exactly-once external effects: an acknowledgement lost after successful delivery can still lead to a duplicate, and tool effects require their own retry rules.

### Keeping a long conversation usable

After many revisions, the transcript may exceed the model's context capacity. Hail's compactor selects an older portion for summarization and retains recent exchanges where the budget permits. The same agent continues with a smaller working view, while its durable records remain available outside that view. Snapshots solve a separate problem by reducing the cost of reconstructing actor state after activation.

The spelling preference need not depend on surviving every successive summary. Its accepted form belongs to user memory and can be retrieved again for relevant turns. This separation does not eliminate retrieval or summarization errors, but it gives them different mechanisms to inspect and improve. It also leaves room to change how an agent moves between context windows without redefining the user, conversation, or delivery process.

## 5. Context management as a test of the object model

Context management provides a practical test of the argument developed here. The separation between an agent's durable history and its current working context was already part of Turgai's design. Extending that design with a dedicated agent to prepare the next context brings the earlier ideas together: a focused responsibility, an explicit request and result, and a persistent owner that decides how the result changes its state.

A proposal in the Codex repository makes this direction concrete. It describes context generations with a stable prefix and appended activity, a separate lower-cost agent that prepares structured checkpoints, and archived material available for retrieval. Its motivation includes both information lost through repeated summaries and the cost of disrupting prompt-cache reuse. This is a feature proposal, rather than evidence of a completed Codex implementation. [Cache-aware generational compaction proposal, issue #37448](https://github.com/openai/codex/issues/37448)

The smaller implementation being developed for Turgai takes the collaboration between agents as its starting point. The main agent has work to continue and history from which a handoff can be prepared. A compaction agent can receive a defined portion of that history and return a structured account of the task. Its responsibility is narrow enough to give it separate instructions, a model choice, and an output contract. The main agent remains the owner of its working context; the compaction agent supplies a result for the runtime to apply.

```text
       main agent: task and durable history
                    |
          request for a handoff
                    v
             compaction agent
        own instructions and model
                    |
           structured handoff
                    v
       runtime records context transition
                    |
                    v
       same main agent continues its task
```
*Figure 9 — The intended compaction collaboration: a specialist prepares a handoff while ownership of the ongoing task remains with the main agent.*

This is a natural extension of the mechanisms already used for ordinary agent work. Hail exposes agent invocation and structured results, while its `CompactionOperation` separates generation from projection into the available context budget. The runtime owns accounting, persistence, and replay. These provide places for the new behaviour to enter: the specialist performs the generation work, the projection determines what enters the next context, and the runtime records the transition. Coordinating the handoff still requires explicit decisions about its source history and when it becomes applicable, especially if the main agent continues working while it is prepared.

In the writing example, that handoff could carry the current draft, outstanding edits, and decisions that must survive the next context change. The British-spelling preference remains in user memory, and the conversation still owns reply delivery. Adding the specialist therefore exercises the composition described in section 2 without assigning it responsibility for users, transport, or the whole application. The implementation can be smaller than the Codex proposal while demonstrating this same architectural property; reproducing its full caching and archival strategy is a separate scope.

The evidence this example is intended to provide is concrete: a new agent responsibility can be added through existing interfaces, and its result can advance an existing durable agent's work. A completed integration and a trace across a context transition would demonstrate that claim. Measurements of summary quality, cost, and cache behaviour would answer further questions about the chosen strategy. The contribution to this article is the implementation path itself—how the object model gives the extension a clear place in the system.

<!-- Publication note: this implementation is currently WIP. Before release, update the description to match the completed integration and add an actual handoff/recovery trace, identifying the interfaces reused and the changes required. Do not imply that the full Codex proposal or its performance benefits have been reproduced. -->

## What the implementation establishes

Hail and Turgai demonstrate a concrete division of responsibility: a persistent agent owns model execution, a conversation owns the user-facing turn and pending delivery, and a user object owns personal memory. Swift expresses their interfaces and isolation, while additional runtime components provide virtual activation and persistence. These boundaries explain how the system can reconstruct work and vary selected capabilities without placing all state in one prompt or one application object.

The implementation does not by itself establish better task performance, cheaper execution, or reliable memory across arbitrary workloads. Those claims require evaluation, as do recovery under repeated failures and the quality of context handoffs. The narrower result is an architecture in which these questions have identifiable owners and mechanisms. That gives further experiments a stable starting point: an agent can retain its identity and recorded work while the way it reasons over that work continues to evolve.
