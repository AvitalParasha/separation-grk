# Implementation Plan: R2P (Recurrence to Persistence) Support

## Context

The existing tool solves **R2R games** (Recurrence to Recurrence): `GF(a) → GF(g)` — if assumptions recur infinitely often, guarantees must recur infinitely often.

We are extending it to solve **R2P games** (Recurrence to Persistence): `GF(a) → FG(g)` — if assumptions recur infinitely often, guarantees must eventually hold permanently (stabilize).

This is described in the FMCAD26 paper (Section VII.C "Solving R2P Games"). The key algorithmic difference: instead of checking if the system can **cycle through** guarantee states (R2R), we check if the system can **reach and permanently maintain** a region where all guarantees hold simultaneously (R2P).

## What Changes (and What Doesn't)

**Changes required:**
1. Parser — support `FG` on guarantee side (currently only `GF`)
2. Spec data structure — record implication type (R2R vs R2P)
3. CycleCover — different "accepting SCC" definition for R2P
4. CycleCover strategy — "reach and maintain" instead of "cycle through"

**No changes needed:**
- WeakFGGame / WeakFGGameSolver — they take `accepting_states` from CycleCover; the game-solving algorithm is identical
- SeparationGrkSolver — same pipeline
- SeparationGrkStrategy — same three-phase structure (initial → reach → cycle/maintain)
- SpaceConnectivity — same reachability/bipath computation

## Detailed Changes

### 1. Spec Data Structure (`src/SeparationGrkSpec.h`)

Add an enum and a type field to `SeparationGrkImplication`:

```cpp
enum class ImplicationType { R2R, R2P };

class SeparationGrkImplication {
    ImplicationType type_;  // NEW
    std::vector<CUDD::BDD> assumptions_;
    std::vector<CUDD::BDD> guarantees_;
public:
    SeparationGrkImplication(ImplicationType type,
                             std::vector<CUDD::BDD> assumptions,
                             std::vector<CUDD::BDD> guarantees);
    ImplicationType Type() const { return type_; }
    // ... existing methods unchanged
};
```

### 2. Parser (`src/sgrk_parser.yy`)

Add a new grammar rule for FG (persistence) justice on the guarantee side:

```yacc
// Existing:
justice: ALWAYS EVENTUAL formula { $$ = $3; }    // G F φ

// New:
persistence: EVENTUAL ALWAYS formula { $$ = $3; }  // F G φ

// New rules for FG guarantee lists:
out_persistences: persistences { $$ = std::move($1); };
persistences: persistence { $$ = std::vector<CUDD::BDD>({ $1 }); }
| persistence AND persistences { /* append */ };

// Extend justice_implication to handle both R2R and R2P:
justice_implication:
  LEFT LEFT in_justices RIGHT IFTHEN LEFT out_justices RIGHT RIGHT
  { $$ = SeparationGrkImplication(ImplicationType::R2R, $3, $7); }
| LEFT LEFT in_justices RIGHT IFTHEN LEFT out_persistences RIGHT RIGHT
  { $$ = SeparationGrkImplication(ImplicationType::R2P, $3, $7); }
;
```

The parser auto-detects R2R vs R2P based on whether guarantees use `GF` or `FG`.

### 2.5. Input Validation (`src/Main.cpp`)

After parsing, validate that all implications are the same type (no mixing R2R and R2P):

```cpp
// After: const SGrk::SeparationGrkSpec& spec = driver.spec;
// Before: SGrk::SeparationGrkSolver solver(mgr, vars, spec);

const auto& implications = spec.JusticeImplications();
if (!implications.empty()) {
    SGrk::ImplicationType expected_type = implications[0].Type();
    for (std::size_t i = 1; i < implications.size(); ++i) {
        if (implications[i].Type() != expected_type) {
            std::cerr << "Error: mixed R2R (GF->GF) and R2P (GF->FG) "
                      << "implications are not supported. "
                      << "All implications must use the same type."
                      << std::endl;
            return 1;
        }
    }
}
```

This check goes in `Main.cpp` between line 119 (spec parsed) and line 121 (solver created). If the user writes a `.sgrk` file with some implications using `GF` guarantees and others using `FG` guarantees, the tool exits with a clear error message.

### 3. CycleCover — Covered Region (`src/CycleCover.cpp`)

**R2R (existing, unchanged):**
For each guarantee g_j: `can_satisfy &= HasCycle(system_bipath, g_j)`
→ "can the system cycle through each guarantee individually?"

**R2P (new — Definition 7 from paper):**
**Condition 1:** There exists a cycle C in S_O where ALL guarantees hold at every state.
**Condition 2:** Some assumption can't hold in S (same as R2R).

In BDD terms, Condition 1 becomes a **safety fixpoint** on the output graph.

#### How ComputeAliveRegion Works — Step-by-Step

**Goal:** Find all output states where (1) every guarantee holds, AND (2) the system can stay in such states forever.

**Setup:** `alive` starts as the set of ALL output states where every guarantee is true. But some of these states might be "dead ends" — forced to transition to a state where some guarantee is violated. We need to remove those.

**Each iteration of the loop does this (from inside out):**

