# ``TurgaiModels``

What Turgai's clients send and receive: the values of its HTTP API and its live connection.

## Overview

`TurgaiModels` is the API as Swift values, with no server in it: what a request carries, what a
response holds, and what the live connection says. The Mac app is a client of exactly these
values; any other client can use them too, or speak the same JSON.

Everything a person does happens in a space: its bots, its conversations, its people, its
connections and its objects. So most of the API is under `/api/v1/spaces/<space>/…`. See
<doc:TheAPI> for the routes, and <doc:LiveConnection> for what the live connection pushes.

## Topics

### Essentials

- <doc:TheAPI>
- <doc:LiveConnection>

### Spaces

- ``SpaceID``
- ``SpaceSummary``
- ``SpacePermissions``
- ``SpacePerson``
- ``SpaceBot``
- ``SpaceConnection``
- ``MakeSpaceRequest``
- ``RenameSpaceRequest``
- ``SpaceInviteOffer``
- ``SpaceInviteLink``
- ``SpaceInviteListing``
- ``JoinSpaceRequest``

### Bots and models

- ``Bot``
- ``BotID``
- ``BotConfiguration``
- ``ModelChoice``
- ``ModelProvider``
- ``ModelsRequest``
- ``ModelsAnswer``

### Conversations

- ``Conversation``
- ``ConversationID``
- ``CreateConversationRequest``
- ``TitleConversationRequest``
- ``Message``
- ``MessageID``
- ``SendMessageRequest``
- ``ParticipantRef``
- ``ParticipantSummary``
- ``TurnRecord``
- ``TurnStep``

### The live connection

- ``ChatCommand``
- ``ChatEvent``
- ``ChatEventKind``
- ``ChatAsk``
- ``ChatReply``
- ``ChatTopic``
- ``PushRef``
- ``AccessRequest``
- ``AccessAnswer``

### Objects and tasks

- ``ObjectListing``
- ``ObjectSharingRequest``
- ``TaskListing``
- ``ScheduleChange``

### People

- ``Me``
- ``MemorySummary``
- ``SetRememberingRequest``
- ``LinkedPerson``
- ``LinkCodeOffer``
- ``EnterLinkCodeRequest``
- ``TurgaiServerStatus``
