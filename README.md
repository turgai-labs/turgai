# Norby

Norby is a personal AI companion built in Swift. It currently uses Telegram as
its primary interface and combines a durable Hail agent runtime, local Ollama
models, personal memory, and a small set of host-owned tools.

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
- Local Ollama model routing through [Hail](../hail).
- Automatic semantic memory with provenance, retrieval, revisions, and
  background extraction.
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
- An Ollama installation with a model available locally.
- A Telegram bot token from BotFather.

The default model is `ollama/qwen3.5:9b` and the default Ollama endpoint is
`http://127.0.0.1:11434`.

## Run

Start Ollama, then run Norby from the repository root:

```sh
ollama serve
swift run Norby --telegram-bot-token "$NORBY_TELEGRAM_BOT_TOKEN"
```

The token can also be supplied through `NORBY_TELEGRAM_BOT_TOKEN`:

```sh
export NORBY_TELEGRAM_BOT_TOKEN="..."
swift run Norby
```

Useful configuration options are available both as command-line options and,
where noted, environment variables:

| Option | Environment variable | Default |
| --- | --- | --- |
| `--telegram-bot-token` | `NORBY_TELEGRAM_BOT_TOKEN` | required |
| `--telegram-chat-ids` | `NORBY_TELEGRAM_CHAT_IDS` | all chats |
| `--model` | `NORBY_MODEL` | `ollama/qwen3.5:9b` |
| `--ollama-base-url` | `OLLAMA_BASE_URL` | `http://127.0.0.1:11434` |
| `--context-window` | `NORBY_CONTEXT_WINDOW` | `16384` |
| `--workspace` | — | current directory |

`NORBY_TELEGRAM_CHAT_IDS` is a comma-separated allow-list. If it is empty or
unset, the bot accepts messages from every chat. Runtime journals, snapshots,
and the Telegram polling checkpoint are stored below `<workspace>/.norby/`.
That directory is local runtime data and is intentionally ignored by Git.

## Test

Run the complete test suite with:

```sh
swift test
```

The tests do not require a live Telegram bot or Ollama server.

## Architecture

| Module | Responsibility |
| --- | --- |
| `NorbyDomain` | Identities, messages, coordination values, and reducers |
| `NorbyMemory` | Facts, observations, memory events, policy, and retrieval |
| `NorbyHail` | Hail adapters, runtime configuration, and host tools |
| `NorbyApplication` | Durable conversations, reply scopes, and memory orchestration |
| `NorbyTelegram` | Telegram transport, mapping, formatting, and publishing |
| `NorbyPersistence` | File-backed journals and snapshots |
| `Norby` | Composition, live connections, and delivery coordination |

Hail owns durable agent communication, model turns, tool execution, and
generic runtime extension points. Norby owns user identity, persona, memory,
channel policy, and application composition.

## Persistence and recovery

Norby treats the journal as the source of truth for conversation recovery.
Snapshots accelerate replay but do not replace the journal. On startup, the
application discovers unfinished conversation state, recreates Telegram
connections, and retries recoverable turns. Personal memory is stored in its
own durable projection and is not part of the Telegram transport state.

Do not commit `.norby/`; it can contain private conversation history and local
credentials/checkpoints.

## License

Norby is licensed under the Apache License, Version 2.0. See
[LICENSE.txt](LICENSE.txt).