1. `UnprimedToPrimed(alive)` — shifts `alive` from current-state vars O to next-state vars O', giving `alive(O')` = "the NEXT state is in alive"

2. `safety_guarantees & UnprimedToPrimed(alive)` — AND the transition relation `ρ_O(O, O')` with `alive(O')`. Result: transitions that **land in alive** = "the system CAN go from O to O', and O' is in alive"

3. `Exists(PrimedOutputs, ...)` — existentially quantify away O'. Result: "there EXISTS some next state O' in alive that the system can reach" = **"state O has at least one successor in alive"**

4. `alive & ...` — intersect with current `alive`. Result: "state O is in alive AND has a successor in alive"

**What each iteration removes:** States in `alive` that have **no successor** in `alive` — states where every guarantee holds NOW, but the system would be forced to leave the all-guarantees region on the next step.

**Concrete walkthrough:**

States {A, B, C, D} with transitions A→B, A→D, B→C, C→A, D→D.
Guarantees: g₁ holds at {A, B, D}, g₂ holds at {A, C, D}.

- `all_g = {A, D}` (only A and D satisfy BOTH g₁ and g₂)
- **Iteration 1:** `alive = {A, D}`
  - A's successors: B (not in alive), D (**yes**) → A survives
  - D's successors: D (**yes**) → D survives
  - `new_alive = {A, D}` = `alive` → **fixpoint**, return `{A, D}`

Now if D didn't satisfy g₂:
- `all_g = {A}`
- **Iteration 1:** A's successors: B (no), D (no) → A removed → `alive = {}`
- **Iteration 2:** empty, fixpoint → return `{}` → **no cycle where all guarantees hold**

**Why it terminates:** Each iteration only removes states (never adds). Finite set → fixpoint in at most |all_g| iterations.

**Why the result contains cycles:** Every state in the final `alive` has at least one successor also in `alive`. A finite set where every element has a successor must contain a cycle.

**Relation to the FMCAD paper's algorithm:** The paper describes an explicit DFS on the filtered graph; this fixpoint is the standard symbolic (BDD) equivalent. Both are linear time. The fixpoint additionally tells us WHICH states are in cycles (needed for strategy construction).

#### Implementation:

```cpp
// New method: ComputeAliveRegion
CUDD::BDD CycleCover::ComputeAliveRegion(
    const CUDD::BDD& safety_guarantees,
    const std::vector<CUDD::BDD>& guarantees) const {

    // Conjunction of all guarantees: states where ALL hold simultaneously
    CUDD::BDD all_g = mgr_->bddOne();
    for (const auto& g : guarantees) {
        all_g &= g;
    }

    // Safety fixpoint: largest subset of all_g that is closed
    // under system transitions (every state has a successor in the set)
    CUDD::BDD alive = all_g;
    while (true) {
        CUDD::BDD new_alive = alive &
            vars_->Exists(vars_->PrimedOutputs(),
                safety_guarantees & vars_->UnprimedToPrimed(alive));
        if (new_alive == alive) return alive;
        alive = new_alive;
    }
}
```

Then in `ComputeCoveredRegion`, the per-implication logic branches on type:

```cpp
for (const auto& implication : spec.JusticeImplications()) {
    // Assumption side: SAME for both R2R and R2P (GF assumptions)
    CUDD::BDD can_satisfy_assumptions = mgr_->bddOne();
    for (const auto& assumption : implication.Assumptions()) {
        can_satisfy_assumptions &= HasCycle(environment_bipath_relation, assumption);
    }

    CUDD::BDD can_satisfy_guarantees;

    if (implication.Type() == ImplicationType::R2R) {
        // R2R: can cycle through each guarantee individually
        can_satisfy_guarantees = mgr_->bddOne();
        for (const auto& guarantee : implication.Guarantees()) {
            can_satisfy_guarantees &= HasCycle(system_bipath_relation, guarantee);
        }
    } else {  // R2P
        // R2P: exists a cycle where ALL guarantees hold simultaneously
        CUDD::BDD alive = ComputeAliveRegion(
            spec.SafetyGuarantees(), implication.Guarantees());
        can_satisfy_guarantees = HasCycle(system_bipath_relation, alive);
    }

    covered_region &= !can_satisfy_assumptions | can_satisfy_guarantees;
}
```

**Why this is correct (per paper Theorem 3):**
- `alive` = the set of output states where all guarantees hold AND the system can stay forever (trap computation)
- `HasCycle(system_bipath, alive)` = states bipath-connected to alive → states in same SCC that can reach alive
- Since alive is within the SCC and the SCC is strongly connected, the system can reach alive and stay there → FG guarantees satisfied

### 4. CycleCover — Strategy (`src/CycleCover.cpp`)

New method for R2P strategy construction:

```cpp
PathStrategy CycleCover::ComputeR2PPathStrategy(
    const CUDD::BDD& transition_relation,
    const CUDD::BDD& bipath_relation,
    const CUDD::BDD& alive_region) const {

    // Part 0: Reachability strategy toward alive region
    MemorylessStrategy reach_strategy =
        ComputeReachabilityStrategy(transition_relation, bipath_relation, alive_region);

    // Part 1: Maintain strategy — stay in alive forever
    CUDD::BDD maintain_moves = transition_relation &
        alive_region & vars_->UnprimedToPrimed(alive_region);
    MemorylessStrategy maintain_strategy =
        MemorylessStrategy::Determinize(mgr_, vars_, maintain_moves);

    std::vector<MemorylessStrategy> parts = {reach_strategy, maintain_strategy};
    std::vector<CUDD::BDD> stops = {
        alive_region,      // Phase 0 stops when we reach alive
        mgr_->bddZero()   // Phase 1 NEVER stops (stay forever)
    };

    CUDD::BDD realizable = reach_strategy.RealizableRegion() &
                           maintain_strategy.RealizableRegion();
    return PathStrategy(realizable, std::move(parts), std::move(stops));
}
```

Modify `ComputeCycleStrategy` to branch on implication type:

```cpp
for (const auto& implication : spec.JusticeImplications()) {
    PathStrategy path_strategy;

    if (implication.Type() == ImplicationType::R2R) {
        // Existing: cycle through guarantee states
        path_strategy = ComputePathStrategy(
            transition_relation, bipath_relation, implication.Guarantees());
    } else {  // R2P
        // New: reach and maintain alive region
        CUDD::BDD alive = ComputeAliveRegion(
            spec.SafetyGuarantees(), implication.Guarantees());
        path_strategy = ComputeR2PPathStrategy(
            transition_relation, bipath_relation, alive);
    }

    cycle_strategy.Merge(path_strategy);
}
```

**Why this integrates cleanly with CycleStrategy::Merge():**
- The reach phase (Part 0) gets continuation = go to maintain phase (Part 1) — automatic via `constant(i+1)` in Merge
- The maintain phase (Part 1, last part) gets a `last_continuation` from Merge, but its stopping condition is `bddZero()` so the continuation is NEVER evaluated
- The system enters reach → reaches alive → enters maintain → stays forever

### 5. CycleCover Header (`src/CycleCover.h`)

Add declarations for the new methods:

```cpp
CUDD::BDD ComputeAliveRegion(
    const CUDD::BDD& safety_guarantees,
    const std::vector<CUDD::BDD>& guarantees) const;

PathStrategy ComputeR2PPathStrategy(
    const CUDD::BDD& transition_relation,
    const CUDD::BDD& bipath_relation,
    const CUDD::BDD& alive_region) const;
```

## Files to Modify

| File | Change |
|------|--------|
| `src/SeparationGrkSpec.h` | Add `ImplicationType` enum, add `type_` field to `SeparationGrkImplication` |
| `src/sgrk_parser.yy` | Add `FG` grammar rules, update `justice_implication` rule |
| `src/Main.cpp` | Add validation: reject mixed R2R/R2P implications |
| `src/CycleCover.h` | Add `ComputeAliveRegion` and `ComputeR2PPathStrategy` declarations |
| `src/CycleCover.cpp` | Add `ComputeAliveRegion`, `ComputeR2PPathStrategy`; modify `ComputeCoveredRegion` and `ComputeCycleStrategy` to branch on type |

## Files NOT Modified

- `src/WeakFGGame.h/cpp` — accepts `accepting_states` BDD, unchanged
- `src/WeakFGGameSolver.h/cpp` — solves weak Büchi game, unchanged
- `src/SeparationGrkSolver.h/cpp` — same pipeline, unchanged
- `src/SeparationGrkStrategy.h/cpp` — same three phases, unchanged
- `src/SpaceConnectivity.h/cpp` — same connectivity, unchanged
- `src/CycleStrategy.h/cpp` — Merge/Step work correctly as-is for R2P
- `src/SeparationGrkPlayer.h/cpp` — plays using strategy, unchanged

## Verification Plan

### 1. Existing R2R tests must still pass (regression)
```bash
bin/sgrk benchmarks/cleaning_robots/cleaning_robots_2.sgrk \
    --test=benchmarks/cleaning_robots/cleaning_robots_2.test
# All must PASS

for f in benchmarks/**/*.sgrk; do
    echo -n "$(basename $f): "; bin/sgrk "$f"
done
# All must report same results as before
```

### 2. Create an R2P benchmark `.sgrk` file
Write a small R2P spec (e.g., a system that must eventually stabilize into a target state) and verify:
- Parser accepts the `FG` syntax
- Tool reports "Realizable" or "Unrealizable" correctly
- `--play` mode works (system eventually enters and stays in guarantee region)

### 3. Create an R2P `.test` file
Validate BDD outputs against hand-computed expected values.

---

# Previous Content: Project Overview

# Project Overview: SGR(k) — Separated GR(k) Synthesis

## What This Project Is

This is an implementation of the **SGR(k) tool** — a reactive synthesis engine for temporal specifications in the **Separated GR(k)** format. It accompanies the research paper *"Adapting Behaviors via Reactive Synthesis"* by Amram et al. (arXiv:2105.13837).

The core idea: given a temporal specification describing desired system behavior in the presence of an adversarial environment, the tool automatically synthesizes a **winning strategy** (a transducer/controller) that guarantees the specification is met — or determines that no such strategy exists.

---

## The Paper's Contribution

The paper presents a reactive synthesis interpretation of the **Adapter Design Pattern**. The problem: given an existing component (the *Adaptee*) and a desired behavior (the *Target*), synthesize an *Adapter* transducer that composes with the Adaptee to achieve the Target behavior.

### Key Theoretical Insight: Separation

Standard **GR(k)** synthesis (Generalized Reactivity of rank k) has complexity **O(N^(k+1) * k!)** where N is the number of game states. The paper identifies a restricted fragment called **Separated GR(k)** where:

- Every **assumption** depends only on **input** variables
- Every **guarantee** depends only on **output** variables

This separation property enables:
- **Realizability checking** in **O(|phi| + N)** — linear in specification size + game states
- **Strategy synthesis** in **O(|phi| * N)** — a dramatic improvement over general GR(k)

### Motivating Use Cases (from the paper)
1. **Hardware adaptation** — adapting hardware interfaces between incompatible components
2. **Cleaning robots** — coordinating robots to clean rooms under environmental constraints
3. **Railway signalling** — synthesizing safe signal controllers for rail networks

---

## Architecture & Algorithm Pipeline

```
Input (.sgrk file)
  |
  v
Parser (Flex/Bison) --> SeparationGrkSpec
  |
  v
SpaceConnectivity  -- computes reachability & bipath relations via BDD transitive closure
  |
  v
CycleCover  -- finds states where system can satisfy all justice (liveness) conditions
  |
  v
WeakFGGame  -- formulates the synthesis problem as a two-player game on a weak automaton
  |
  v
