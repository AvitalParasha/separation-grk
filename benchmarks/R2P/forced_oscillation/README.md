# Forced Oscillation

**Type:** Recurrence-to-Persistence (R2P)
**Result:** UNREALIZABLE (for all i)
**Generated files:** `forced_oscillation_1.sgrk` through `forced_oscillation_10.sgrk`

## Overview

This example demonstrates a fundamental contradiction between safety and
persistence. The system controls i independent Boolean outputs
`bit_0` ... `bit_{i-1}`, each forced by safety constraints to toggle at every
step (true, false, true, false, ...). The fairness condition demands that if
the environment triggers infinitely often, each bit must eventually become
permanently true — which is impossible under forced oscillation.

## Scaling Parameter

The parameter `i` controls the **number of independently oscillating bits**.

| i | Output variables | Fairness pairs | Output states (2^i) |
|---|-----------------|----------------|---------------------|
| 1 | `bit0` | 1 | 2 |
| 2 | `bit0`, `bit1` | 2 | 4 |
| 3 | `bit0`, `bit1`, `bit2` | 3 | 8 |
| 5 | `bit0` ... `bit4` | 5 | 32 |
| 10 | `bit0` ... `bit9` | 10 | 1024 |

The single input variable `in:trigger` is shared across all scales.

## Specification (for general i)

```
Initial assumptions:  trigger (trigger starts true)
Initial guarantees:   bit_0 & bit_1 & ... & bit_{i-1}  (all start true)
Safety assumptions:   1 (none)
Safety guarantees:    (bit_0 -> !X bit_0) & (!bit_0 -> X bit_0) &
                      (bit_1 -> !X bit_1) & (!bit_1 -> X bit_1) &
                      ...
                      (bit_{i-1} -> !X bit_{i-1}) & (!bit_{i-1} -> X bit_{i-1})
Fairness:             ((GF trigger) -> (FG bit_0)) &
                      ((GF trigger) -> (FG bit_1)) &
                      ...
                      ((GF trigger) -> (FG bit_{i-1}))
```

Each bit is **independent**: it has its own toggle constraint and its own
fairness pair.

---

## Walkthrough: i=1

### Variables

| Type | Variables | Count |
|------|-----------|-------|
| Input | `in:trigger` | 1 |
| Output | `out:bit0` | 1 |
| **Total** | | **2** |

### Full Specification (`forced_oscillation_1.sgrk`)

```
"in:trigger" ;
"out:bit0" ;
1 ;
("out:bit0" -> !X "out:bit0") &
(!"out:bit0" -> X "out:bit0") ;
((GF "in:trigger") -> (FG "out:bit0"))
```

#### Line-by-line breakdown

| Section | Formula | Meaning |
|---------|---------|---------|
| Initial assumptions | `trigger` | Environment starts with trigger = true. |
| Initial guarantees | `bit0` | Bit starts **true**. |
| Safety assumptions | `1` | No constraints on environment transitions. |
| Safety guarantees | `(bit0 -> !X bit0) & (!bit0 -> X bit0)` | **Forced toggle**: if true, must become false next; if false, must become true next. |
| Fairness | `(GF trigger) -> (FG bit0)` | If trigger fires infinitely often, then bit must become **permanently** true. |

#### State space and the contradiction

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

`FG bit0` requires: "there exists a step N such that for all steps ≥ N,
bit0 = true." But bit0 is false at every odd step. So `FG bit0` is **false**.

The environment can keep `trigger = true` at every step, making
`GF trigger` true. The implication `(GF trigger) -> (FG bit0)` then
requires `FG bit0`, which is impossible.

#### Why no strategy exists

The system has zero degrees of freedom. The initial guarantee fixes step 0,
and the safety constraints determine every subsequent step. There is exactly
one possible execution trace, and it does not satisfy `FG bit0`. No strategy
can change this.

---

## Walkthrough: i=2

### Variables

