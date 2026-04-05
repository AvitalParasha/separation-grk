# Forced Oscillation

**Type:** Recurrence-to-Persistence (R2P)
**Result:** UNREALIZABLE
**Specification file:** `forced_oscillation.sgrk`

## Overview

This example demonstrates a fundamental contradiction between safety and
persistence. The system controls a single Boolean output `bit` that is forced
by safety constraints to toggle at every step (true, false, true, false, ...).
The fairness condition demands that if the environment triggers infinitely
often, the bit must eventually become permanently true — which is impossible
under forced oscillation.

This is a single-instance example (no scaling parameter) because the
contradiction is self-contained: one oscillating bit already captures the full
difficulty. Adding more independent bits would not create any new challenge.

## Variables

| Type | Variables | Count |
|------|-----------|-------|
| Input | `in:trigger` | 1 |
| Output | `out:bit0` | 1 |
| **Total** | | **2** |

## Full Specification (`forced_oscillation.sgrk`)

```
"in:trigger" ;
"out:bit0" ;
1 ;
("out:bit0" -> !X "out:bit0") &
(!"out:bit0" -> X "out:bit0") ;
((GF "in:trigger") -> (FG "out:bit0"))
```

### Line-by-line breakdown

| Section | Formula | Meaning |
|---------|---------|---------|
| Initial assumptions | `trigger` | Environment starts with trigger = true. |
| Initial guarantees | `bit0` | Bit starts **true**. |
| Safety assumptions | `1` | No constraints on environment transitions. |
| Safety guarantees | `(bit0 -> !X bit0) & (!bit0 -> X bit0)` | **Forced toggle**: if true, must become false next; if false, must become true next. |
| Fairness | `(GF trigger) -> (FG bit0)` | If trigger fires infinitely often, then bit must become **permanently** true. |

## State Space and the Contradiction

Two output states. Safety forces a strict cycle:

```
step 0:  bit0 = 1  (initial guarantee)
step 1:  bit0 = 0  (forced by: bit0 -> !X bit0)
step 2:  bit0 = 1  (forced by: !bit0 -> X bit0)
step 3:  bit0 = 0
  ...forever
```

The system has **no choice** — the toggle is deterministic. The bit
oscillates `1, 0, 1, 0, ...` forever.

`FG bit0` requires: "there exists a step N such that for all steps >= N,
bit0 = true." But bit0 is false at every odd step. So `FG bit0` is **false**.

The environment can keep `trigger = true` at every step, making
`GF trigger` true. The implication `(GF trigger) -> (FG bit0)` then
requires `FG bit0`, which is impossible.

## Why It Is Unrealizable

1. **Safety forces permanent oscillation.** The bit toggles every step:
   `true -> false -> true -> ...`. Since safety assumptions are `1` (always
   true), this toggling holds globally.

2. **Fairness demands eventual stability.** `FG bit0` means "eventually
   `bit0` is true at every step from some point onward." This directly
   contradicts the forced toggling.

3. **The environment can force the issue.** The environment can keep
   `trigger = true` at every step, making `GF trigger` true. This makes
   the fairness implication non-vacuous, requiring `FG bit0`, which the
   system can never deliver.

The system has zero degrees of freedom. The initial guarantee fixes step 0,
and the safety constraints determine every subsequent step. There is exactly
one possible execution trace, and it does not satisfy `FG bit0`. No strategy
can change this.

## What This Example Tests

This tests the algorithm's ability to detect **unrealizability** in the R2P
setting. The safety constraints create a state space where no absorbing
region satisfying the persistence guarantee exists. Specifically:

- **No absorbing state:** the only two states (`bit0=0` and `bit0=1`) form
  a strict 2-cycle. Neither can be maintained permanently.
- **Structural unrealizability:** the contradiction comes from the safety
  constraints making persistence impossible, regardless of the environment's
  behavior. The algorithm should detect this without exhaustive search.
- **Contrast with realizable examples:** unlike stabilize_lock (where the
  system can reach and stay in an absorbing state) or alive_region_pruning
  (where the system can avoid traps), here there is no winning path at all.
