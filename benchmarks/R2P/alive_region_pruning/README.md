# Alive Region Pruning

**Type:** Recurrence-to-Persistence (R2P)
**Result:** REALIZABLE (for all i)
**Generated files:** `alive_region_pruning_1.sgrk` through `alive_region_pruning_10.sgrk`

## Overview

This example features pairs of Boolean outputs whose transitions create a
state space with both absorbing "good" states and deceptive "trap" states.
The system controls i independent pairs `(a_0, b_0)` ... `(a_{i-1}, b_{i-1})`.
For each pair, the state `(a=1, b=1)` is absorbing (stays forever), while
`(a=1, b=0)` is a trap that forces a reset. The algorithm must identify that
only the path through `(1,1)` leads to satisfying the persistence guarantee,
and prune all trap states from the winning region.

## Scaling Parameter

The parameter `i` controls the **number of independent (a, b) pairs**.

| i | Output variables | Fairness pairs | Output states (4^i) |
|---|-----------------|----------------|---------------------|
| 1 | `a0`, `b0` | 1 | 4 |
| 2 | `a0`, `b0`, `a1`, `b1` | 2 | 16 |
| 3 | `a0` ... `a2`, `b0` ... `b2` | 3 | 64 |
| 5 | `a0` ... `a4`, `b0` ... `b4` | 5 | 1024 |
| 10 | `a0` ... `a9`, `b0` ... `b9` | 10 | 1,048,576 |

Each pair has 4 possible states `(a_j, b_j) ∈ {(0,0), (0,1), (1,0), (1,1)}`,
so the total output state space is 4^i. The single input variable `in:trigger`
is shared across all scales.

## Specification (for general i)

```
Initial assumptions:  1 (none)
Initial guarantees:   !a_0 & !b_0 & !a_1 & !b_1 & ... & !a_{i-1} & !b_{i-1}
Safety assumptions:   1 (none)
Safety guarantees:    For each pair j = 0 ... i-1:
                        (a_j & !b_j) -> !X a_j    (trap: from (1,0), a resets)
                        (a_j &  b_j) ->  X a_j    (absorbing: (1,1) keeps a)
                        (a_j &  b_j) ->  X b_j    (absorbing: (1,1) keeps b)
Fairness:             ((GF trigger) -> (FG a_0)) &
                      ((GF trigger) -> (FG a_1)) &
                      ...
                      ((GF trigger) -> (FG a_{i-1}))
```

Each pair is **independent**: its safety constraints only involve its own
variables, and its fairness condition only requires persistence of its own `a`.

## State Space Analysis (per pair)

Each pair `(a_j, b_j)` has the following transition structure:

```
(0,0) ──── no constraints ────→ any of {(0,0), (0,1), (1,0), (1,1)}
(0,1) ──── no constraints ────→ any of {(0,0), (0,1), (1,0), (1,1)}
(1,0) ──── TRAP ──────────────→ must go to (0,0) or (0,1)  [a forced to 0]
(1,1) ──── ABSORBING ─────────→ must stay at (1,1)          [a and b stay 1]
```

The key states:
- **(1,1) is absorbing:** once reached, the system stays here forever,
  satisfying `FG a_j`.
- **(1,0) is a trap:** entering it forces `a_j` back to 0 on the next step,
  breaking any attempt at persistence. The system must **avoid** this state.

---

## Walkthrough: i=1

### Variables

| Type | Variables | Count |
|------|-----------|-------|
| Input | `in:trigger` | 1 |
| Output | `out:a0`, `out:b0` | 2 |
| **Total** | | **3** |

### Full Specification (`alive_region_pruning_1.sgrk`)

```
1 ;
!"out:a0" &
!"out:b0" ;
1 ;
(("out:a0" & !"out:b0") -> !X "out:a0") &
(("out:a0" & "out:b0") -> X "out:a0") &
(("out:a0" & "out:b0") -> X "out:b0") ;
((GF "in:trigger") -> (FG "out:a0"))
```

#### Line-by-line breakdown