WeakFGGameSolver  -- solves the game via layer peeling (topological decomposition)
  |
  v
SeparationGrkStrategy  -- extracts and assembles the winning strategy
  |
  v
Output: "Realizable" / "Unrealizable"
  (+ optional: --play, --test, --dumpdot)
```

---

## Key Source Files (`src/`)

| File | Purpose |
|------|---------|
| `Main.cpp` | Entry point, CLI argument handling |
| `Driver.h/cpp` | Parser/scanner coordination |
| `sgrk_parser.yy` / `sgrk_scanner.ll` | Bison/Flex grammar for .sgrk specifications |
| `SeparationGrkSpec.h` | Data structure holding the parsed specification (initial/safety/justice formulas as BDDs) |
| `SeparationGrkSolver.h/cpp` | **Main orchestrator** — chains SpaceConnectivity -> CycleCover -> WeakFGGame -> Solver |
| `SpaceConnectivity.h/cpp` | BDD-based transitive closure for reachability and bipath (mutual reachability) relations |
| `CycleCover.h/cpp` | Computes which states are "covered" (can satisfy all justice implications) and builds cycle strategies |
| `WeakFGGame.h/cpp` | Game representation: states, transitions (antagonist/protagonist), accepting states |
| `WeakFGGameSolver.h/cpp` | **Core algorithm**: layer peeling + reachability/safety fixpoints per layer |
| `SeparationGrkStrategy.h/cpp` | Combines initial strategy, cycle cover, and weak FG strategy into a complete winning strategy |
| `MemorylessStrategy.h/cpp` | Determinizes permissive (set-of-moves) strategies into concrete output functions via CUDD's `SolveEqn` |
| `PermissiveStrategy.h/cpp` | Represents a set of winning states and all winning moves (non-deterministic) |
| `CycleStrategy.h` / `CycleCover.cpp` | Multi-phase strategy for cycling through justice guarantees |
| `SeparationGrkPlayer.h/cpp` | Interactive game player — lets a user play against the synthesized strategy |
| `VarMgr.h/cpp` | BDD variable management: unprimed (current), primed (next-state), temp variables; quantification helpers |
| `TestSet.h/cpp` | Test harness for validating BDD evaluations against expected results |

---

## Core Algorithm Details

### 1. SpaceConnectivity
Computes **transitive closure** of transitions using iterative BDD fixpoint:
- **Environment paths**: reachability under environment (input) transitions alone
- **System paths**: reachability under system (output) transitions alone
- **Combined paths**: reachability under the full transition relation
- **Bipath relation**: mutual reachability (s reaches s' AND s' reaches s) — identifies strongly connected components

### 2. CycleCover
For each justice implication `(GF a1 & ... & GF an) -> (GF g1 & ... & GF gm)`:
- Checks if the environment **can** cycle through all assumptions (via environment bipaths)
- If so, checks if the system **can** cycle through all guarantees (via system bipaths)
- A state is "covered" if for every implication, either the assumptions can't all be satisfied, or the guarantees can all be satisfied

### 3. WeakFGGameSolver (the novel algorithm)
**Layer peeling**: decomposes the game graph into topological layers.

`PeelLayer(states)` extracts the **top layer** — states where every state that can reach them, they can also reach back (i.e., the topologically maximal SCC-like component).

Then processes layers bottom-to-top:
- **Non-accepting layers**: solve **reachability** to previously-known good states
- **Accepting layers**: solve **safety** (avoid previously-known bad states)

This avoids the nested fixpoint iteration of standard GR(k), achieving linear time.

### 4. Strategy Construction — The Three-Phase Winning Strategy

Once the solver determines a specification is realizable, it doesn't just say "yes" — it builds a **concrete strategy** that tells the system exactly what outputs to produce at every step. This strategy has three phases that work together like a state machine:

#### Phase 1: Initial Strategy (`SeparationGrkSolver.cpp:40-44`)

**When it's used:** Only at time step 0 (the very first move of the game).

**What it does:** The environment picks an initial input (e.g., the starting positions of robots). The initial strategy responds with an initial output that:
- Satisfies the initial guarantees (the output conditions that must hold at time 0)
- Lands in a state that is within the **winning region** (states from which the system can win the infinite game)

**How it's built:**
```cpp
// SeparationGrkSolver.cpp:41-44
initial_moves = UnprimedToPrimed(initial_guarantees & WinningStates());
initial_strategy = Determinize(initial_moves);
```
- `initial_guarantees & WinningStates()` = "states satisfying initial output conditions AND in the winning region"
- `UnprimedToPrimed(...)` = shift to primed variables (because we're choosing the *next* state)
- `Determinize(...)` = pick one concrete output for each possible input (using CUDD's SolveEqn)

**Realizability check:** If `initial_strategy.RealizableRegion()` covers all possible initial inputs satisfying the assumptions → the spec is realizable. Otherwise → unrealizable.

**At runtime** (`SeparationGrkPlayer.cpp:90-99`):
1. Environment gives initial input bits
2. `initial_strategy.Update(transition_vector)` writes the output bits into the transition vector
3. We now have a complete initial state (input + output)

#### Phase 2: Reachability Strategy (`SeparationGrkStrategy.cpp:15-19`)

**When it's used:** At every time step where the current state is in the winning region but **NOT** in the cycle-covered region.

**Why this phase is needed:** The winning region (from WeakFGGameSolver) includes two kinds of states:
- **Cycle-covered states** ("accepting"): states in SCCs where the system can directly satisfy all justice conditions by cycling through guarantees
- **Non-covered winning states**: states that are winning but NOT in a cycle-covering SCC — the system needs to *leave* these states and *reach* a cycle-covered SCC

The reachability strategy handles the second case — it guides the system from a non-covered state toward a cycle-covered one.

**How it's built:**
```cpp
// SeparationGrkStrategy.cpp:15-19
reaching_moves_ = weak_fg_strategy_.WinningMoves() & !cycle_cover_.CoveredRegion();
reachability_strategy_ = Determinize(winning_moves);
```
- Takes the full set of winning moves from the game solver
- Restricts to moves from non-covered states (states not in the cycle cover)
- Determinizes into concrete output functions

**At runtime** (`SeparationGrkPlayer.cpp:130-136`):
```cpp
if (!can_cover_cycles) {
    reachability_strategy.Update(transition_vector);  // choose output to move toward covered region
    cycle_index = cycle_strategy.InitialIndex(transition_vector);  // prepare cycle phase
}
```
The system keeps using this strategy until it reaches a cycle-covered state. Each step brings it closer (guaranteed by the reachability fixpoint correctness).

#### Phase 3: Cycle Strategy (`CycleCover.cpp:79-100`, `CycleStrategy.cpp:30-102`)

**When it's used:** At every time step where the current state IS in the cycle-covered region.

**What it does:** This is the **long-term** strategy. Once the system is in a cycle-covered SCC, it needs to visit justice guarantee states infinitely often. The cycle strategy orchestrates this by cycling through sub-goals.

**Example:** Consider a spec with justice implication `(GF done) → (GF clean₀ ∧ GF clean₁)`:
- The system must visit `clean₀` infinitely often AND `clean₁` infinitely often
- The cycle strategy breaks this into sub-phases:
  - **Phase 0 (idle):** No active obligation. Use a safe default move that stays in the SCC.
  - **Phase 1:** Drive toward a state satisfying `clean₀`. Once reached (stopping condition met), advance to phase 2.
  - **Phase 2:** Drive toward a state satisfying `clean₁`. Once reached, jump back to phase 1 (or phase 0).
  - This creates an infinite cycle: ... → clean₀ → clean₁ → clean₀ → clean₁ → ...

**How it's built (for each justice implication):**

1. `ComputePathStrategy()` (`CycleCover.cpp:59-77`): For each guarantee gⱼ in the implication:
   - `ComputeReachabilityStrategy(transition, bipath, gⱼ)` → a `MemorylessStrategy` that drives toward gⱼ while staying in the SCC (ensured by the bipath constraint)
   - The stopping condition is: the next state satisfies gⱼ

2. `CycleStrategy::Merge()` (`CycleStrategy.cpp:42-87`): Weaves this path strategy into the overall cycle:
   - Appends the new strategy parts and stopping conditions
   - Updates the ADD continuations (the "jump table") so that when phase 2 finishes, it knows to go to phase 1, etc.
   - Updates the idle region — states where all assumptions are vacuously false shrink as more implications are processed

**At runtime** (`SeparationGrkPlayer.cpp:137-143`):
```cpp
if (can_cover_cycles) {
    cycle_index = cycle_strategy.Step(transition_vector, cycle_index);
}
```

`Step()` (`CycleStrategy.cpp:94-102`):
```cpp
strategy_parts_[i].Update(transition_vector);  // apply phase i's output function

