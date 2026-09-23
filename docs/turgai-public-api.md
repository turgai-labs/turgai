# Turgai public API

Turgai exposes a small conversation API for applications that want to use a
running Turgai server as an agent service. The API owns bots, conversations,
messages, durable history, model turns, and streaming events. It does not own
the calling application's users, sessions, roles, or authentication model.

The wire contract lives in the `TurgaiModels` module. It contains the
transport values and event types; `TurgaiWeb` owns the HTTP and WebSocket
routes that serve them.

An application maps its own user to a conversation in its own database. The
same conversation API can then be used by a web app, a mobile app, a terminal
client, or another service.

## Server authentication

Authentication is selected when Turgai is started:

```sh
turgai serve --api-auth local
turgai serve --api-auth api-key
turgai serve --api-auth trusted-proxy
```

`local` is the default and is intended for the local server. `api-key` checks
`Authorization: Bearer ...` against `TURGAI_API_KEY`:

```sh
TURGAI_API_KEY=replace-me turgai serve --api-auth api-key
```

`trusted-proxy` is for a deployment where an authenticated reverse proxy is
the network boundary. Turgai does not interpret the proxy's users or tokens in
this mode; it assumes that only authorized traffic can reach the server.

These modes protect access to the service. They are deliberately separate
from the public API model. A client can use OAuth, OIDC, JWT, mTLS, its own API
gateway, or a local anonymous session and still call the same Turgai API.

## Resources

All endpoints are under `/api/v1`.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/bots` | List enabled bots |
| `GET` | `/conversations` | List conversations visible to this API scope |
| `WS` | `/chat` | Create or resume a conversation and exchange live events |

The WebSocket is the primary API. A connection without a `conversationID`
starts a new conversation. A connection with one resumes that conversation.
The server sends the conversation ID in the first `ready` event, so clients do
not need a separate conversation-creation request.

Conversation listing is intentionally separate from the live connection. A
client can use it to render a conversation picker, then pass the selected ID
to the WebSocket. The current local API scope lists persisted API
conversations; a deployment that has multiple external users must apply its
own user-to-conversation visibility at this boundary.

## WebSocket chat

Connect to the default bot:

```text
WS /api/v1/chat
```

Or select a bot, and optionally resume an existing conversation:

```text
WS /api/v1/chat?botID=research&conversationID=bot-research-…
```

The server first sends `ready` and then `history`:

```json
{
  "type": "ready",
  "conversationID": "bot-research-…",
  "botID": "research",
  "status": "idle"
}
```

The client sends a message with a client-generated UUID. Reusing the same ID
lets the durable conversation reject a duplicated delivery:

```json
{
  "id": "C0A80101-ABCD-4EF0-9012-1234567890AB",
  "text": "Summarize the latest report."
}
```

The server may then emit:

```text
message.accepted
turn.started
turn.phase
turn.status
turn.partial
turn.completed
```

`turn.phase` is live activity, not a transcript message. Its `phase` is
`thinking` or `typing`; clients should render it in a transient activity
indicator and clear it when `turn.completed` or `turn.failed` arrives. The
`ready.status` value lets a reconnecting client restore an in-flight
indicator before the next live event. `turn.status` carries ephemeral
provider/tool narration such as the current tool being used; it is also not
part of conversation history.

Failures and runtime notices use `turn.failed` or `notice` with a structured
`error` containing `code` and `message`. Message bodies contain text only. The
API does not duplicate text as HTML; a client chooses how to render the text.

## Turgai Chat

The built-in chat page is a reference client of this API. It connects directly
to the public WebSocket; the server derives the conversation identity for the
selected bot and client identity. It does not use a second private chat
protocol.

## Ownership boundary

Turgai persists the conversation and its history. The consuming application
persists its own user-to-conversation relationship and decides who may access
each conversation. Turgai's web dashboard is one client of the runtime, not a
required identity provider for other clients.