| Type | Variables | Count |
|------|-----------|-------|
| Input | `in:trigger` | 1 |
| Output | `out:bit0`, `out:bit1` | 2 |
| **Total** | | **3** |

### Full Specification (`forced_oscillation_2.sgrk`)

```
"in:trigger" ;
"out:bit0" &
"out:bit1" ;
1 ;
("out:bit0" -> !X "out:bit0") &
(!"out:bit0" -> X "out:bit0") &
("out:bit1" -> !X "out:bit1") &
(!"out:bit1" -> X "out:bit1") ;
((GF "in:trigger") -> (FG "out:bit0")) &
((GF "in:trigger") -> (FG "out:bit1"))
```

#### Line-by-line breakdown

| Section | Formula | Meaning |
|---------|---------|---------|
| Initial assumptions | `trigger` | Trigger starts true. |
| Initial guarantees | `bit0 & bit1` | Both bits start **true**. |
| Safety assumptions | `1` | No constraints on environment. |
| Safety guarantees | Toggle rules for bit0 AND toggle rules for bit1 | Both bits independently forced to toggle every step. |
| Fairness (pair 1) | `(GF trigger) -> (FG bit0)` | bit0 must become permanently true. |
| Fairness (pair 2) | `(GF trigger) -> (FG bit1)` | bit1 must become permanently true. |

#### State space and the contradiction

Four output states: `(bit0, bit1) ∈ {(0,0), (0,1), (1,0), (1,1)}`.

Since both bits toggle independently and in lock-step (both start true), the
execution is fully determined:

```
step 0:  (1, 1)   initial guarantees
step 1:  (0, 0)   both toggle: true → false
step 2:  (1, 1)   both toggle: false → true
step 3:  (0, 0)
  ...forever cycling between (1,1) and (0,0)
```

The system visits only 2 of the 4 possible states, in a strict 2-cycle. Neither
`FG bit0` nor `FG bit1` can be satisfied, since both bits are false at every
odd step.

#### Why no strategy exists

Just like i=1, the system has zero degrees of freedom. Both bits are
deterministically locked into oscillation. The only execution trace cycles
between `(1,1)` and `(0,0)`, never settling. The environment keeps triggering,
making both fairness implications non-vacuous, but neither persistence
condition can be met.

#### What changes from i=1 to i=2

- **Two contradictions instead of one.** Both `FG bit0` and `FG bit1` are
  independently impossible. Even if one could somehow be satisfied, the other
  still fails.
- **State space doubles** (2 → 4 states), but only 2 are reachable due to
  the lock-step toggling.
- **The algorithm must handle multiple fairness pairs**, each independently
  unsatisfiable, and correctly conclude unrealizability.

---

## Why It Is Unrealizable (for all i)

The argument is the same at every scale:

1. **Safety forces permanent oscillation.** Each bit toggles every step:
   `true → false → true → ...`. Since safety assumptions are `1` (always
   true), this toggling holds globally.

2. **Fairness demands eventual stability.** `FG bit_j` means "eventually
   `bit_j` is true at every step from some point onward." This directly
   contradicts the forced toggling.

3. **The environment can force the issue.** The environment can keep
   `trigger = true` at every step, making `GF trigger` true. This makes
   every fairness implication non-vacuous, requiring `FG bit_j` for all j,
   which the system can never deliver.

Even a single oscillating bit is enough to make the spec unrealizable. Adding
more bits adds more independent contradictions.

## What This Example Tests

This tests the algorithm's ability to detect unrealizability in the R2P
setting at increasing scale. As i grows, the algorithm must handle:

- **More contradictions to detect** — i independent persistence conditions,
  each individually impossible.
- **Larger state space** — 2^i output states, all of which cycle rather than
  converge.
- **No absorbing region** — the state space has no strongly connected
  component where any persistence guarantee can be satisfied. The algorithm
  must determine this efficiently.

The unrealizability is "structural" — it comes from the safety constraints
making persistence impossible, regardless of the environment's behavior. The
algorithm should detect this without exhaustive search.
