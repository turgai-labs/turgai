# The API

Turgai's HTTP routes, under `/api/v1`, each on behalf of whoever's signed in.

## Overview

Every call is on behalf of a person: an account signed in with its session cookie
(`turgai_auth`), or a guest with its guest cookie. What a call may do is decided by the space it's
in, as it's made: a call a person's groups don't allow is refused.

How a client itself is let in is the server's choice (`turgai serve --api-auth`):

- `local`, the default: any client that reaches the server.
- `api-key`: a client that sends `Authorization: Bearer <key>`, the key the server was given in
  `TURGAI_API_KEY`.
- `trusted-proxy`: whatever the proxy in front of the server lets through.

Bodies and answers are JSON. A refusal answers an error with a `code` and a `message`.

### Who's asking

| Route | |
| --- | --- |
| `GET /api/v1/status` | Whether Turgai is set up: ``TurgaiServerStatus``. Asks no one. |
| `GET /api/v1/me` | Who's signed in: ``Me``. |
| `GET`, `DELETE /api/v1/me/memory` | What's remembered about them; forgetting it all. |
| `PUT /api/v1/me/memory/remembering` | Whether they're remembered from now on. |
| `GET`, `POST /api/v1/me/links`, `POST …/codes`, `DELETE …/:person` | Their other ways in, linked as one human. |

### Spaces

| Route | |
| --- | --- |
| `GET`, `POST /api/v1/spaces` | Their spaces; making one, with its first bot. |
| `PATCH /api/v1/spaces/:space` | Renaming it. |
| `DELETE /api/v1/spaces/:space/me` | Leaving it. |
| `GET /api/v1/spaces/:space/people` | Who's in it, and their groups. |
| `GET`, `POST /api/v1/spaces/:space/invites`, `DELETE …/:invite` | Its invites. |
| `POST /api/v1/spaces/:space/join` | Joining it with an invite. |
| `POST /api/v1/spaces/:space/guests` | Coming in as a guest: in its guests group, allowed what its admins allow guests. |

### Bots and connections

| Route | |
| --- | --- |
| `GET`, `POST /api/v1/spaces/:space/bots` | Its bots; adding one. |
| `PATCH`, `DELETE /api/v1/spaces/:space/bots/:bot` | Changing one; removing one. |
| `PUT /api/v1/spaces/:space/bots/:bot/main` | Making one its main bot. |
| `POST /api/v1/models` | A provider's models, for choosing a bot's: ``ModelsRequest``. |
| `GET`, `POST /api/v1/spaces/:space/connections` | Its connections, such as a Telegram bot; adding one. |
| `PATCH`, `DELETE /api/v1/spaces/:space/connections/:connection` | Changing one; removing one. |

### Conversations

| Route | |
| --- | --- |
| `GET /api/v1/conversations` | Their conversations, the one something was last said in first. |
| `POST /api/v1/conversations` | Starting one in a space: ``CreateConversationRequest``. |
| `GET`, `PATCH /api/v1/conversations/:id` | One of them; titling it. |
| `GET`, `POST /api/v1/conversations/:id/participants` | Who's in it; adding someone from its space. |
| `DELETE /api/v1/conversations/:id/me` | Leaving it. |
| `GET`, `POST /api/v1/spaces/:space/conversations/:id/messages` | Its messages; saying something. |

### Objects

| Route | |
| --- | --- |
| `GET /api/v1/spaces/:space/objects` | The space's objects they may read. |
| `GET /api/v1/spaces/:space/objects/:object/card` | One of them, by its handle: an ``ObjectCard``. |
| `POST /api/v1/spaces/:space/objects/:object/share` | Sharing one: ``ObjectSharingRequest``. |

For what changes while a client is open, follow the live connection: <doc:LiveConnection>.
