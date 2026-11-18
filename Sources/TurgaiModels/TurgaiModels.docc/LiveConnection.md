# The live connection

One WebSocket per app: the conversation it shows, and what changes for the person, pushed.

## Overview

A client opens one WebSocket, `GET /api/v1/live`, on behalf of whoever's signed in. Over it, the
client sends ``ChatCommand``s and receives ``ChatEvent``s, each JSON with a `type`.

### What it's always told

Without asking, the connection is told what changes in the person's lists:

- their conversations: `conversation.joined`, `conversation.said`, `conversation.titled`,
  `conversation.left`, `conversation.deleted`;
- their spaces: `space.joined`, `space.listed` (renamed, archived, or what they may do changed),
  `space.left`.

### The conversation it shows

``ChatCommand/open(spaceID:conversationID:)`` shows a conversation from then on: its history comes
(`history`), then its turns as they happen: `turn.started`, the reply so far (`turn.partial`), the
steps it takes (`turn.step`), and `turn.completed` or `turn.failed`.

``ChatCommand/message(_:)`` says something in it. ``ChatCommand/answer(id:answer:)`` answers an
access request the conversation asked (`access.requested`), for whoever may decide.

### Asking, and topics

``ChatCommand/push(ref:ask:)`` asks something, a ``ChatAsk``, and is answered by a `reply`
carrying the same ``PushRef``: archiving a space, leaving or deleting a conversation, changing a
schedule, and joining or leaving a ``ChatTopic``.

A topic is told only while it's joined:

- ``ChatTopic/memory``: what's remembered about the person (`memory.changed`);
- ``ChatTopic/tasks(space:)``: the space's schedules and reminders (`tasks`, `task.kept`,
  `task.ended`);
- ``ChatTopic/objects(space:)``: that the space's objects changed (`objects.changed`).
