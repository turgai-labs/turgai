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

## Revert if

- Objects that need interchangeable behaviors (two behaviors behind one parameter) turn out to be common. Then protocols come back, as shared message types.
- The eval does worse than the typed spec with protocols.

To revert: drop the branch.