| Section | Formula | Meaning |
|---------|---------|---------|
| Initial assumptions | `1` | No constraints on environment. |
| Initial guarantees | `!a0 & !b0` | Both outputs start **false** → state `(0,0)`. |
| Safety assumptions | `1` | No constraints on environment transitions. |
| Safety guarantee 1 | `(a0 & !b0) -> !X a0` | **Trap rule**: from state `(1,0)`, `a0` must become 0 next step. |
| Safety guarantee 2 | `(a0 & b0) -> X a0` | **Absorb rule**: from state `(1,1)`, `a0` stays 1. |
| Safety guarantee 3 | `(a0 & b0) -> X b0` | **Absorb rule**: from state `(1,1)`, `b0` stays 1. |
| Fairness | `(GF trigger) -> (FG a0)` | If trigger recurs, `a0` must become permanently true. |

#### State space (4 states)

```
        ┌─────────┐         ┌─────────┐
        │  (0,0)  │ ──────→ │  (1,1)  │ ←─── ABSORBING
        │  START  │         │  GOAL   │ ───→ stays here
        └─────────┘         └─────────┘
             │                   ↑
             │                   │
             ↓                   │
        ┌─────────┐         ┌─────────┐
        │  (0,1)  │ ──────→ │  (1,0)  │ ←─── TRAP
        │         │         │         │ ───→ forced to (0,x)
        └─────────┘         └─────────┘
```

From `(0,0)` and `(0,1)`, the system has free choice (no safety constraints
apply). From `(1,0)`, the system is forced back to `a0=0`. From `(1,1)`,
the system must stay.

#### Winning strategy

1. Start at `(0,0)` (required by initial guarantee).
2. On the next step, set `a0 = 1` and `b0 = 1` → move to `(1,1)`.
3. Safety keeps the system at `(1,1)` forever.
4. `a0 = 1` at every step from step 1 onward → `FG a0` satisfied.

**Critical mistake to avoid:** If the system goes to `(1,0)` instead of
`(1,1)`, the trap rule forces `a0` back to 0 on the next step. The system
would have to try again, wasting a step. The winning strategy avoids `(1,0)`
entirely.

---

## Walkthrough: i=2

### Variables

| Type | Variables | Count |
|------|-----------|-------|
| Input | `in:trigger` | 1 |
| Output | `out:a0`, `out:b0`, `out:a1`, `out:b1` | 4 |
| **Total** | | **5** |

### Full Specification (`alive_region_pruning_2.sgrk`)

```
1 ;
!"out:a0" &
!"out:a1" &
!"out:b0" &
!"out:b1" ;
1 ;
(("out:a0" & !"out:b0") -> !X "out:a0") &
(("out:a0" & "out:b0") -> X "out:a0") &
(("out:a0" & "out:b0") -> X "out:b0") &
(("out:a1" & !"out:b1") -> !X "out:a1") &
(("out:a1" & "out:b1") -> X "out:a1") &
(("out:a1" & "out:b1") -> X "out:b1") ;
((GF "in:trigger") -> (FG "out:a0")) &
((GF "in:trigger") -> (FG "out:a1"))
```

#### Line-by-line breakdown

| Section | Formula | Meaning |
|---------|---------|---------|
| Initial assumptions | `1` | No constraints. |
| Initial guarantees | `!a0 & !a1 & !b0 & !b1` | All outputs start false → both pairs at `(0,0)`. |
| Safety assumptions | `1` | No constraints. |
| Safety (pair 0) | Trap: `(a0 & !b0) -> !X a0` | From `(1,0)`, pair 0's `a0` resets. |
| Safety (pair 0) | Absorb: `(a0 & b0) -> X a0` and `-> X b0` | From `(1,1)`, pair 0 stays locked. |
| Safety (pair 1) | Trap: `(a1 & !b1) -> !X a1` | From `(1,0)`, pair 1's `a1` resets. |
| Safety (pair 1) | Absorb: `(a1 & b1) -> X a1` and `-> X b1` | From `(1,1)`, pair 1 stays locked. |
| Fairness (pair 0) | `(GF trigger) -> (FG a0)` | `a0` must become permanently true. |
| Fairness (pair 1) | `(GF trigger) -> (FG a1)` | `a1` must become permanently true. |

