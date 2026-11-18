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

## Run

Turgai needs Swift 6.4 and macOS 26.4, or Linux.

```sh
TURGAI_SECRET_KEY=$(openssl rand -base64 32) swift run Turgai serve
```

Then open <http://127.0.0.1:3333> to set it up: your account, where memory is kept, and your first
space with its first bot. Keep the key: every secret Turgai keeps is sealed with it. Data lives in
`~/.turgai`.

On a Mac, the app in `Clients/Mac` runs all of Turgai in its own process. For a Raspberry Pi,
`scripts/build-pi.sh` builds a Linux arm64 release into `dist/pi`, with an installer.

## Test

```sh
swift test
```

The tests need no model, Telegram bot or network.

## License

Apache License, Version 2.0. See [LICENSE.txt](LICENSE.txt).
