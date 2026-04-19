## R2P Implementation: Joint State-Dependent Alive Region

**Notation:** x = (x₁, ..., xₙ) for environment variables, y = (y₁, ..., yₘ) for system variables. We have R2P implications of the form (GF a₁ ∧ ... ∧ GF aₖ) → (FG g₁ ∧ ... ∧ FG gₗ).

**Structure:** Steps 1–5 are shared logic implemented in `ComputeR2PAliveRegion` (`src/CycleCover.cpp:162-192`). The result is used in two places: **ComputeCoveredRegion** (`src/CycleCover.cpp:219-284`, determines which states are winning) and **ComputeCycleStrategy** (`src/CycleCover.cpp:79-117`, builds the strategy for how to win). They diverge at Step 6.

---

### Step 1 — Build R_i(x, y): can the environment cycle through implication i's assumptions?

For each R2P implication Imp_i with assumptions GF(a₁) ∧ ... ∧ GF(aₖ), check whether the environment can cycle through each assumption from the current state, and AND the results:

> R_i(x, y) = HasCycle(env_bipath, a₁) ∧ HasCycle(env_bipath, a₂) ∧ ... ∧ HasCycle(env_bipath, aₖ)

**HasCycle(connected, prop)** answers: "from the current state (x, y), does there exist a bipathconnected state (x', y') that satisfies prop?" Formally:

> HasCycle(x, y) = ∃(x', y'). connected((x,y), (x',y')) ∧ prop(x')

Bipathconnected means there is a path from (x, y) to (x', y') AND a path back. So if HasCycle is true, the environment can reach a state satisfying prop and return — meaning it can visit prop infinitely often. We AND across all assumptions because the LHS requires **all** of them to recur simultaneously.

**Runtime:** Each HasCycle performs one `UnprimedToPrimed` (BDD VectorCompose over the prop BDD), one AND with the bipath BDD, and one existential quantification over all primed variables. Cost per call: O(|env_bipath| · |prop'|) dominated by the BDD AND. Total: Σᵢ kᵢ calls across all R2P implications, where kᵢ is the number of assumptions in implication i.

**Implementation:**
- `HasCycle`: `src/CycleCover.cpp:119-124`
- Loop over assumptions in `ComputeR2PAliveRegion`: `src/CycleCover.cpp:173-177`

---

### Step 2 — Build P_i(y): the conjunction of implication i's guarantees

For the same implication, if the guarantees are FG(g₁(y)) ∧ ... ∧ FG(gₗ(y)), build:

> P_i(y) = g₁(y) ∧ g₂(y) ∧ ... ∧ gₗ(y)

This is the condition that must hold at every step once the system stabilizes for this implication. Since each gⱼ depends only on output variables (separated specification), P_i is a function of y only.

**Runtime:** l − 1 BDD AND operations. Each AND is O(|gⱼ| · |accumulated|). Typically very cheap since individual guarantee BDDs are small.

**Implementation:**
- In `ComputeR2PAliveRegion`: `src/CycleCover.cpp:180-183`

---

### Step 3 — Build Accept_i(x, y): the per-implication acceptance condition

> Accept_i(x, y) = ¬R_i(x, y) ∨ P_i(y)

This evaluates to 1 if **either** the environment cannot cycle through implication i's assumptions from this state (so the implication is vacuously satisfied), **or** the guarantees hold at this output state. In other words: "implication i is not a problem here."

**Runtime:** One BDD NOT (O(1) — complement pointer flip in CUDD) and one BDD OR. The OR is O(|R_i| · |P_i|).

**Implementation:**
- In `ComputeR2PAliveRegion`: `src/CycleCover.cpp:186`

---

### Step 4 — Build Accept(x, y): the joint acceptance condition across all R2P implications

> Accept(x, y) = Accept₁(x, y) ∧ Accept₂(x, y) ∧ ... ∧ Accept_k(x, y)

Stored as `r2p_demanded`. It evaluates to 1 if output state y satisfies the guarantees of **every** R2P implication whose assumptions the environment can cycle through from input state x. This is the key difference from the per-implication approach: all R2P implications are folded into one BDD that captures their joint interaction through the safety constraint.

**Runtime:** Steps 1–4 are fused in a single loop over implications. Each iteration builds R_i (Step 1), P_i (Step 2), Accept_i (Step 3), and ANDs into the accumulator (Step 4). The AND per iteration is O(|r2p_demanded| · |Accept_i|). Total loop cost: O(k) iterations, each doing Σ kᵢ HasCycle calls plus the BDD AND chain.

**Implementation:**
- The full fused loop (Steps 1–4) in `ComputeR2PAliveRegion`: `src/CycleCover.cpp:167-187`

---

### Step 5 — Build Alive(x, y): the state-dependent alive region

Compute the greatest fixpoint of Accept that is closed under the system's safety transition relation:

> Alive₀(x, y) = Accept(x, y)
>
> Aliveₙ₊₁(x, y) = Aliveₙ(x, y) ∧ ∃y'. ( Safety(y, y') ∧ Aliveₙ(x, y') )

**What question does this answer?**

Accept(x, y) tells us which output states satisfy the demanded guarantees right now. But that's not enough. The system doesn't just need to be in a "good" state — it needs to **stay** in a good state **forever**, taking only safety-legal output transitions. The alive region answers: "from which states can the system remain in Accept for all future steps?"

**What is being reduced?**

We start with the full Accept set and **shrink** it. At each iteration, we remove states that are "trapped" — states where **every** safety-legal output transition leads outside the current set. A state with no safe way to stay in Accept is not truly alive, so we prune it. But pruning one state can cause a chain reaction: other states that relied on transitioning to the pruned state may now themselves have no alive successor, so they get pruned too. The fixpoint iterates until no more states are pruned.

**The iteration, broken down:**

```
alive = Accept(x, y)                                       // start with everything demanded
repeat:
    successor_exists = ∃y'. Safety(y, y') ∧ alive(x, y')   // can I go somewhere alive?
    new_alive = alive ∧ successor_exists                    // keep only states that can
    if new_alive == alive: stop                             // nothing pruned, we're done
    alive = new_alive                                       // shrunk; repeat
```

Each piece:

1. **`alive(x, y')`** — take the current alive set and express it in terms of the **next** output state y'. This is computed by `OutputUnprimedToPrimed`, which substitutes y → y' but leaves x alone. The result says: "is the next output state y' alive, given input state x?"

2. **`Safety(y, y') ∧ alive(x, y')`** — filter to transitions that are both safety-legal AND land in an alive state. This is a relation over (x, y, y').

3. **`∃y'. (...)`** — existentially quantify over y'. This asks: "does there **exist at least one** safety-legal next output state that is alive?" The result is a BDD over (x, y) — true if state (x, y) has at least one safe escape route.

4. **`alive ∧ successor_exists`** — keep only states that are currently alive AND have a safe successor. States that fail either condition are pruned.

**Why input-dependent?**

Because `OutputUnprimedToPrimed` keeps x as a free parameter, the pruning happens **independently for each input state**. Accept(x₁, y) and Accept(x₂, y) are different sets (different implications may be active at different input states). The fixpoint prunes them independently. An output state might be alive at x₁ but dead at x₂. The result alive(x, y) captures this: "output state y is alive **when the input is x**."

**What converges and why?**

The alive set can only shrink (we only AND with additional constraints, never OR). There are finitely many output states (at most 2ᵐ). So the fixpoint must converge in at most 2ᵐ iterations. In practice it converges much faster because entire regions are pruned at once via BDD operations.

**The critical detail:** the substitution Aliveₙ(x, y') is computed using `OutputUnprimedToPrimed`, which maps y → y' but maps x → x (identity). This means:
- Input variables are **never primed** — they stay as free parameters throughout
- The alive region is a function of **(x, y)**, varying by input state: at input states where fewer assumptions can recur, less is demanded, so more output states are alive
- The fixpoint BDDs have **n + m** free variables throughout (not 2n + m as they would with full `UnprimedToPrimed`, which would spuriously prime x to x' and require unpriming afterwards)

**The final result:** alive(x, y) = the largest set of (input, output) pairs where the demanded guarantees hold (Accept) AND the system can keep them holding forever by always having a safety-legal output transition to another alive state. If alive is empty, the system cannot satisfy the R2P obligations → **unrealizable**.

**Runtime:** Each iteration performs:
1. `OutputUnprimedToPrimed(alive)` — VectorCompose, O(|alive|)
2. AND with safety — O(|safety| · |alive'|)
3. ∃y' quantification — O(|result|)
4. AND with current alive — O(|alive| · |exists_result|)

Number of iterations ≤ 2ᵐ (output state space) since the alive set strictly shrinks each iteration. In practice converges much faster. All intermediate BDDs have n + m free variables.

**Implementation:**
- `ComputeStateDependentAliveRegion`: `src/CycleCover.cpp:148-160`
- `OutputUnprimedToPrimed` substitution vector (identity for inputs, unprimed→primed for outputs): `src/VarMgr.cpp:83-91`
- `OutputUnprimedToPrimed` method: `src/VarMgr.cpp:165-167`
- Called from `ComputeR2PAliveRegion`: `src/CycleCover.cpp:190-191`

---

### Step 6a — Covered Region: check system reachability to alive

*Only in ComputeCoveredRegion.* Verify that from the current state, the system can reach a cycle within the alive region:

> can_satisfy_r2p(x, y) = ∃y'. sys_bipath(y, y') ∧ Alive(x, y')

Again uses `OutputUnprimedToPrimed` to prime only y in the alive region, and quantifies over `PrimedOutputs` only — preserving x as a free parameter. Then conjoin into the covered region as a **single** constraint for all R2P implications:

> covered_region &= can_satisfy_r2p

This is the final verdict: state (x, y) is covered for R2P iff the system can reach an output cycle that stays within the alive region given the current input state.

**Runtime:** One `OutputUnprimedToPrimed` (O(|alive|)), one AND with sys_bipath (O(|sys_bipath| · |alive'|)), one ∃y' quantification (O(|result|)), one AND with covered_region. Single pass, no iteration.

**Implementation:**
- `ComputeR2PAliveRegion` call: `src/CycleCover.cpp:273-274`
- Reachability check and conjoin: `src/CycleCover.cpp:277-280`

---

### Step 6b — Cycle Strategy: reach and maintain the alive region

*Only in ComputeCycleStrategy.* If Alive is non-empty, compute a **single** two-phase path strategy:

- **Phase 0 (Reach):** Backward fixpoint from Alive — starting from states in Alive, iteratively expand to states that can transition into the current set while staying bipathconnected. Each iteration adds states one step further from Alive. Determinize the resulting winning moves into a memoryless output function using CUDD's `SolveEqn`. This phase stops when the system enters the alive region.

- **Phase 1 (Maintain):** Stay in Alive forever. Winning moves are transitions that start in Alive and end in Alive: moves(y, y') = Safety(y, y') ∧ Alive(y) ∧ Alive(y'). Determinize into a memoryless output function. This phase **never terminates** (stopping condition = false).

Merge this one strategy into the cycle strategy. All R2P implications are served by this single two-phase strategy, rather than one strategy per implication.

**Runtime:** Phase 0: backward fixpoint, at most 2ᵐ iterations, each doing BDD AND/OR/Exists over BDDs with n + m variables, plus one Determinize (CUDD `SolveEqn`, cost depends on BDD size and number of output variables). Phase 1: one BDD AND for the maintain moves, plus one Determinize. Merge into cycle strategy: O(1) structural operation.

**Implementation:**
- `ComputeR2PAliveRegion` call: `src/CycleCover.cpp:106-107`
- Guard and strategy merge: `src/CycleCover.cpp:109-113`
- `ComputeR2PPathStrategy` (builds two-phase strategy): `src/CycleCover.cpp:194-217`
- `ComputeReachabilityStrategy` (Phase 0 backward fixpoint): `src/CycleCover.cpp:24-57`