if (stopping_conditions_[i] is true for current state):
    return continuations_[i] evaluated on state;  // advance to next phase
else:
    return i;  // stay in current phase, keep driving toward current sub-goal
```

#### How the Three Phases Work Together at Runtime

```
Time 0:  Environment gives initial input
         → PHASE 1 (initial_strategy) picks initial output
         → We're now in a winning state

Time 1+: Each step:
         ┌─ Is current state in cycle-covered region?
         │
         ├─ NO  → PHASE 2 (reachability_strategy) picks output
         │        Goal: move toward a cycle-covered SCC
         │        (may take multiple steps)
         │
         └─ YES → PHASE 3 (cycle_strategy) picks output
                  Goal: cycle through justice guarantees
                  Sub-phases: g₁ → g₂ → ... → gₘ → g₁ → ...
                  (runs forever, satisfying liveness)
```

**Key guarantee:** As long as the environment satisfies its safety assumptions, the system will:
1. Start in a winning state (phase 1)
2. Eventually reach a cycle-covered SCC (phase 2, finite steps)
3. Once there, cycle through all justice guarantees forever (phase 3)

This satisfies the full GR(k) specification: safety holds at every step, and every justice guarantee is visited infinitely often.

---

## Specification Format (.sgrk)

Five sections separated by semicolons:
```
<initial-assumptions>;         -- must hold at time 0 (over input vars)
<initial-guarantees>;          -- must hold at time 0 (over output vars)
<safety-assumptions>;          -- transition constraints (over input vars, with X operator)
<safety-guarantees>;           -- transition constraints (over output vars, with X operator)
<justice-implications>         -- liveness: (GF a1 & ... -> GF g1 & ...)
```

Variables: `"in:name"` for inputs, `"out:name"` for outputs.
Operators: `!`, `&`, `|`, `->`, `<->`, `^`, `X` (next), `GF` (infinitely often).

The implicit LTL semantics: if initial assumptions hold, then the system guarantees initial conditions, maintains safety guarantees as long as safety assumptions hold, and satisfies justice implications under the global safety assumption.

---

## Build & Dependencies

- **Language**: C++17
- **Parser**: Flex + Bison 3.0.4+
- **BDD library**: CUDD 3.0.0 (with C++ namespace wrapper)
- **Build**: `make` produces `bin/sgrk`

---

## Benchmarks (`benchmarks/`)

Five benchmark families with .sgrk specification files:
1. **cleaning_robots** (1-10): multi-robot room cleaning coordination
2. **multi_mode** (1-10): system with multiple operating modes
3. **railway_signaling_2** (2-10): railway signal synthesis, level 2
4. **railway_signaling_3** (2-10): railway signal synthesis, level 3
5. **rotating_robots**: cyclic robot motion

Generator scripts (Python/Java) and `.strix` format conversions for comparison with the Strix synthesis tool are included. The paper reports significant performance improvements over Strix on these benchmarks.

---

---

## Concrete Execution Flow: What Happens When You Run `bin/sgrk spec.sgrk`

### Step 1: Initialization
**File:** `src/Main.cpp:92-96`
```cpp
shared_ptr<Cudd> mgr = make_shared<Cudd>();  // L93: Create CUDD BDD manager
mgr->AutodynEnable();                         // L94: Enable dynamic variable reordering
shared_ptr<VarMgr> vars = make_shared<VarMgr>(mgr);  // L95: Create empty variable manager
```
**File:** `src/VarMgr.cpp:26-37` — `VarMgr` constructor initializes all cube BDDs (`unprimed_input_vars_`, etc.) to `bddOne()` (the "true" cube, meaning "no variables yet").

### Step 2: Parse the specification
**File:** `src/Main.cpp:116-119`
```cpp
Driver driver(mgr, vars);       // L116: Create driver (src/Driver.cpp:8-10)
driver.Parse(argv[1]);           // L117: Open file, run Flex/Bison (src/Driver.cpp:12-22)
```

**File:** `src/Driver.cpp:12-22` — `Parse()` calls `BeginScan()` (opens the file via `fopen`, L29), creates a `yy::parser`, runs `parser.parse()` (L18), then `EndScan()` (closes file, L37).

**File:** `src/sgrk_scanner.ll` — The Flex scanner tokenizes:
- `"in:room0"` → `INPROP` token (string `"in:room0"`)
- `"out:clean0"` → `OUTPROP` token
- `&`, `|`, `!`, `->`, `<->`, `^`, `X`, `G`, `F`, `(`, `)`, `;` → corresponding tokens

**File:** `src/sgrk_parser.yy` — The Bison parser builds BDDs bottom-up:

- **Variable lookup/creation** (L78-101): First encounter of a variable name → calls `driver.vars->NewVar()` (which goes to `src/VarMgr.cpp:39-90`). This creates 3 CUDD variables (unprimed, primed, temp), updates all composition vectors (`unprimed_to_primed_`, etc.), and adds `x XNOR x'` to the reflexive relation (L87).

- **Formula construction** (L110-120):
  - `FALSE` → `mgr->bddZero()` (L110)
  - `TRUE` → `mgr->bddOne()` (L111)
  - `prop` → `var()` returns unprimed BDD (L112)
  - `X prop` → `var.Prime()` returns primed BDD (L113)
  - `!f` → `!f` BDD complement (L115)
  - `(f & g & ...)` → BDD conjunction (L116)
  - `(f | g | ...)` → BDD disjunction (L117)
  - `(f -> g)` → `!f | g` (L118)
  - `(f <-> g)` → `f.Xnor(g)` (L119)
  - `(f ^ g)` → `f.Xnor(!g)` (L120)

- **Top-level rule** (L73-76): Assembles the 5 semicolon-separated sections into `SeparationGrkSpec`:
  ```
  sgrk_spec: in_formulas ";" out_formulas ";" in_formulas ";" out_formulas ";" justice_implications
  → driver.spec = SeparationGrkSpec($1, $3, $5, $7, $9)
  ```

- **Justice parsing** (L140-158):
  - `justice_implication: ((in_justices) -> (out_justices))` (L140-143)
  - `justice: G F formula` → just the inner formula BDD (L158)
  - Multiple implications joined by `&` (L128-138)

**Result:** `driver.spec` is a `SeparationGrkSpec` (`src/SeparationGrkSpec.h:28-58`) with:
  - `initial_assumptions_`: BDD over unprimed input vars
  - `initial_guarantees_`: BDD over unprimed output vars
  - `safety_assumptions_`: BDD over unprimed+primed input vars
  - `safety_guarantees_`: BDD over unprimed+primed output vars
  - `justice_implications_`: vector of `SeparationGrkImplication` (each has `assumptions_` and `guarantees_` vectors of BDDs)

### Step 3: Solve
**File:** `src/Main.cpp:121-123`
```cpp
SeparationGrkSolver solver(mgr, vars, spec);    // L121
optional<SeparationGrkStrategy> strategy = solver.Run();  // L123
```

**File:** `src/SeparationGrkSolver.cpp:17-59` — `Run()`:

**3a. Extract spec components (L18-24):**
```cpp
BDD initial_assumptions = spec_.InitialAssumptions();   // L18
BDD initial_guarantees = spec_.InitialGuarantees();     // L19
BDD initial_states = initial_assumptions & initial_guarantees;  // L20
BDD safety_assumptions = spec_.SafetyAssumptions();     // L22
BDD safety_guarantees = spec_.SafetyGuarantees();       // L23
BDD transition_relation = safety_assumptions & safety_guarantees;  // L24
```

**3b. Compute connectivity (L26-27):**
```cpp
SpaceConnectivity connectivity(vars_, initial_assumptions, initial_guarantees,
                               safety_assumptions, safety_guarantees);  // L26-27
```