#### State space (16 output states)

Each pair independently has 4 states, so there are 4 × 4 = 16 total output
states. The combined state is `(pair0_state, pair1_state)`.

The winning region is the single absorbing state where **both** pairs are at
`(1,1)`:

```
pair 0 at (1,1) AND pair 1 at (1,1)  →  a0=1, b0=1, a1=1, b1=1
```

Any state where at least one pair is at `(1,0)` is losing. For example:

| State | pair 0 | pair 1 | Status |
|-------|--------|--------|--------|
| `a0=1, b0=1, a1=1, b1=1` | (1,1) absorbing | (1,1) absorbing | **WINNING** — both FG satisfied |
| `a0=1, b0=1, a1=1, b1=0` | (1,1) absorbing | (1,0) **trap** | **LOSING** — pair 1 will reset |
| `a0=1, b0=0, a1=1, b1=1` | (1,0) **trap** | (1,1) absorbing | **LOSING** — pair 0 will reset |
| `a0=0, b0=0, a1=0, b1=0` | (0,0) free | (0,0) free | Winning — can reach (1,1,1,1) |

#### Winning strategy

1. Start at `(a0=0, b0=0, a1=0, b1=0)` (initial guarantee).
2. On the next step, set all four outputs to 1: `a0=b0=a1=b1=1`.
3. Both pairs are now at `(1,1)`. Safety keeps them there forever.
4. Both `FG a0` and `FG a1` are satisfied from step 1 onward.

**Critical mistake to avoid:** If the system sets `a0=1, b0=0` (putting
pair 0 into the trap), then on the next step `a0` is forced back to 0.
Meanwhile pair 1 might be fine at `(1,1)`, but pair 0 has to start over.
The system must set **both** `a` and `b` together for each pair.

#### What changes from i=1 to i=2

- **Two independent pairs** with two independent traps. The system must
  avoid `(1,0)` for **both** pairs simultaneously.
- **State space quadruples** (4 → 16 states). Out of the 16 states, only 1
  is the winning absorbing state, while 7 states contain at least one pair
  in the trap configuration.
- **The algorithm must prune more states.** At i=1, only state `(1,0)` is
  pruned. At i=2, any state where pair 0 or pair 1 (or both) is at `(1,0)`
  must be pruned — that's 7 out of 16 states.
- **Two fairness conditions** must both be satisfied, requiring the algorithm
  to verify that the absorbing state satisfies all persistence conditions
  simultaneously.

---

## Why It Is Realizable (for all i)

The winning strategy is to move **every** pair from the initial state `(0,0)`
directly to `(1,1)` on the first step. Since:

- From `(0,0)` there are no constraints preventing the transition to `(1,1)`.
- Once at `(1,1)`, each pair stays there forever (absorbing).
- All `a_j` are then permanently true, satisfying `FG a_j` for every j.

The pairs are independent, so the system can handle them all at once. The
strategy works at any scale.

## What This Example Tests

This tests the algorithm's **alive region pruning** capability at increasing
scale. As i grows:

- **More traps to prune** — each pair contributes a trap state `(1,0)`, and
  any combination where at least one pair is in its trap must be pruned.
  The number of "partially trapped" states grows exponentially.
- **Exponential state space** — 4^i output states (over 1 million at i=10),
  stressing BDD operations.
- **Independent subsystems** — the algorithm should ideally exploit the
  independence between pairs. BDDs naturally handle this through variable
  ordering, but the scaling still tests the efficiency of the SCC
  decomposition and pruning.

The trap state `(a_j=1, b_j=0)` is reachable and has defined successors, so
it appears to be a valid part of the game graph. However, it cannot
participate in any winning strategy because it forces the system out of the
persistence region. The algorithm must correctly identify and exclude all such
states across all pairs.
