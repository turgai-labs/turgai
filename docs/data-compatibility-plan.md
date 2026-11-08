# Keeping data

Agreed: not yet. Until the data model settles, a changed stored type means resetting the streams that hold it. Once it settles, Turgai keeps data the way Akka does: what's stored never changes, only how it's read.

## What others do

**Akka Persistence** evolves events on the way in:

| Mechanism | What it does |
|---|---|
| Evolvable serializer | Protobuf field numbers, or Jackson JSON with a version stored beside each event |
| Jackson migrations | Rewrite an old version's JSON to the current shape before decoding: rename, default, rename the type |
| Event adapters | Turn one stored event into none, one, or several domain events: drop a retired type, split a coarse one |
| Snapshots | A cache: one that can't be read is deleted, and the events are replayed |
| Projections | Rebuilt by resetting their offset |
| Copy and transform | An offline migrated journal, the last resort |

**Orleans** leans on its serializer. Fields carry ids, so adding or removing one is safe, and `[Alias]` keeps a renamed type readable. Event-sourced grains (`JournaledGrain`) store events through the same serializer, with no upcasting built in: anything more is done by hand in the grain or a custom storage provider. `[Version]` on grain interfaces is about calls during rolling upgrades, not stored data.

## The design

All of it lives in `cluster-event-sourcing`, which owns the journal. Hail isn't involved.

**`@Stored(version:)`**, a macro on every type that goes into a journal or a snapshot. It generates:

1. Decoding that tolerates a missing optional or defaulted field, so every additive change is free. Swift's synthesized `Decodable` doesn't.
2. The version, stored with each payload, so the journal knows what it's reading before it decodes.
3. `storedShape`: the type's field names and declared types, as text.

**Migrations**, one static function per type, called when what's stored is older:

```swift
extension MemoryObservation {
    static func migrate(from version: Int, _ stored: inout StoredJSON) -> Migration {
        if version < 2 { return .drop }   // nothing to place it in: ignored, as Akka's adapters can
        return .keep
    }
}
```

**The shape guard**, a test helper. It compares each stored type's `storedShape` with a committed fixture, and fails when a shape changed without a new version, or a version has no migration from the one before. It also decodes sample payloads of every old version through the migrations. A stored change can't slip in unnoticed.

**Around it:**

- Snapshots stay a cache: one that doesn't decode is dropped, and the stream is replayed.
- Read sides (`memory_unread`, the space and conversation directories) are rebuilt by resetting their offset.
- Stored types are kept apart from domain types once frozen, so a domain change isn't a storage change by accident.
- Accounts, profiles, and other SQLite tables are outside all of this: they evolve by SQL migrations.

## Where it starts

1. Build the macro, `StoredJSON`, `Migration`, the decode hook, and the shape guard in CES. Commit, merge into the integration branch, and push, then update norby.
2. Mark `SpaceEvent` and the channel events `@Stored(version: 1)`, with every type nested in them: the guard needs those too.
3. Mark the rest as each settles: conversations, memory, objects.

## Until then

Reset only the streams whose types changed, not the whole directory. For a person's memory:

```
sqlite3 ~/.turgai/turgai.sqlite "DELETE FROM journal WHERE persistence_id LIKE 'turgai-user-%'"
```

A commit that changes a stored type says which streams to reset.
