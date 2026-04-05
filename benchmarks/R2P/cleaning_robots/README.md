# Cleaning Robots (R2P)

**Type:** Recurrence-to-Persistence (R2P)
**Result:** REALIZABLE (for all i)
**Generated files:** `cleaning_robots_1.sgrk` through `cleaning_robots_10.sgrk`
**Derived from:** R2R cleaning_robots benchmark (same initial/safety, FG guarantees instead of GF)

## Overview

This is the R2P counterpart of the R2R cleaning robots benchmark. Both versions
model a robot cleaning rooms, but with fundamentally different liveness goals:

- **R2R (original):** The robot must **keep visiting** clean/unclean states
  infinitely often — it bounces between rooms, repeatedly cleaning them.
- **R2P (this version):** The robot must **eventually achieve lasting
  cleanliness** — once a room is cleaned, it stays clean permanently.

The R2P version is realizable because of a critical safety constraint shared
with the R2R version: `(out:clean_i -> X out:clean_i)` — a **latch** that
prevents a cleaned room from becoming dirty again. In R2R this latch is
incidental (the robot just needs to visit clean states). In R2P the latch is
essential — it is what makes permanent cleanliness achievable.

## Scaling Parameter

The parameter `i` controls the **number of rooms**.

| i | Input variables | Output variables | Fairness pairs | Output states |
|---|----------------|-----------------|----------------|---------------|
| 1 | `room0`, `clean0`, `done` (3) | `room0`, `clean0` (2) | 2 | 4 |
| 2 | `room0..1`, `clean0..1`, `done` (5) | `room0..1`, `clean0..1` (4) | 4 | 16 |
| 3 | 7 | 6 | 6 | 64 |
| 5 | 11 | 10 | 10 | 1024 |
| 10 | 21 | 20 | 20 | 1,048,576 |

Each room contributes **two** fairness pairs (one for "clean" and one for
"unclean"), matching the structure of the R2R version.

## Specification (for general i)

```
Initial assumptions:  room_0 & !room_1 & ... & !room_{i-1} &
                      !clean_0 & ... & !clean_{i-1} & !done
Initial guarantees:   room_0 & !room_1 & ... & !room_{i-1} &
                      !clean_0 & ... & !clean_{i-1}
Safety assumptions:   Room movement (at most one room at a time, ordered traversal)
                      Latch: (clean_j -> X clean_j) for each room j
                      Latch: (done -> X done)
                      Freeze on done: room and clean positions freeze
Safety guarantees:    Same structure as assumptions, over output variables.
                      Key: (out:clean_j -> X out:clean_j) — LATCH
Fairness:             ((GF done & GF !in:clean_j) -> (FG out:clean_j))   for each j
                      ((GF done & GF  in:clean_j) -> (FG !out:clean_j))  for each j
```

**Key difference from R2R:** The guarantee side uses `FG` (persistence) instead
of `GF` (recurrence).

## Why Both Implications Are Compatible

At first glance, the two implications per room appear contradictory:
1. `(GF done & GF !in:clean_j) -> FG out:clean_j` — "eventually permanently clean"
2. `(GF done & GF  in:clean_j) -> FG !out:clean_j` — "eventually permanently unclean"

These are **not** contradictory because the environment's latch constraint
`(in:clean_j -> X in:clean_j)` prevents both assumption-sides from being true
simultaneously:

- If the environment's room **stays dirty forever**: `GF !in:clean_j` is true
  but `GF in:clean_j` is false. Only implication 1 fires.
- If the environment's room **eventually becomes permanently clean**:
  `GF in:clean_j` is true but `GF !in:clean_j` is false (it was dirty for only
  finitely many steps). Only implication 2 fires.

The latch makes it an either/or — the environment commits to one behavior per
room, and the system only needs to satisfy the corresponding persistence
guarantee.

---

## Walkthrough: i=1

### Variables

| Type | Variables | Count |
|------|-----------|-------|
| Input | `in:room0`, `in:clean0`, `in:done` | 3 |
| Output | `out:room0`, `out:clean0` | 2 |
| **Total** | | **5** |

### Full Specification (`cleaning_robots_1.sgrk`)

