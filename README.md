# Turgai

> [!WARNING]
> Turgai is at an early stage. Its APIs, storage and behaviour change without notice between
> versions, and parts of it are unfinished. Use it with caution, and don't rely on it for anything
> important yet.

Turgai is a place where people and bots talk, and where bots build things that keep running.

- **Spaces.** Everything lives in a space: its people and their groups, its bots, its
  conversations, its connections and its objects. A space decides who may do what, as it's done.
- **Bots on your models.** Apple's on-device model, Ollama, a server that speaks OpenAI's API,
  OpenAI, Anthropic or Gemini.
- **Live objects.** A bot writes Swift, and it runs as a live object: state, actions, events,
  schedules, websites. Objects keep running across restarts.
- **Ways in.** A web app, a Mac app, Telegram, and an API for your own clients.

It's written in Swift on distributed actors, with [Hail](https://github.com/akbashev/hail) as its
agent runtime.

## How it fits together

### Spaces

A space is a workspace, like a family's or a team's. Each space has:

- **people**, each in some of its groups. Every space starts with its admins, who may do
  everything; `members`, which whoever joins is in; and `guests`, allowed nothing until the admins
  allow the group something. People join by invites;
- **bots**, one of them the main, each with its own instructions and model;
- **conversations** between its people and its bots, each as private as the people in it;
- **connections**, ways in from elsewhere. A Telegram bot is one: its chats become conversations
  in the space;
- **objects** and **websites** its bots make.

Nothing reaches into a space except through it, and nothing in one space reaches another.

### Permissions

A space decides live. Every call and every effect carries who it's on behalf of, and the space
decides as it is at that moment, so a change to someone's groups applies to the next thing they do.
Something no one has allowed yet, such as a bot fetching a web page for someone, is asked of
whoever may decide, and waits for the answer.

### Objects

A bot makes an object by writing an `actor` in Swift. Turgai checks the code before it runs, then
runs it as a live actor that keeps its state in its own journal. Objects answer calls, announce
events, follow each other, run on schedules, and come back after a restart with what they were
doing. A space with websites installed can serve an object's page at `/websites/<name>/`.

### Bots and agents

A bot's agent runs on Hail: one turn at a time, tools answered inside the model's request, each
effect decided by the space. What an agent did is journaled, so a turn cut short by a restart is
resumed.

## Ways in

- **Web.** `http://<server>:3333`: your spaces, each with its bots, connections and chat.
- **Mac.** `Clients/Mac` runs all of Turgai inside the app, with a window for conversations and
  the objects beside them.
- **Telegram.** Add a Telegram bot as one of a space's connections.
- **API.** HTTP routes under `/api/v1`, and one WebSocket per app for what changes live. See the
  [documentation](https://turgai-labs.github.io/turgai/documentation/turgaimodels/).

## Run

Turgai needs Swift 6.4 and macOS 26.4, or Linux.

```sh
TURGAI_SECRET_KEY=$(openssl rand -base64 32) swift run Turgai serve
```

Then open <http://127.0.0.1:3333> to set it up: your account, where memory is kept, and your first
space with its first bot.

- **The key.** Every secret Turgai keeps (API keys, connection tokens, sessions) is sealed with
  it. Keep it: another key doesn't open them. `turgai forget-secrets` clears them all, to start
  over with a new key.
- **Data.** In `~/.turgai`, or `--directory`. Memory can be kept there, in SQLite, or in
  PostgreSQL.
- **Clients.** `--api-auth` says how API clients are let in: `local` (the default), `api-key`
  (with `TURGAI_API_KEY`), or `trusted-proxy`.

For a Raspberry Pi, `scripts/build-pi.sh` builds a Linux arm64 release in Docker into `dist/pi`.
Copy it to the Pi and run `sudo ./install.sh`: Turgai runs as a service, as you, with its key kept
by the system.

## Inside

Turgai is a set of Swift modules, with dependencies one way, from the domain up to the apps:

| Module | What it is |
| --- | --- |
| `TurgaiDomain` | The values everything shares: identities, bots, connections, messages |
| `TurgaiCalls` | Who a call is on behalf of, and what they may do |
| `TurgaiPeople` | People, and linking the ways in that are one human |
| `TurgaiConversations` | Conversations, their people and their agents |
| `TurgaiAgents` | Where bots' models run, and their keys |
| `TurgaiSpaces` | Spaces: their people, groups, bots, connections and requests |
| `TurgaiMemory` | What's remembered about each person |
| `TurgaiObjects` | Objects: checking their code, and running it as live actors |
| `RunningActors` | Keeping actors' long-running work going across restarts |
| `TurgaiHail` | Turgai's side of Hail: conversations' agents, and bots' roles |
| `TurgaiApplication` | Tools, built-in objects, Telegram connections, authority |
| `TurgaiTelegram` | Telegram's API |
| `TurgaiPersistence` | Turgai's database, and the key secrets are sealed with |
| `TurgaiModels` | The API's values |
| `TurgaiWeb` | The web app and the API |
| `TurgaiServer`, `Turgai` | The server, and its command |
| `MacApp` | The Mac app |

Underneath, every space, conversation, object and agent is a virtual actor on a cluster: reached
by its id, activated when a message arrives, and rebuilt from its own journal. A space's rules are
pure functions, apart from the actor that runs them. Lists, such as a person's spaces, are read
sides kept from the journal.

## Documentation

The documentation is at [turgai-labs.github.io/turgai](https://turgai-labs.github.io/turgai/): the
API and its live connection, spaces and permissions, and writing objects. Build the site yourself
with `bash scripts/build-docs.sh`, or preview one module:

```sh
swift package --disable-sandbox preview-documentation --target TurgaiObjects
```

## Test

```sh
swift test
```

The tests need no model, Telegram bot or network.

## License

Apache License, Version 2.0. See [LICENSE.txt](LICENSE.txt).
