# Norby plan

Updated 2026-09-06 against the current implementation.

## Direction and boundaries

Build a local Norby companion with Telegram, personal memory, tools, and
scheduled agent work. Add other clients when needed.

Follow Scott Wlaschin's functional-core/imperative-shell approach in Swift:
typed values and pure decisions, async throwing operations at the boundary.
Protocols represent useful typeclass contracts. Prefer structured concurrency
and standard async sequences; introduce abstractions when actual consumers
need them.

Hail owns durable agent communication, history, model turns, tool execution,
and generic integration points. Norby owns persona, user identity, memory,
channel policy, and future scheduled work. Tool schemas describe capabilities;
avoid duplicating a tool manual in the persona prompt.

## Implemented baseline

- Swift 6.4 executable with local Hail and configurable Ollama routing.
- Channel-neutral domain/reducer; durable Conversation and User actors.
- Telegram polling and persisted acceptance checkpoint, text/attachments,
  HTML formatting, reactions, and replies to source messages.
- Scoped reply lifecycle and partial output; Telegram preview folding,
  throttling and rate-limit handling; durable pending terminal replies.
- File journals and snapshots under .norby/journal and .norby/snapshots;
  transport checkpoint at .norby/telegram-offset.txt.
- Hail is the transcript authority. ConversationState holds coordination
  state; ModelRequest carries the accepted InboundMessage.
- Model context capacity and compaction integration through Hail.
  Snapshotting and summarization are separate concerns.
- Search, URL fetch, attachment fetch, weather, and per-turn memory tools.
  Weather composes clock and network effects.
- Semantic memory values, provenance, deterministic policy, additions/revisions,
  bounded retrieval and per-turn context.
- Combined capture: MemoryTool plus independent background model extraction.
  Both submit explicit proposals through the User aggregate. A proposal must
  reference a user observation and quote its text; observation completion
  stores the assistant response as context, never as fact evidence.
  Equivalent repeats are no-ops and meaningful background writes produce
  notices.
- Startup recovery discovers unfinished Conversation journal state, recreates
  Telegram chat connections, reattaches the durable conversation, retries
  interrupted turns, and delivers pending terminal replies.
- Tests for domain transitions, memory, adapters, reply scopes, Telegram
  formatting/delivery, and file persistence.

Implemented does not imply every real-world scenario has been verified.
Remaining behavior checks are listed below.

| Target | Responsibility |
| --- | --- |
| NorbyDomain | Identity, messages, coordination values and reducer |
| NorbyMemory | Observations, facts, events, projection, policy and retrieval |
| NorbyHail | Hail adapters, runtime configuration and host tools |
| NorbyApplication | Durable aggregates, reply scope and memory orchestration |
| NorbyTelegram | Transport, mapping, formatting and publisher |
| NorbyPersistence | File journals and snapshots |
| Norby | Composition, live connections and Telegram delivery coordination |

## Next: explicit calendar information

Observed: weather responses assign incorrect weekdays to dates and reuse
those incorrect labels in follow-up turns. The current weather formatter
omits the date from its clock output and emits forecast dates without weekdays.

- [x] Return weekday, full date including year, local time and timezone for
  the tool's current instant.
- [x] Derive forecast weekdays from each forecast date using a Gregorian
  calendar in the location's timezone. Keep date, weekday and weather together.
- [x] Distinguish current clock time from forecast/measurement timestamps.
- [x] Use Hail's built-in NowTool for a fresh current instant. The incoming
  message timestamp remains the stable reference for relative dates in that
  turn.
- [ ] Test a known week, year boundary, and local midnight/timezone boundary.
  Manually verify the September 6–12, 2026 example and a follow-up correction.

Start with explicit tool data. If follow-ups still invent dates without a tool
call, evaluate a small host-supplied per-turn clock context. A host timezone
must not be silently treated as the user's timezone.

## Next: memory controls and reset

Capture is automatic. The user can inspect or delete all saved memory;
there is no candidate approval workflow.

