# ``TurgaiObjects``

Objects: Swift a bot writes, run as live actors in a space.

## Overview

A bot makes an object by writing an `actor` in Swift. Turgai checks the code against what it may
use, then runs it as a ``DynamicObject``: a virtual actor with the object's state, kept in its own
journal. It answers calls, announces events, follows other objects, runs on schedules, and comes
back after a restart with what it was doing.

Each space has its own objects, held by its ``DynamicObjects``: no call from another space reaches
them. Every space has the built-in objects, such as ``Page``, of its own.

See <doc:WritingObjects> for what object code can do.

## Topics

### Essentials

- <doc:WritingObjects>

### Objects

- ``DynamicObject``
- ``DynamicObjects``
- ``Script``
- ``Spec``

### Due work

- ``Schedule``
- ``Timer``

### Pages

- ``Page``
- ``Page``
- ``PageName``
- ``Layout``
- ``ButtonPressed``

### Calls

- ``AccessControlled``
- ``ObjectCallDecisions``
