# Stabilize Lock

**Type:** Recurrence-to-Persistence (R2P)
**Result:** REALIZABLE (for all i)
**Generated files:** `stabilize_lock_1.sgrk` through `stabilize_lock_10.sgrk`

## Overview

This is the simplest R2P example: a collection of one-way latches. The system
controls i independent Boolean outputs `locked_0` ... `locked_{i-1}`, each
starting false. Once a lock is set to true, it can never go back to false.
The fairness condition requires that if the environment triggers infinitely
often, the system must eventually lock **every** lock permanently.

## Scaling Parameter

The parameter `i` controls the **number of independent locks**.

| i | Output variables | Fairness pairs | Output states (2^i) |
|---|-----------------|----------------|---------------------|
| 1 | `locked0` | 1 | 2 |
| 2 | `locked0`, `locked1` | 2 | 4 |
| 3 | `locked0`, `locked1`, `locked2` | 3 | 8 |
| 5 | `locked0` ... `locked4` | 5 | 32 |
| 10 | `locked0` ... `locked9` | 10 | 1024 |

The single input variable `in:trigger` is shared across all scales.

## Specification (for general i)

```
Initial assumptions:  1 (none)
Initial guarantees:   !locked_0 & !locked_1 & ... & !locked_{i-1}
Safety assumptions:   1 (none)
Safety guarantees:    (locked_0 -> X locked_0) &
                      (locked_1 -> X locked_1) &
                      ...
                      (locked_{i-1} -> X locked_{i-1})
Fairness:             ((GF trigger) -> (FG locked_0)) &
                      ((GF trigger) -> (FG locked_1)) &
                      ...
                      ((GF trigger) -> (FG locked_{i-1}))
```

Each lock is **independent**: it has its own safety constraint (once true,
stays true) and its own fairness pair (must eventually become permanently
true).

---

## Walkthrough: i=1

### Variables

| Type | Variables | Count |
|------|-----------|-------|
| Input | `in:trigger` | 1 |
| Output | `out:locked0` | 1 |
| **Total** | | **2** |

### Full Specification (`stabilize_lock_1.sgrk`)

```
1 ;
!"out:locked0" ;
1 ;
("out:locked0" -> X "out:locked0") ;
((GF "in:trigger") -> (FG "out:locked0"))
```

#### Line-by-line breakdown

| Section | Formula | Meaning |
|---------|---------|---------|
| Initial assumptions | `1` | No constraints on environment. |
| Initial guarantees | `!"out:locked0"` | Lock starts **unlocked** (false). |
| Safety assumptions | `1` | No constraints on environment transitions. |
| Safety guarantees | `locked0 -> X locked0` | **Latch**: once locked, stays locked forever. |
| Fairness | `(GF trigger) -> (FG locked0)` | If trigger fires infinitely often, then locked must become **permanently** true. |

#### State space

Two output states: `locked0 = 0` (unlocked) and `locked0 = 1` (locked).

```
 [unlocked]  ──── system chooses ────→  [locked]
     │                                     │
     └──── can stay here ────┘             └──── must stay here (safety) ────┘
```

#### Winning strategy

1. Start at `locked0 = 0` (required by initial guarantee).
2. On the next step, set `locked0 = 1`.
3. Safety ensures `locked0` stays `1` forever.
4. `FG locked0` is satisfied from step 1 onward.

The system wins regardless of what the environment does with `trigger`.

---

## Walkthrough: i=2

### Variables

| Type | Variables | Count |
|------|-----------|-------|
| Input | `in:trigger` | 1 |
| Output | `out:locked0`, `out:locked1` | 2 |
| **Total** | | **3** |

### Full Specification (`stabilize_lock_2.sgrk`)

```
1 ;
!"out:locked0" &
!"out:locked1" ;
1 ;
("out:locked0" -> X "out:locked0") &
("out:locked1" -> X "out:locked1") ;
((GF "in:trigger") -> (FG "out:locked0")) &
((GF "in:trigger") -> (FG "out:locked1"))
```

#### Line-by-line breakdown

| Section | Formula | Meaning |
|---------|---------|---------|
| Initial assumptions | `1` | No constraints on environment. |
| Initial guarantees | `!locked0 & !locked1` | Both locks start **unlocked**. |
| Safety assumptions | `1` | No constraints on environment transitions. |
| Safety guarantees | `(locked0 -> X locked0) & (locked1 -> X locked1)` | **Two independent latches**: once either lock is set, it stays set forever. |
| Fairness (pair 1) | `(GF trigger) -> (FG locked0)` | If trigger recurs, `locked0` must become permanently true. |
| Fairness (pair 2) | `(GF trigger) -> (FG locked1)` | If trigger recurs, `locked1` must become permanently true. |

#### State space

Four output states: `(locked0, locked1) ∈ {(0,0), (0,1), (1,0), (1,1)}`.

```
(0,0) ──→ can go anywhere
(0,1) ──→ can go to (0,1) or (1,1)     [locked1 latched]
(1,0) ──→ can go to (1,0) or (1,1)     [locked0 latched]
(1,1) ──→ must stay at (1,1)            [both latched, ABSORBING]
```

The state `(1,1)` is the only absorbing state where both `FG locked0` and
`FG locked1` are satisfied.

#### Winning strategy

1. Start at `(0,0)` (required by initial guarantee).
2. On the next step, set both `locked0 = 1` and `locked1 = 1`.
3. Safety keeps both locked forever: stuck at `(1,1)`.
4. Both `FG locked0` and `FG locked1` are satisfied.

Alternatively, the system could lock them one at a time (e.g., step 1: set
`locked0 = 1`, step 2: set `locked1 = 1`). The intermediate state `(1,0)` is
safe because `locked0` is latched and won't revert. Either way, the system
reaches `(1,1)` and stays there.

#### What changes from i=1 to i=2

- **One more latch, one more fairness pair.** The system must satisfy two
  independent persistence conditions instead of one.
- **The absorbing state is now a conjunction.** The system must reach the
  single state where **all** locks are true, not just one.
- **State space doubles** (2 → 4 states). The algorithm must verify that the
  all-true state is reachable and absorbing.

---

## Why It Is Realizable (for all i)

The system has full control over when to set each `locked_j = true`, and the
safety constraint ensures each stays true forever once set. A winning
strategy is: set all locks to true on the very first step. After that, all
locks remain true for all future steps, satisfying `FG locked_j` for every j,
regardless of the environment's behavior.

The locks are independent — there is no constraint preventing the system from
setting multiple locks simultaneously. This means the problem does not become
harder strategically as i grows, only in terms of state space size.

## What This Example Tests

This tests the most basic scalable R2P pattern: reacting to a recurrent input
stimulus by stabilizing multiple outputs into permanent states. As i grows,
the algorithm must handle:

- **More persistence guarantees** — i separate `FG` conditions that must all
  hold simultaneously.
- **Larger state space** — 2^i output states, making BDD operations more
  expensive.
- **SCC analysis at scale** — the algorithm must identify the single
  absorbing state (all locks true) within an exponentially growing game graph.

The strategic difficulty remains constant (the winning strategy is trivial),
but the computational difficulty scales with i.