**File:** `src/SpaceConnectivity.cpp:5-55` — constructor does all the work:
- **L17-18:** `system_path_relation_ = TransitiveClosure(system_transition_relation)` — transitive closure of output-variable transitions
- **L19-20:** `environment_path_relation_ = TransitiveClosure(environment_transition_relation)` — transitive closure of input-variable transitions
- **L21-22:** `path_relation_ = TransitiveClosure(transition_relation)` — combined transitive closure
- **L25-32:** Compute reachable states — `Exists(initial_vars, initial_states & path_relation)`, then `PrimedToUnprimed()` to get back to unprimed encoding
- **L35-43:** Valid states = initial states | reachable states (separately for env, sys, combined)
- **L46-54:** Bipath relations = `path & SwapPrimedAndUnprimed(path)` — mutual reachability

**File:** `src/SpaceConnectivity.cpp:57-79` — `TransitiveClosure()`:
- L60: Start with `closure = relation`
- L62-78: Loop until fixpoint:
  - L64-66: `transitive = PrimedToTemp(closure) & UnprimedToTemp(closure)` — relational composition via temp vars
  - L70-71: `new_closure = closure | Exists(temp_vars, transitive)` — add new paths
  - L73-74: If unchanged, return

**3c. Compute cycle cover (L29):**
```cpp
CycleCover cycle_cover(mgr_, vars_, spec_, connectivity);  // L29
```

**File:** `src/CycleCover.cpp:7-14` — constructor calls two methods:
- `covered_region_ = ComputeCoveredRegion(spec, connectivity)` (L13)
- `cycle_strategy_ = ComputeCycleStrategy(spec, connectivity)` (L14)

**File:** `src/CycleCover.cpp:109-146` — `ComputeCoveredRegion()`:
- L112-123: Get valid states, bipath relations; compute `cycle_states` = states with self-loops in bipath
- L127-143: For each justice implication:
  - L130-133: `can_satisfy_assumptions &= HasCycle(environment_bipath, assumption)` for each assumption
  - L137-139: `can_satisfy_guarantees = HasCycle(system_bipath, guarantee)` for each guarantee (**note: uses `=` not `&=`**)
  - L142: `covered_region &= !can_satisfy_assumptions | can_satisfy_guarantees`

**File:** `src/CycleCover.cpp:102-107` — `HasCycle()`:
- `Exists(primed_vars, connected & UnprimedToPrimed(prop))` — "exists a bipath-connected state satisfying prop"

**File:** `src/CycleCover.cpp:79-100` — `ComputeCycleStrategy()`:
- L82-83: Get system transition relation and bipath
- L85-87: Create `idle_strategy` = determinized (transition & bipath) — strategy for when no justice obligation is active
- L89: Create `CycleStrategy` with idle strategy (`src/CycleStrategy.cpp:30-40`)
- L91-97: For each implication, compute `PathStrategy` via `ComputePathStrategy()` and merge into cycle strategy

**File:** `src/CycleCover.cpp:59-77` — `ComputePathStrategy()`:
- L67-76: For each guarantee goal, call `ComputeReachabilityStrategy()` to get a `MemorylessStrategy` that drives toward that goal

**File:** `src/CycleCover.cpp:24-57` — `ComputeReachabilityStrategy()`:
- L30: Start from `states = goal`
- L35: Initial moves = `goal & transition & bipath` (stay in SCC while at goal)
- L37-56: Fixpoint: expand backward — add states that can reach current winning states while staying on bipath
- L51: Determinize final winning moves via `MemorylessStrategy::Determinize()`

**File:** `src/CycleStrategy.cpp:42-87` — `CycleStrategy::Merge()`:
- Appends new strategy parts and stopping conditions
- Updates ADD-based `continuations_` to encode the index transitions between cycle phases
- Updates `idle_region_` to exclude newly covered states

**3d. Formulate weak FG game (L31-34):**
```cpp
BDD accepting_states = cycle_cover.CoveredRegion();  // L31
WeakFGGame game(connectivity, initial_assumptions, initial_guarantees,
                safety_assumptions, safety_guarantees, accepting_states);  // L33-34
```

**File:** `src/WeakFGGame.cpp:5-16` — constructor just stores:
- `all_states_` = `connectivity.ValidStates()` (L11)
- `path_relation_` = `connectivity.PathRelation()` (L12)
- `initial_states_` = `antagonist_initial & protagonist_initial` (L13)
- Transition relations and accepting states moved in (L14-16)

**3e. Solve the game (L36-38):**
```cpp
WeakFGGameSolver solver(mgr_, vars_, move(game));  // L36
PermissiveStrategy weak_fg_strategy = solver.Run();  // L38
```

**File:** `src/WeakFGGameSolver.cpp:11-30` — constructor peels layers:
- L17: `remaining_states = game_.AllStates()`
- L19-26: Loop: `PeelLayer()` extracts top layer, subtract from remaining
- L28-29: Reverse both `layers_` and `layers_below_` (so index 0 = bottom)

**File:** `src/WeakFGGameSolver.cpp:32-46` — `PeelLayer()`:
- L36-37: `path = states & UnprimedToPrimed(states) & game_.PathRelation()` — restrict path relation to current states
- L40-43: `top_layer = states & Forall(primed_vars, !SwapPrimedAndUnprimed(path) | path)` — states where: everything that reaches me, I can reach back

**File:** `src/WeakFGGameSolver.cpp:48-73` — `Run()`:
- L49-52: Initialize `good_states`, `bad_states`, `winning_moves` to zero
- L54-72: For each layer i (bottom to top):
  - L55-56: `SolveReachability(good_states, layers_below_[i])` — can we reach previously-good states?
  - L57-58: `SolveSafety(!bad_states, layers_below_[i])` — can we avoid previously-bad states?
  - L60-62: `winning_moves |= layer & (non-accepting ? reachability : safety)`
  - L64-69: Update `good_states` and `bad_states`
- L72: Return `PermissiveStrategy(good_states, winning_moves)`

**File:** `src/WeakFGGameSolver.cpp:75-101` — `SolveReachability()`:
- L79-80: Start from `winning = goal_states`
- L82-100: Fixpoint loop:
  - L83-87: Expand winning moves: states not yet won + antagonist transition + transitions into winning states
  - L88-92: Expand winning states: `Forall(primed_inputs, !antagonist_transition | Exists(primed_outputs, winning_moves))`
  - L94-96: If unchanged → return

**File:** `src/WeakFGGameSolver.cpp:103-132` — `SolveSafety()`:
- L107-109: Start from `winning = safe_states`
- L111-131: Fixpoint loop (shrinking):
  - L113-115: Winning moves: current winners + antagonist transition + transitions staying in winners
  - L119-123: Winning states: `Forall(primed_inputs, !antagonist_transition | Exists(primed_outputs, winning_moves))`
  - L125-127: If unchanged → return

**3f. Check realizability (L40-49):**
**File:** `src/SeparationGrkSolver.cpp:40-49`
```cpp
BDD initial_moves = UnprimedToPrimed(initial_guarantees & winning_states);  // L41-42
MemorylessStrategy initial_strategy = Determinize(mgr_, vars_, initial_moves);  // L43-44
bool is_realizable = (!UnprimedToPrimed(initial_assumptions) |
                      initial_strategy.RealizableRegion()).IsOne();  // L48-49
```

**File:** `src/MemorylessStrategy.cpp:20-77` — `Determinize()`:
- L26-27: Get primed output cube
- L30-32: `(!winning_moves).SolveEqn(output_cube, ...)` — CUDD solves system of boolean equations
- L42-43: Verify solution with `VerifySol()`
- L57-72: Replace parameters with constants (bddZero) via `Compose()` to get fully deterministic output functions
- L75-76: Return strategy with `!consistency_condition` as realizable region

**File:** `src/SeparationGrkSolver.cpp:51-58` — if unrealizable return `nullopt`, else construct strategy:
```cpp
return SeparationGrkStrategy(mgr_, vars_, initial_strategy, cycle_cover, weak_fg_strategy);
```

**File:** `src/SeparationGrkStrategy.cpp:5-20` — constructor:
- L15-16: `reaching_moves_ = winning_moves & !covered_region` — moves for states not yet in cycle cover
- L17-19: `reachability_strategy_ = Determinize(winning_moves)` — determinize the weak FG strategy

### Step 4: Output
**File:** `src/Main.cpp:125-153`
- L126: Print `"Realizable"` or L152: Print `"Unrealizable"`
- L129-133: Extract 3 BDDs: `WinningStates()`, `CycleCoveringStates()`, `ReachingMoves()`
- L139-141: If `--test` flag: run tests via `RunTests()` (L50-75) → calls `TestSet::ReadFromFile()` then `TestSet::Run(bdds)`
- L143-145: If `--dumpdot` flag: `vars->DumpDot(bdds, labels, file)` (`src/VarMgr.cpp:226-276`)
- L147-149: If `--play` flag: `PlayGame()` (L77-90) → creates `SeparationGrkPlayer` and calls `Play()`

