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
- Durable recurring schedules and one-shot timers with `notify` and
  `prompt_agent` actions. Scheduled agent work re-enters the owning
  conversation through the normal Hail path.
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

## Validation: explicit calendar information

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

## Memory controls and context reset

Capture is automatic. The user can inspect or delete all saved memory;
there is no candidate approval workflow.

- [x] Add /memory with bounded output for the requesting user's current facts.
  Preserve participant ownership in group chats.
- [x] Add /forget for all saved personal memory. Logical forgetting clears the
  active memory projection and starts a new generation; the event journal is
  retained. Physical journal erasure remains a separate privacy operation.
- [x] Ensure extraction already in flight cannot restore forgotten memory.
  Generation and observation-time boundaries reject stale writes.
- [x] Keep `/reset` as a Norby coordination/channel reset. It cancels active
  model work, drops queued messages and pending replies, and clears channel
  delivery state; it does not clear Hail's durable transcript or context
  summary.
- [ ] Only add a fresh-context command when the product needs it. That would
  be a separate Hail-owned durable context boundary, while Norby would still
  own the user-facing command and policy. Hail's `contextSet` marker is not a
  reset operation.
- [ ] Manually check multilingual facts, contextual short answers,
  corrections, duplicate tool/background writes, notices and later retrieval.

Accepted MVP tradeoffs: observations use journal order; background extraction
is best-effort and may be skipped by a crash. Durable extraction jobs and
additional ordering machinery are deferred. Saved facts remain durable.

## Following: local data protection

Norby currently stores conversation coordination, Hail transcripts, memory,
and snapshots as readable local persistence files. Telegram and any remote
model endpoint remain separate external trust boundaries.

- [ ] Make Telegram access explicit and default-deny. An empty allow-list
  currently permits every chat to reach Norby.
- [ ] Keep Ollama local unless explicitly configured otherwise. Make a remote
  model endpoint an obvious, deliberate configuration choice.
- [ ] Define the local at-rest protection contract and key-loss behavior.
- [ ] Add encryption to `FilePersistenceClient`, covering event journals and
  snapshots through the existing store/client boundary. Event and snapshot
  adapters remain thin plugin details; Hail and domain values stay unaware of
  encryption.
- [ ] Provision the installation key from the application composition root
  using the macOS Keychain, and fail clearly when protected data cannot be
  opened.
- [ ] Verify migration/rotation behavior and backups before enabling it by
  default.
- [ ] Keep logical `/forget` separate from a future physical local wipe of
  journals and snapshots.

## Next feature: a scheduled agent

First deliver one narrow path: a durable schedule wakes a named Hail agent
with input and selected tools, then sends its result to the owner conversation.
Example: "Every morning at 8, send me today's weather."

- [x] Integrate cluster-durable-workflows with the existing cluster/journal
  bootstrap and one event-store configuration. Norby installs the workflow
  plugin beside Hail and uses the existing file event/snapshot stores.
- [x] Add a registered scheduled-agent workflow and activity. The durable
  input carries owner and destination identity, prompt, participant and
  channel/agent configuration. The activity resolves Conversation, so
  scheduled work uses ordinary Hail history, tools and memory.
- [x] Add a one-shot scheduled-agent timer workflow using the workflow
  runtime's journaled `sleep(until:)`. Stable workflow-derived message/turn
  IDs and Conversation deduplication make activity replay idempotent.
- [x] Support a specific fire date through the timer domain API and recurring
  local time with timezone through `Calendar.RecurrenceRule`. Schedules use
  skip-overlap behavior and durable workflow retry policy.
- [x] Expose schedule creation and one-shot timer creation as agent tools;
  application APIs also support cancellation and description.
- [x] Expose schedule creation, cancellation and MVP replacement through the
  schedule tool. Replacement cancels and recreates the existing schedule
  under its returned schedule ID.
- [ ] Add owner-scoped schedule listing and a small `/schedules` view.
- [x] Verify ordinary restart recovery with a shared journal: a running timer
  resumes and completes, a recurring schedule is rediscovered, repeated
  registration is idempotent, and cancellation removes the schedule.
- [ ] Verify result delivery manually with the real file stores and a live
  channel; cross-process file-store verification is still pending.

The registry and each workflow/schedule have separate journal writes. A crash
between those writes can leave a stale registry entry or an object that was
never registered; startup recovery validates the object and drops stale
entries, but it cannot recover an object whose registry registration was never
written. Cross-journal atomicity is intentionally deferred.

A general declarative workflow language follows this milestone.

## Plugin evolution: schedule replacement and scoped agent sessions

The MVP keeps schedule replacement as cancel-then-create. The next plugin work
should make the two underlying capabilities explicit without moving product
policy into the plugins.

### DurableWorkflows schedule replacement

- [x] Keep the current cancel-then-create path as the Norby MVP behavior.
- [ ] Add a durable scheduler update operation for an existing `ScheduleID`.
  The operation must persist the new recurrence, input, retry policy and
  overlap policy as one scheduler event and rearm from the resulting state.
- [ ] Define update behavior for an occurrence that is pending, running or
  already finished. Preserve the existing occurrence and apply the new
  definition to future occurrences.
- [ ] Keep schedule identity separate from schedule definition. Norby should
  own the stable logical schedule identity; changing a prompt or recurrence
  must not silently create a second schedule.
- [ ] Keep registry bookkeeping idempotent when a schedule is updated, and
  recover the updated definition after restart.
- [ ] Add scheduler tests for update, cancellation, restart recovery,
  repeated update and an update racing with an occurrence.

### Hail scoped multi-exchange sessions

- [ ] Model a bounded session that can contain several agent exchanges while
  the application keeps one reply scope alive.
- [ ] Define interactive completion separately from background completion:
  interactive work requires a visible terminal response; background work may
  complete with no reply.
- [ ] Add a continuation operation over the durable transcript. It must not
  append the original user input again or replay completed tool effects.
- [ ] Decide how a continuation is journaled and exposed through the existing
  agent connection, including partial output, failure and cancellation.
- [ ] Add a bounded empty-output recovery policy in Norby’s scope. One
  continuation attempt is enough; repeated empty output becomes a recorded
  terminal outcome.
- [ ] Test a tool round followed by an empty model response, continuation
  without duplicate side effects, an intentional background void, reconnect,
  recovery and cancellation.

The current Norby persona may carry a small visible-completion instruction as
an interim guardrail. It is a behavioral aid, not the correctness mechanism;
the scoped session and output contract remain plugin work.

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
