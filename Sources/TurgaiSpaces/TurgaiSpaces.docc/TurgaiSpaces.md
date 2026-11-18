# ``TurgaiSpaces``

Spaces: who's in them, what each may do, and everything that lives in them.

## Overview

A ``Space`` holds its people, each in some of its groups; what each group may do; its bots, one
of them its main; its connections; and the requests it's been asked. Its conversations and objects
are its own too, and are reached only through it.

Every space is made with three groups: its admins, who may do everything; `members`, which whoever
joins is in; and `guests`, allowed nothing until its admins allow the group something. What a
person may do is what their groups may, together.

A space decides live. A call or an effect carries who it's on behalf of, and the space decides
then, as it is then, so a change to someone's groups applies to what they do next. A request no
one has allowed yet is asked of whoever may decide, and waits for the answer.

The rules are pure functions, kept apart from the actor: ``SpaceDecider`` decides what a command
does, as events, and evolves the state with them. The ``Space`` actor runs a command through it,
journals the events, and applies them.

## Topics

### A space

- ``Space``
- ``SpaceDecider``
- ``SpaceListing``
- ``SpaceRefusal``

### Who's in which spaces

- ``SpaceDirectory``
- ``SpaceNotice``
- ``SpaceDirectoryChange``