### Step 5 (optional): Playing the game
**File:** `src/SeparationGrkPlayer.cpp:86-145` — `Play()`:

- L87: Create zeroed transition vector (`VarMgr::ZeroedTransitionVector()` at `src/VarMgr.cpp:179-183`)
- L90-91: Ask for initial input (validated against `initial_assumptions` via `AskForInput()` at L19-71)
- L99: Apply `initial_strategy_.Update(transition_vector)` — writes output bits (`src/MemorylessStrategy.cpp:83-90`)
- L101-106: Get accepting states and strategy references
- L108: `cycle_index = cycle_strategy.InitialIndex(transition_vector)` (`src/CycleStrategy.cpp:89-92`) — evaluates last continuation ADD

- L110-144: **Main game loop:**
  - L111: Compute current state BDD from transition vector (`NewState()` at L73-84)
  - L113-114: Print current state
  - L116-120: Copy current state into transition vector
  - L122: Check if current state is in cycle-covering region (`EvalBdd(accepting_states, ...)`)
  - L124: Ask for next input (validated against `safety_assumptions`)
  - L130-136: If NOT in covered region:
    - L134: `reachability_strategy.Update(transition_vector)` — drive toward covered region
    - L136: Reset `cycle_index = InitialIndex(...)`
  - L137-143: If IN covered region:
    - L142: `cycle_index = cycle_strategy.Step(transition_vector, cycle_index)` (`src/CycleStrategy.cpp:94-102`)
      - L95: Apply strategy part i's `Update()`
      - L97-98: If stopping condition met → evaluate continuation ADD to get next index
      - L100: Otherwise stay at current index

---

## Detailed Code Architecture

### Namespace & Organization

Everything lives in namespace `SGrk` except the `Driver` class (which sits in global scope as it bridges Flex/Bison's C-style interface with the C++ code). There are no subdirectories within `src/` — it's a flat layout of ~16 `.h`/`.cpp` pairs plus the parser/scanner files.

### Ownership & Lifetime Model

The project uses `std::shared_ptr` extensively for two key objects that nearly every class needs:

- **`std::shared_ptr<CUDD::Cudd> mgr_`** — the CUDD manager, the singleton that owns all BDD nodes. Every class that creates BDDs holds a shared reference to it.
- **`std::shared_ptr<VarMgr> vars_`** — the variable manager, which wraps the CUDD manager with domain-specific operations (priming, quantification, composition).

These are created once in `main()` and passed by shared_ptr through the entire pipeline. Other objects (specs, strategies, games) are passed by value/move — they're relatively lightweight wrappers around BDDs (which are themselves just integer handles into the CUDD manager's internal table).

### Class Dependency Graph

```
main()
 ├── Driver                      [Parsing layer]
 │    ├── Flex scanner (sgrk_scanner.ll)
 │    ├── Bison parser (sgrk_parser.yy)
 │    └── produces: SeparationGrkSpec
 │
 ├── SeparationGrkSolver          [Orchestration layer]
 │    ├── SpaceConnectivity       [Connectivity analysis]
 │    ├── CycleCover              [Liveness analysis]
 │    │    └── produces: CycleStrategy (contains PathStrategy + MemorylessStrategy)
 │    ├── WeakFGGame              [Game formulation - pure data]
 │    └── WeakFGGameSolver        [Game solving]
 │         └── produces: PermissiveStrategy
 │
 ├── SeparationGrkStrategy        [Strategy assembly]
 │    ├── MemorylessStrategy (initial)
 │    ├── MemorylessStrategy (reachability)
 │    └── CycleStrategy (from CycleCover)
 │
 └── SeparationGrkPlayer          [Execution layer - optional]
      └── uses SeparationGrkStrategy to play interactively
```

### Layer-by-Layer Breakdown

#### 1. Parsing Layer: `Driver` + Flex/Bison

`Driver` is a classic Bison-style driver class. It holds mutable state (`spec`, `filename`, `location`) that the parser actions populate.

The parser (`sgrk_parser.yy`) converts the `.sgrk` text into BDDs on-the-fly — it doesn't build an AST. Each formula token is immediately converted to a `CUDD::BDD` using `VarMgr::NewVar()` (which creates unprimed/primed/temp variable triples). Boolean operators (`&`, `|`, `!`, `->`, `<->`, `^`) map directly to BDD operations. The `X` (next) operator maps to `VarMgr::UnprimedToPrimed()`.

The output is a `SeparationGrkSpec` — a simple value type holding 4 BDDs + a vector of `SeparationGrkImplication`:

```cpp
SeparationGrkSpec:
  initial_assumptions_: BDD       // over unprimed input vars
  initial_guarantees_: BDD        // over unprimed output vars
  safety_assumptions_: BDD        // over unprimed + primed input vars
  safety_guarantees_: BDD         // over unprimed + primed output vars
  justice_implications_: vector<SeparationGrkImplication>
    each: assumptions_: vector<BDD>   // each over unprimed input vars
          guarantees_: vector<BDD>    // each over unprimed output vars
```

#### 2. Variable Management: `VarMgr`

`VarMgr` is the critical infrastructure class. For each named variable (e.g., `"in:room0"`), it creates **three** CUDD BDD variables:

- **Unprimed** (current state): used in state formulas
- **Primed** (next state): used in transition relations
- **Temp** (scratch): used during transitive closure computation

It maintains pre-computed composition vectors for efficient variable substitution:
- `unprimed_to_primed_`: replaces x with x'
- `primed_to_unprimed_`: replaces x' with x
- `swap_primed_and_unprimed_`: swaps x ↔ x'
- `primed_to_temp_`, `unprimed_to_temp_`: for intermediate computations

It also provides:
- `Forall(cube, bdd)` / `Exists(cube, bdd)` — quantifier abstractions
- `Reflexive()` — the relation x = x' (identity)
- `DumpDot()` — export BDDs to Graphviz
- `ZeroedTransitionVector()` — creates a zeroed bit-vector for BDD evaluation
- `ToString(bdd)` — converts a single-variable BDD to its name string

Variables are stored as a flat `unordered_map<string, Var>`, and also indexed by `VarType` (INPUT/OUTPUT). The cube BDDs (`unprimed_input_vars_`, etc.) are conjunctions of all variables of each type, used as quantification domains.

#### 3. Connectivity Analysis: `SpaceConnectivity`

This class exploits the **separation property**. Because assumptions depend only on inputs and guarantees only on outputs, the transition relation factors into:
- **Environment transitions** (`safety_assumptions`): constraint on input variable evolution
- **System transitions** (`safety_guarantees`): constraint on output variable evolution

For each, it computes:
- **Valid states**: initial states + all states reachable via the transition relation
- **Path relation**: transitive closure of the transition — `Path(s, s')` means s can reach s'
- **Bipath relation**: `Path(s, s') & Path(s', s)` — mutual reachability (SCC membership)

`TransitiveClosure()` works by iterative squaring with a temp-variable relay:
```
R → R ∪ (R ; R) → R ∪ (R ; R) ∪ ...  until fixpoint
```
where `;` is relational composition (existentially quantify the intermediate state).

The separation means it computes three independent sets: environment-only, system-only, and combined.

#### 4. Liveness Analysis: `CycleCover`

`CycleCover` determines the **covered region** — states from which the system can satisfy all justice conditions while staying in the same strongly connected component.

For each justice implication `(GF a₁ & ... & GF aₙ) → (GF g₁ & ... & GF gₘ)`:
- `HasCycle(environment_bipath, aᵢ)`: can the environment cycle through assumption aᵢ?
- `HasCycle(system_bipath, gⱼ)`: can the system cycle through guarantee gⱼ?
- A state is covered if: ¬(all assumptions satisfiable) ∨ (all guarantees satisfiable)

It also computes a `CycleStrategy` — the strategy for actually cycling through guarantees:
- For each implication, builds a `PathStrategy` — a sequence of `MemorylessStrategy` parts, one per guarantee
- Each part drives the system toward one guarantee state, then moves to the next
- The `CycleStrategy` merges all path strategies and uses ADD-based `continuations_` to track which part of the cycle to follow

#### 5. Game Formulation: `WeakFGGame`