```
"in:room0" & !"in:clean0" & !"in:done" ;
"out:room0" & !"out:clean0" ;
("in:room0") & (X "in:room0") & ("in:room0" -> X "in:room0") &
((!"in:clean0" & X "in:clean0") -> ("in:room0" & X "in:room0")) &
("in:clean0" -> X "in:clean0") &
("in:done" -> X "in:done") &
(X "in:done" -> (X "in:room0" <-> "in:room0")) &
(X "in:done" -> (X "in:clean0" <-> "in:clean0")) ;
("out:room0") & (X "out:room0") & ("out:room0" -> X "out:room0") &
((!"out:clean0" & X "out:clean0") -> ("out:room0" & X "out:room0")) &
("out:clean0" -> X "out:clean0") ;
((GF "in:done" & GF !"in:clean0") -> (FG "out:clean0")) &
((GF "in:done" & GF "in:clean0") -> (FG !"out:clean0"))
```

### Line-by-line breakdown

| Section | Formula | Meaning |
|---------|---------|---------|
| Initial assumptions | `room0 & !clean0 & !done` | Robot starts at room 0, room is dirty, task not done. |
| Initial guarantees | `room0 & !clean0` | System robot starts at room 0, room marked dirty. |
| Safety assumptions | Position: always at room 0 | Single-room case: robot cannot leave. |
| Safety assumptions | `clean0 -> X clean0` | **Latch**: once the env room is clean, it stays clean. |
| Safety assumptions | `done -> X done` | **Latch**: once done, stays done. |
| Safety assumptions | Freeze on done | When done triggers, room and clean state freeze. |
| Safety guarantees | Position: always at room 0 | Single-room case: system robot stays at room 0. |
| Safety guarantees | `out:clean0 -> X out:clean0` | **Latch**: once the system marks room clean, it stays clean. |
| Safety guarantees | To clean, must be at the room | Cleaning requires being present. |
| Fairness (pair 1) | `(GF done & GF !clean0) -> FG out:clean0` | If env keeps signaling work and room stays dirty, eventually permanently mark it clean. |
| Fairness (pair 2) | `(GF done & GF clean0) -> FG !out:clean0` | If env room becomes permanently clean, eventually permanently mark it unclean. |

### State space

The output has 2 variables (`room0`, `clean0`), but `room0` is always true
(single room — safety forces the robot to stay). So the effective state space
is just `clean0 ∈ {0, 1}`.

```
[clean0 = 0]  ──── system chooses to clean ────→  [clean0 = 1]
     │                                                  │
     └──── can stay dirty ────┘                        └──── LATCHED (stays forever) ────┘
```

### Winning strategy

**If the environment room stays dirty** (implication 1 fires):
1. Start at `clean0 = 0`.
2. At any step, set `clean0 = 1`.
3. The latch ensures `clean0 = 1` forever. `FG out:clean0` is satisfied.

**If the environment room becomes permanently clean** (implication 2 fires):
1. Start at `clean0 = 0`.
2. Never set `clean0 = 1` (just stay at `clean0 = 0`).
3. `clean0 = 0` at every step. `FG !out:clean0` is satisfied.

The system can simply observe which environment behavior occurs and respond
accordingly. In practice, the synthesized strategy doesn't need to "observe" —
the game-theoretic solution handles both cases.

---

## Walkthrough: i=2

### Variables

| Type | Variables | Count |
|------|-----------|-------|
| Input | `in:room0`, `in:room1`, `in:clean0`, `in:clean1`, `in:done` | 5 |
| Output | `out:room0`, `out:room1`, `out:clean0`, `out:clean1` | 4 |
| **Total** | | **9** |

### Full Specification (`cleaning_robots_2.sgrk`)

```
"in:room0" & !"in:room1" & !"in:clean0" & !"in:clean1" & !"in:done" ;
"out:room0" & !"out:room1" & !"out:clean0" & !"out:clean1" ;
<safety assumptions: room movement, clean latches, done latch, freeze> ;
<safety guarantees: room movement, clean latches, cleaning requires presence> ;
((GF "in:done" & GF !"in:clean0") -> (FG "out:clean0")) &
((GF "in:done" & GF !"in:clean1") -> (FG "out:clean1")) &
((GF "in:done" & GF "in:clean0") -> (FG !"out:clean0")) &
((GF "in:done" & GF "in:clean1") -> (FG !"out:clean1"))
```

### Key safety constraints

