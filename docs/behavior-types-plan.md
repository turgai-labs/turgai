# Behaviors as types

Status: trying

An object's type is its behavior. `x: worker` means x runs the behavior `worker`, so changing `worker` changes every object of that type: they adopt it when idle, as today. No protocols, no `speaks`.

## Steps

1. A branch, `behavior-types`, from the typed-spec work. Protocols stay in git history.
2. A parameter's or field's type is a built-in or a behavior's name. Sends to it are checked against what that behavior takes.
3. A new spec for a behavior relinks the specs that send to values of its type, and is refused if one would break.
4. A name not defined yet is accepted, checked when it's defined, and refused at runtime if it still doesn't fit.
5. Remove protocols, `speaks`, and their relinking and subtyping code. States become fields.
6. Tests, then the eval with FM and qwen.

## Kinds, and replies

7. A kind is a behavior with a name and no object, as an Erlang module or an Akka `Behavior` exists before anything runs it. `like:` and `sameAs:` name a kind or an object. A kind whose clauses do nothing is an interface: objects that take at least its messages fit it.
8. A message's reply type comes from its clauses: what each one replies. Clauses for one message that reply differently, or where some reply and some don't, are an error.

Done: kinds live in the objects directory, `sameAs` takes an object's handle or a kind's name, and a kind's change relinks what refers to it. A separate `objects_kind` tool was tried and dropped: it doubled FM's tool tokens (4,759 of 8,192), and FM used it when it didn't need a kind. Kinds aren't a model tool for now.

How objects relate to a kind: `sameAs` shares it, so a change reaches them (nominal, like a Pony trait); `like` fits any object that takes at least its messages (structural, like a Pony interface).

## Revert if

- Objects that need interchangeable behaviors (two behaviors behind one parameter) turn out to be common. Then protocols come back, as shared message types.
- The eval does worse than the typed spec with protocols.

To revert: drop the branch.
