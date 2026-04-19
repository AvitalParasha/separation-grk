# Strategy Bug Regression Test

This example exposes a bug in `ComputeR2PPathStrategy` where the realizable
region of the two-phase R2P path strategy was computed using AND instead of OR:

```cpp
// BUG (old):
CUDD::BDD realizable = reach_strategy.RealizableRegion() &
                        maintain_strategy.RealizableRegion();
// FIX:
CUDD::BDD realizable = reach_strategy.RealizableRegion() |
                        maintain_strategy.RealizableRegion();
```

## The example

- 1 input: `trigger` (free, no safety constraints)
- 2 outputs: `x`, `y` with mutual exclusion `!(Xx & Xy)`
- R2P implication: `GF(trigger) → FG(y)`
- Initial state: `x=0, y=0`

The spec is **REALIZABLE** — the system can go to `(x=0, y=1)` and stay there.

## Why the old code fails

The alive region is `{(x=0, y=1)}`. The two-phase R2P path strategy has:
- Phase 0 (reach): drive from outside alive toward `(0,1)`. Realizable from all states.
- Phase 1 (maintain): stay at `(0,1)`. Realizable only at `(0,1)`.

With AND: `realizable = all_states & {(0,1)} = {(0,1)}`. Only alive states activate
the R2P strategy. The reach phase is dead code.

With OR: `realizable = all_states | {(0,1)} = all_states`. The R2P strategy activates
from any state, including `(0,0)` where the reach phase drives toward alive.

## Symptom

The idle strategy at `(0,0)` determinizes `!(x' & y')` using CUDD's SolveEqn, which
produces `x'=0, y'=0` — staying at `(0,0)` forever. The cycle strategy at `(0,0)` uses
idle (since `(0,0)` is outside the R2P realizable region), so the system never reaches
alive. FG(y) is violated despite the spec being realizable.

Verified via `--play`: 20 rounds of `trigger=1`, output never includes `out:y`.

## Verification

Run `bash benchmarks/verify_strategies.sh` — this example should PASS after the fix
and FAIL with the old AND code.