**Room movement** (same for input and output):
- Must always be at exactly one room: `(room0 | room1)` and `(room1 -> !room0)`.
- Ordered traversal: from room 0, can go to room 0 or room 1; from room 1,
  must stay at room 1 (rightward-only movement).
- `(room1 -> X room1)` — once at room 1, stay there.

**Cleaning constraints**:
- `(out:clean_j -> X out:clean_j)` — **latch** for each room.
- `(!out:clean_j & X out:clean_j) -> (out:room_j & X out:room_j)` — to clean
  room j, robot must be at room j and stay there.

### State space

With 4 output variables, there are 16 possible output states. But room
constraints reduce the effective space: the robot is at exactly one room, and
clean flags are latched.

The key reachable sequences:
```
Step 0:  room=0, clean0=0, clean1=0  (start)
Step 1:  robot can stay at room 0 and set clean0=1
Step 2:  robot moves to room 1, clean0 stays 1 (latched)
Step 3:  robot at room 1, sets clean1=1
Step 4+: robot at room 1, clean0=1, clean1=1 (both latched, permanent)
```

### Winning strategy

1. Start at room 0, both rooms dirty.
2. Clean room 0 (set `clean0 = 1`). The latch keeps it clean.
3. Move to room 1.
4. Clean room 1 (set `clean1 = 1`). The latch keeps it clean.
5. Both rooms are now permanently clean.

This satisfies `FG out:clean0` and `FG out:clean1` — both rooms are clean from
some step onward and remain clean forever.

### What changes from i=1 to i=2

- **Two rooms to clean instead of one.** The robot must visit both rooms and
  clean each one. The ordered traversal constraint means it must clean room 0
  first, then move to room 1.
- **Four fairness pairs instead of two.** Each room contributes a "clean" and
  "unclean" implication.
- **Position planning matters.** The robot can't teleport — it must physically
  traverse rooms in order. The strategy must plan the cleaning sequence.
- **State space grows to 16.** The algorithm must handle room positions, clean
  flags, and their interactions.

---

## Why It Is Realizable (for all i)

The argument follows from three properties:

1. **The latch guarantees permanence.** `(out:clean_j -> X out:clean_j)` means
   that once the system sets a room's clean flag, it can never be reverted. This
   directly enables `FG out:clean_j` — set it once, and it holds forever.

2. **The system can reach every room.** The ordered traversal allows the robot
   to visit room 0, then room 1, ..., then room i-1. At each room, it can
   choose to set the clean flag (or not).

3. **The environment's latches prevent contradictions.** `(in:clean_j -> X
   in:clean_j)` means the environment's clean state for each room is
   monotonic — it starts dirty and either stays dirty forever or becomes
   permanently clean. This means for each room, exactly one of the two fairness
   implications fires, never both. The system only needs to satisfy one
   persistence condition per room.

### Winning strategy (general i):

1. Start at room 0, all rooms dirty.
2. For j = 0, 1, ..., i-1:
   - If the environment room j stays dirty: set `out:clean_j = 1` (latch it).
   - If the environment room j becomes clean: leave `out:clean_j = 0`.
3. Move through rooms in order (0 → 1 → ... → i-1).
4. Once at room i-1, stay there. All clean flags are latched.

## Comparison with R2R Version

| Aspect | R2R | R2P |
|--------|-----|-----|
| Guarantee type | `GF out:clean_j` (visit clean infinitely) | `FG out:clean_j` (eventually permanently clean) |
| Robot behavior | Bounces between rooms forever | Visits each room once, then settles |
| Latch role | Incidental (clean stays clean) | Essential (enables permanence) |
| Strategy | Cycle through rooms, clean repeatedly | Clean each room once, done forever |
| Alive region | Not applicable (R2R uses cycle cover) | `{all relevant clean flags set}` — closed under safety |

## What This Example Tests

This tests R2P on a **realistic, structured specification** derived from a known
R2R benchmark. As i grows:

- **Richer safety constraints** — room movement, cleaning preconditions, and
  latches interact in non-trivial ways.
- **Multiple independent persistence goals** — 2i fairness pairs that must all
  be satisfied.
- **Non-trivial alive region computation** — the alive region is the set of
  output states where all relevant clean flags are set AND the system can remain
  there. The latch constraints make this region non-empty and closed.
- **Strategy requires sequential planning** — unlike simpler examples where the
  system can satisfy all goals in one step, the robot must traverse rooms in
  order, cleaning them sequentially.