A pure data class packaging the game for the solver:

```cpp
WeakFGGame:
  all_states_        = ValidStates from SpaceConnectivity
  initial_states_    = initial_assumptions (primed) & initial_guarantees (primed)
  antagonist_transition_relation_  = safety_assumptions (environment moves)
  protagonist_transition_relation_ = safety_guarantees (system moves)
  path_relation_     = PathRelation from SpaceConnectivity
  accepting_states_  = CoveredRegion from CycleCover
```

The naming convention: **antagonist** = environment, **protagonist** = system.

#### 6. Game Solving: `WeakFGGameSolver`

The novel algorithm. The constructor does **layer peeling**:

```cpp
while remaining_states is not empty:
    top_layer = PeelLayer(remaining_states)
    layers_.push_back(top_layer)
    remaining_states -= top_layer
reverse(layers_)  // process bottom-up
```

`PeelLayer(states)` extracts the topologically maximal component:
```
TopLayer(s) = States(s) ∧ ∀s'. (Path(s',s) → Path(s,s'))
```
A state is in the top layer if anything that can reach it, it can also reach back — meaning it's in the "outermost" SCC.

`Run()` then processes layers bottom-to-top, maintaining `good_states` and `bad_states`:
- **Non-accepting layers**: call `SolveReachability(good_states, ...)` — can the system force reaching already-known good states?
- **Accepting layers**: call `SolveSafety(¬bad_states, ...)` — can the system force staying away from already-known bad states?

Both `SolveReachability` and `SolveSafety` are standard fixpoint computations over the game graph:
- **Reachability fixpoint**: starting from goal states, expand backward — a state is winning if for all environment moves, there exists a system move reaching a winning state
- **Safety fixpoint**: starting from safe states, shrink — a state is winning if for all environment moves, there exists a system move staying in a winning state

The key insight: because each layer is an SCC (or union of SCCs at the same topological level), and accepting/non-accepting is uniform within a layer (due to the weak automaton structure), this processes in linear time over the total state space.

#### 7. Strategy Representation

Three strategy types form a hierarchy:

**`PermissiveStrategy`** — the most general. Stores:
- `winning_states_: BDD` — all states from which the system can win
- `winning_moves_: BDD` — all (state, next-state) pairs that are part of some winning strategy

This is non-deterministic: multiple valid outputs may exist for the same input.

**`MemorylessStrategy`** — deterministic. Created by `Determinize()`:
- Uses CUDD's `SolveEqn()` to find boolean functions for each output variable
- Result: `strategy_: unordered_map<int, BDD>` mapping each output variable index to a BDD over input + current-state variables
- `Update(transition_vector)` evaluates each output function on the current state to produce concrete output bits
- `realizable_region_: BDD` — the subset of states where this strategy is defined

**`CycleStrategy`** — stateful (has memory). Maintains:
- `strategy_parts_: vector<MemorylessStrategy>` — one per sub-goal in the cycle
- `stopping_conditions_: vector<BDD>` — when to advance to the next sub-goal
- `continuations_: vector<ADD>` — ADDs encoding which sub-goal index to jump to next
- `idle_region_: BDD` — states where no justice obligation is active

`Step(transition_vector, i)` applies strategy part `i`, then checks the stopping condition to potentially advance to the next part.

#### 8. Strategy Assembly: `SeparationGrkStrategy`

Combines the three phases of play:

```cpp
SeparationGrkStrategy:
  initial_strategy_       : MemorylessStrategy  // pick initial outputs
  reachability_strategy_  : MemorylessStrategy  // reach the covered region
  cycle_cover_            : CycleCover          // holds the CycleStrategy
  reaching_moves_         : BDD                 // winning moves outside covered region
```

The constructor determinizes the weak FG strategy's winning moves into `reachability_strategy_`, and computes `reaching_moves_` as the winning moves restricted to states NOT in the covered region.

#### 9. Execution: `SeparationGrkPlayer`

The `Play()` method implements a game loop with three phases:

1. **Initialization**: ask for initial input, apply `initial_strategy_`
2. **Each step**:
   - If current state is NOT in the cycle-covering region → use `reachability_strategy_` to move toward it
   - If current state IS in the cycle-covering region → use `cycle_strategy_.Step()` to cycle through justice guarantees
3. Input is validated against `safety_assumptions` each turn

The state is tracked as a `vector<int>` (the "transition vector") — a flat bit array indexed by CUDD variable indices. `MemorylessStrategy::Update()` writes output bits into this vector by evaluating each output function BDD.

#### 10. Testing: `TestSet`

A simple test harness that:
- Reads a `.test` file (variable names header + bitvector test cases)
- Evaluates given BDDs on each test case using `Util::EvalBdd()`
- Compares against expected results

### Notable C++ Patterns

- **Value semantics for BDDs**: `CUDD::BDD` is a lightweight handle (wraps an integer node pointer + reference counting). Copying is cheap. The project passes and stores BDDs by value freely.
- **Move semantics**: Classes accept `spec`, `game`, etc. by value in constructors and `std::move()` them into members — avoiding unnecessary BDD reference count bumps.
- **`std::optional`**: `SeparationGrkSolver::Run()` returns `std::optional<SeparationGrkStrategy>` — `nullopt` means unrealizable.
- **Static factory**: `MemorylessStrategy::Determinize()` is a static method that constructs a strategy from a permissive BDD, encapsulating the CUDD `SolveEqn` machinery.
- **No inheritance**: The codebase uses composition throughout. No virtual functions, no class hierarchies.
- **Namespace isolation**: All domain types in `SGrk`, only `Driver` is in global scope (Bison requirement).

### Potential Issue Spotted

In `CycleCover::ComputeCoveredRegion()` (line 138 of `CycleCover.cpp`):
```cpp
for (const auto& guarantee : implication.Guarantees()) {
    can_satisfy_guarantees = HasCycle(system_bipath_relation, guarantee);  // = not &=
}
```
This uses `=` instead of `&=`, meaning only the **last** guarantee determines `can_satisfy_guarantees`. Compare with the assumptions loop (line 131) which correctly uses `&=`. This looks like it could be a bug — or it could be intentional if there's always exactly one guarantee per implication in practice.

---

---

## Algorithm Deep-Dive

### 1. Transitive Closure (`SpaceConnectivity.cpp:57-79`)

**Goal:** Given a transition relation R(s, s'), compute R*(s, s') = "s can reach s' in any number of steps."

**How it works:** Iterative relational composition until fixpoint.

```
closure₀(s, s') = R(s, s')                    // direct transitions
closure₁(s, s') = R(s, s') ∨ ∃t. R(s,t) ∧ R(t, s')    // 1 or 2 steps
closure₂(s, s') = closure₁ ∨ ∃t. closure₁(s,t) ∧ closure₁(t, s')  // up to 4 steps
...
closureₖ covers up to 2^k steps
```

Each iteration **doubles** the reachable distance. So for a graph of diameter D, this converges in O(log D) iterations.

**The temp variable trick (`VarMgr`):**

The challenge: `R(s, s')` uses unprimed vars for s and primed vars for s'. To compose R with itself (R;R), we need an intermediate variable t. That's what temp vars are for.

```cpp
// SpaceConnectivity.cpp:64-66
transitive = PrimedToTemp(closure) & UnprimedToTemp(closure);
```

