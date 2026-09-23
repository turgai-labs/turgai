# Turgai

Turgai is a personal AI companion built in Swift. It currently uses Telegram as
its primary interface and combines a durable Hail agent runtime, provider-aware
model routing, personal memory, and a small set of host-owned tools.

The project is intentionally being built as an application rather than as a
general-purpose agent framework. Its design follows functional core,
imperative shell: domain decisions are represented by typed values and pure
transitions, while Telegram, model, filesystem, and cluster operations stay at
the boundaries. Protocols are introduced where they provide a useful
typeclass-like contract.

## Current capabilities

- Durable, recoverable conversations backed by file journals and snapshots.
- Telegram polling, replies, reactions, attachments, HTML formatting, and
  folded partial responses.
- Provider-aware model routing through [Hail](../hail): Apple Foundation
  Models on supported macOS, local Ollama, and OpenAI-compatible API models.
- Automatic semantic memory with provenance, retrieval, revisions, and
  background extraction where the selected provider supports it.
- Web search, URL fetching, attachment fetching, and Open-Meteo weather.
- Composable typed effects, including the clock and network effects used by
  the weather tool.
- Swift 6.4 structured concurrency and tests for the core boundaries.

This is an active personal project. The architecture and APIs are still
evolving.

## Requirements

- macOS 26 or newer.
- Swift 6.4.
- A checkout of [Hail](../hail) next to this repository; `Package.swift` uses
  that local package dependency.
- A model provider: Ollama, Apple Foundation Models, or an OpenAI API account.
- A Telegram bot token from BotFather when Telegram is enabled.

The onboarding dashboard chooses the first bot's model. Providers that need an
endpoint store that endpoint with the bot; Ollama defaults to
`http://127.0.0.1:11434`.

## Run

Start Ollama, then run Turgai from the repository root. On first launch the
process serves the local Turgai dashboard and waits for onboarding to finish:

```sh
ollama serve
swift run Turgai
```

For an A/B test that disables Qwen's extended reasoning while preserving the
normal provider behavior by default:

```sh
TURGAI_QWEN_FAST_MODE=1 swift run Turgai
```

The dashboard stores the Telegram token and persistence settings locally. It
offers the default file store (with an editable `file://` directory) or
PostgreSQL for both journals and snapshots. PostgreSQL credentials are kept in
separate local secret files.

The Telegram chat allow-list, model, persona, and context window are configured
in the dashboard. Background memory extraction follows the configured provider
when an extraction adapter is available. If the allow-list is empty, the bot
accepts messages from every chat. The dashboard's default file store and the Telegram polling
checkpoint live below `.turgai/` unless you choose another file-store URL.
That directory is local runtime data and is intentionally ignored by Git.

## Test

Run the complete test suite with:

```sh
swift test
```

The tests do not require a live Telegram bot or model provider server.

## Architecture

| Module | Responsibility |
| --- | --- |
| `TurgaiDomain` | Identities, messages, coordination values, and reducers |
| `TurgaiMemory` | Facts, observations, memory events, policy, and retrieval |
| `TurgaiHail` | Hail adapters, runtime configuration, and host tools |
| `TurgaiApplication` | Durable conversations, reply scopes, and memory orchestration |
| `TurgaiTelegram` | Telegram transport, mapping, formatting, and publishing |
| `TurgaiPersistence` | File- or PostgreSQL-backed journals and snapshots |
| `Turgai` | Composition, live connections, and delivery coordination |

Hail owns durable agent communication, model turns, tool execution, and
generic runtime extension points. Turgai owns user identity, persona, memory,
channel policy, and application composition.

## Persistence and recovery

Turgai treats the journal as the source of truth for conversation recovery.
Snapshots accelerate replay but do not replace the journal. On startup, the
application discovers unfinished conversation state, recreates Telegram
connections, and retries recoverable turns. Personal memory is stored in its
own durable projection and is not part of the Telegram transport state.

Do not commit `.turgai/`; it can contain private conversation history and local
credentials/checkpoints.

## License

Turgai is licensed under the Apache License, Version 2.0. See
[LICENSE.txt](LICENSE.txt).