- [ ] Add /memory with bounded output for the requesting user's current facts.
  Preserve participant ownership in group chats.
- [ ] Add /forget for all saved personal memory. Define which observations,
  facts and historical records are retained; distinguish logical forgetting
  from physical journal erasure.
- [ ] Ensure extraction already in flight cannot restore forgotten memory.
- [ ] Finish /reset. Current code clears Norby coordination/channel state,
  but does not invoke a Hail context reset. Add a generic journaled Hail reset
  boundary and connect it through the adapter.
- [ ] Reset settles the active turn and clears queued work and model
  context/summary/session state, retaining personal memory and historical
  chat records. Verify this boundary survives replay.
- [ ] Manually check multilingual facts, contextual short answers,
  corrections, duplicate tool/background writes, notices and later retrieval.

Accepted MVP tradeoffs: observations use journal order; background extraction
is best-effort and may be skipped by a crash. Durable extraction jobs and
additional ordering machinery are deferred. Saved facts remain durable.

## Next feature: a scheduled agent

First deliver one narrow path: a durable schedule wakes a named Hail agent
with input and selected tools, then sends its result to the owner conversation.
Example: "Every morning at 8, send me today's weather."

- [ ] Integrate cluster-durable-workflows with the existing cluster/journal
  bootstrap and one event-store configuration.
- [ ] Add one registered scheduled-agent workflow with persisted agent
  reference, input, owner, output destination and tool-access selection.
- [ ] Support a specific instant and recurring local time with timezone.
  Define overlap and missed-run behavior using the runtime's facilities.
- [ ] Expose create/list/cancel schedule tools and a small /schedules view.
- [ ] Scope operations to the owner and reuse Hail effect/authority handling.
  Tool access may inherit agent tools or select an explicit subset.
- [ ] Verify restart recovery, cancellation and result delivery; define retry
  behavior where external effects could otherwise be duplicated.

A general declarative workflow language follows this milestone.

## Following: visibility and tool registration

- [ ] Add small application queries for host/model status, agents, tools,
  channel health and schedules; start with /status and /agents.
- [ ] Reuse those queries in future clients, with access scoped to the caller.
- [ ] Extract a host tool catalog when inspection, selection or multiple
  providers need it. Per-turn composition already registers host tools.
- [ ] Preserve explicit tool selection and effect composition for future
  clock + scheduler + weather + fetch operations.

## Later capabilities

- Validated agent-created workflow plans: invoke agents, tools and registered
  workflows. Add limits and versioned plan data with that feature.
- Worker agents on other nodes or models; independently configurable
  extraction and background work when needed.
- Custom tools through a deliberate execution boundary, such as a sandboxed
  process/IPC mechanism for runtime-created code.
- Optional host API/dashboard sharing application queries and commands.
  Generate API models/client/backend when a real client needs them.
- Custom chat history query/projection with pagination over durable history,
  rather than an unbounded messages array in ConversationState.
- Additional channels and explicit cross-channel user linking.
- Telegram webhooks/OpenAPI generation when transport requirements justify it.
- Embeddings, semantic retrieval improvements and periodic consolidation
  when observed memory quality warrants them.

## Local operation and validation

- [ ] Write a short operator guide for configuration, .norby storage,
  backup/restore, reset and forgetting semantics.
- [ ] Add launchd support when unattended operation is needed.
- [ ] Pin development dependencies for a reproducible release.
- [ ] Manually verify reconnect and interrupted turn/reply delivery, then test
  long conversations with attachments/compaction. Address reproducible
  failures as they appear.

Current configuration: NORBY_TELEGRAM_BOT_TOKEN, NORBY_TELEGRAM_CHAT_IDS,
NORBY_MODEL, OLLAMA_BASE_URL, and the workspace CLI option. An empty chat
allow-list currently permits all chats.

Keep unit tests independent of live Telegram/Ollama. Add integration coverage
as the corresponding features are implemented.
