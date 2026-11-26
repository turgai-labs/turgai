# The live connection

One WebSocket per app: the conversation it shows, and what changes for the person, pushed.

## Overview

A client opens one WebSocket, `GET /api/v1/live`, on behalf of whoever's signed in. Over it, the
client sends ``LiveCommand``s and receives ``LiveEvent``s, each JSON with a `type`.

### The conversation it shows

``LiveCommand/open(spaceID:conversationID:)`` shows a conversation from then on: its history comes
(`history`), then its turns as they happen: `turn.started`, what the agent is doing (`turn.phase`,
`turn.status`), the reply so far (`turn.partial`), and `turn.completed` or `turn.failed`. What's
said, not the tools the agent calls to say it: a turn's steps are read over HTTP, as one is asked
for (<doc:TheAPI>).

``LiveCommand/message(_:)`` says something in it. ``LiveCommand/answer(id:answer:)`` answers an
access request the conversation asked (`access.requested`), for whoever may decide.

### Asking, and topics

``LiveCommand/push(ref:ask:)`` asks something, a ``LiveAsk``, and is answered by a `reply`
carrying the same ``PushRef``: archiving a space, leaving or deleting a conversation, stopping the
reply a conversation is working on, changing a schedule, pressing a page's button, and joining or
leaving a ``LiveTopic``.

A topic's join is answered with what it is now (``LiveReply/joined(_:)``), as opening a
conversation is answered with its history; each change follows as it comes, while it's joined.
Joined again, it's answered again; it's left once every join of it is left. Joined again on a new
connection, its answer is heard as its other events are:

- ``LiveTopic/spaces``: the spaces the person is in (`spaces`), then each change (`space.joined`,
  `space.listed` when it's renamed, archived, or what they may do changes, `space.left`);
- ``LiveTopic/conversations``: the person's conversations, the one something was last said in
  first (`conversations`), then each change (`conversation.joined`, `conversation.said`,
  `conversation.titled`, `conversation.left`, `conversation.deleted`); what's said in the one it
  shows comes as that conversation's own events;
- ``LiveTopic/memory``: what's remembered about the person (`memory`);
- ``LiveTopic/tasks(space:)``: the space's schedules and reminders (`tasks`), then each change
  (`task.kept`, `task.ended`);
- ``LiveTopic/objects(space:)``: the space's objects (`objects`);
- ``LiveTopic/pages(space:)``: the space's pages (`pages`);
- ``LiveTopic/page(space:page:)``: what one page shows (`page`), or why it can't be shown
  (`page.failed`).