This creates:
- `PrimedToTemp(closure)` = R(s, t) — replace s' with t in the first copy
- `UnprimedToTemp(closure)` = R(t, s') — replace s with t in the second copy
- Their conjunction = R(s, t) ∧ R(t, s')

Then:
```cpp
// L70-71
new_closure = closure | Exists(temp_vars, transitive);
```
Existentially quantifies out t → gives ∃t. R(s,t) ∧ R(t,s'), which is "reachable in 2 steps."

**Separation advantage:** Because environment and system transitions are independent, we compute three separate closures:
- `TransitiveClosure(safety_assumptions)` — just input variable reachability
- `TransitiveClosure(safety_guarantees)` — just output variable reachability
- `TransitiveClosure(safety_assumptions & safety_guarantees)` — combined

The first two are over fewer variables, so the BDDs are smaller and the fixpoints converge faster.

### 2. Layer Peeling (`WeakFGGameSolver.cpp:11-46`)

**Goal:** Decompose the game graph into topological layers — from "bottom" (sink SCCs) to "top" (source SCCs).

**Intuition:** Think of the game graph's SCC structure as a DAG. The "top layer" consists of SCCs that have no outgoing edges to other SCCs (or equivalently: anything that can reach them, they can reach back).

**How PeelLayer works (`WeakFGGameSolver.cpp:32-46`):**

```cpp
// Restrict path relation to current states
path = states & UnprimedToPrimed(states) & PathRelation();

// TopLayer(s) = States(s) ∧ ∀s'. (Path(s', s) → Path(s, s'))
top_layer = states & Forall(primed_vars, !SwapPrimedAndUnprimed(path) | path);
```

Let's unpack:
- `SwapPrimedAndUnprimed(path)` turns Path(s, s') into Path(s', s)
- `!Path(s', s) | Path(s, s')` means "if s' can reach s, then s can reach s'" — this is the bipath condition
- `Forall(primed_vars, ...)` universally quantifies over s' — "for ALL states s' in the current set..."
- So: s is in the top layer if **every** state that can reach s, s can also reach back

**Why this identifies topological maxima:**
- In a DAG of SCCs, the "top" SCCs are those with no outgoing edges
- If an SCC has an outgoing edge, some states can reach states in other SCCs but can't come back → those states fail the bipath test → they're NOT in the top layer
- States in the topmost SCC(s) all satisfy: everything reaching them is in the same SCC → they pass

**Iteration:**
```
Round 1: Peel top layer (topologically last SCCs)
Round 2: Remove those, peel new top layer
...
Round n: Only bottom layer (topologically first SCCs) remains
```

Then `reverse()` so `layers_[0]` = bottom, `layers_[n-1]` = top.

### 3. The Weak FG Game Solver (`WeakFGGameSolver.cpp:48-73`)

**Goal:** Determine which states are winning for the protagonist (system) in a game where:
- **Accepting states** (from CycleCover): states where the system can satisfy justice conditions locally
- **Non-accepting states**: states where the system needs to reach an accepting region

**Core insight:** Process layers bottom-to-top. At each layer, we know the fate of all layers below.

```
good_states = ∅    // states confirmed winning
bad_states = ∅     // states confirmed losing

for each layer (bottom → top):
    if layer is NON-ACCEPTING:
        Can the system force reaching good_states? → SolveReachability
        Winning = those that can reach good states
    if layer is ACCEPTING:
        Can the system force staying away from bad_states? → SolveSafety
        Winning = those that can avoid bad states

    // A state in this layer is winning if:
    //   non-accepting AND can reach good → good
    //   accepting AND can avoid bad → good
    // Everything else → bad
```

**Why this is correct:**
- **Non-accepting, bottom layer:** No good states below → no one can win → all bad ✓
- **Accepting, bottom layer:** No bad states below → everyone can avoid bad → all good ✓
- **Non-accepting, middle layer:** Must eventually leave this layer (since it's non-accepting, staying forever loses). So must reach a lower good state.
- **Accepting, middle layer:** Can stay forever (it's an SCC). Only loses if forced into a bad state.

**Why this is linear:** Each state is processed exactly once (in its layer). The fixpoints within each layer are bounded by the layer size. Total work = sum of layer sizes = total state space.

### 4. Reachability Fixpoint (`WeakFGGameSolver.cpp:75-101`)

**Goal:** Find states from which the protagonist can force reaching `goal_states`, regardless of antagonist moves.

**This is the classic "attractor" computation in game theory:**

```
Win₀ = goal_states
Winₙ₊₁ = Winₙ ∪ {s | ∀ env_move(s, x'). ∃ sys_move(s, x', y'). (x', y') ∈ Winₙ}
```

In BDD terms (`WeakFGGameSolver.cpp:83-92`):
```cpp
// New winning moves: states not yet won, where antagonist transitions and
// we can transition into winning states
new_winning_moves = winning_moves |
    (state_space & !winning_states & AntagonistTransition & TransitionsInto(winning_states));

// New winning states: for all antagonist moves, there exists a protagonist move in winning_moves
new_winning_states = state_space &
    Forall(primed_inputs, !AntagonistTransition | Exists(primed_outputs, new_winning_moves));
```

**Reading the BDD formula:**
- `TransitionsInto(W)` = `ProtagonistTransition & UnprimedToPrimed(W)` — protagonist moves that land in W
- The `Forall/Exists` pattern: "for every environment choice x', there exists a system choice y' such that the combined move is winning"
- This is the standard ∀∃ pattern for two-player games

**Convergence:** Each iteration adds at least one new state to the winning set. Bounded by the state space size.

### 5. Safety Fixpoint (`WeakFGGameSolver.cpp:103-132`)

**Goal:** Find states from which the protagonist can force staying in `safe_states` forever.

**This is the dual of reachability — a "trap" computation:**

```
Win₀ = safe_states
Winₙ₊₁ = {s ∈ Winₙ | ∀ env_move(s, x'). ∃ sys_move(s, x', y'). (x', y') ∈ Winₙ}
```

```cpp
// WeakFGGameSolver.cpp:113-123
new_winning_moves = state_space & winning_states & AntagonistTransition &
                    TransitionsInto(winning_states);

new_winning_states = state_space &
    Forall(primed_inputs, !AntagonistTransition | Exists(primed_outputs, new_winning_moves));
```

**Difference from reachability:**
- Reachability **grows** the winning set (attracting toward the goal)
- Safety **shrinks** the winning set (removing states that can be forced out)
- Reachability stops when no more states can be added
- Safety stops when no more states need to be removed

### 6. CycleCover: How Justice Is Checked (`CycleCover.cpp:109-146`)

**Goal:** For each state, check: "if the system stays in this SCC forever, can it satisfy all justice conditions?"

A justice implication `(GF a₁ ∧ ... ∧ GF aₙ) → (GF g₁ ∧ ... ∧ gₘ)` means: if the environment visits a₁, ..., aₙ infinitely often, the system must visit g₁, ..., gₘ infinitely often.

**How HasCycle works (`CycleCover.cpp:102-107`):**
```cpp
HasCycle(connected, prop) = Exists s'. Connected(s, s') ∧ Prop(s')
```
"From state s, there exists a bipath-connected state s' satisfying Prop." Since bipath means mutual reachability, this means s can reach a Prop-state and come back — i.e., s is in an SCC that contains a Prop-state, so s can visit Prop infinitely often.

**Covered region:**
```
covered(s) = cycle_state(s) ∧ ⋀ᵢ (¬can_satisfy_assumptionsᵢ(s) ∨ can_satisfy_guaranteesᵢ(s))
```
A state is covered if for every justice implication: either the environment can't cycle through all assumptions (so the implication is vacuously true), or the system can cycle through all guarantees.

### 7. Cycle Strategy: How Justice Is Achieved at Runtime

Once we know a state is covered, the `CycleStrategy` provides a concrete strategy for cycling through guarantees.

**Structure (`CycleStrategy.h`):**
- `strategy_parts_[i]`: a `MemorylessStrategy` — deterministic output function for phase i
- `stopping_conditions_[i]`: a BDD — when to advance from phase i to the next phase
- `continuations_[i]`: an ADD (Algebraic Decision Diagram) — maps current state to the next phase index
- `idle_region_`: states where no justice obligation is active (all assumptions vacuously false)

**Runtime execution (`CycleStrategy.cpp:94-102`):**
```cpp
Step(transition_vector, i):
    strategy_parts_[i].Update(transition_vector);  // apply phase i's output function
    if (stopping_conditions_[i] evaluates to true):
        return continuations_[i] evaluated on current state  // advance to next phase
    else:
        return i  // stay in current phase
```

**Example:** For a spec with one implication `(GF done) → (GF clean₀ ∧ GF clean₁)`:
- Phase 0: idle (no obligation active)
- Phase 1: drive toward `clean₀`
- Phase 2: drive toward `clean₁`
- When phase 2 completes → continuation sends back to phase 1 (or 0 if idle)

The `Merge()` method (`CycleStrategy.cpp:42-87`) is how path strategies from different justice implications get woven together into a single cycle. The ADD continuations encode the "jump table" — which phase to enter next based on the current state.

---

## Summary

This is a research tool implementing a novel, efficient algorithm for reactive synthesis. The key contribution is exploiting the **separation** between input and output variables in GR(k) specifications to achieve **linear-time** realizability checking — a major improvement over the exponential complexity of general GR(k). The implementation is BDD-based (using CUDD) and follows a clean pipeline: parse -> compute connectivity -> find cycle cover -> solve weak game -> extract strategy.
