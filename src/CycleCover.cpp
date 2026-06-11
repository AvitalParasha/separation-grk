#include "CycleCover.h"

#include <numeric>

namespace SGrk {

CycleCover::CycleCover(std::shared_ptr<CUDD::Cudd> mgr,
                       std::shared_ptr<VarMgr> vars,
                       const SeparationGrkSpec& spec,
                       const SpaceConnectivity& connectivity)
	  // The initializers below have data dependencies on each other:
	  //   predicates_     uses profile_
	  //   artifacts_      uses profile_ and predicates_
	  //   covered_region_ uses profile_, predicates_, and artifacts_
	  //   cycle_strategy_ uses profile_, predicates_, and artifacts_
	  // This is safe because C++ runs member initializers in DECLARATION order
	  // (see CycleCover.h), and the declaration order matches the dependency
	  // chain. The order written here is just for readability — if you change
	  // it, do NOT also reorder the member declarations in the header.
	  : mgr_(std::move(mgr))
	  , vars_(std::move(vars))
	  , profile_(ImplicationProfile::Classify(spec))
	  , predicates_(ComputeImplicationPredicates(spec, connectivity))
	  , artifacts_(ComputeArtifacts(spec, connectivity))
	  , covered_region_(ComputeCoveredRegion(spec, connectivity))
	  , cycle_strategy_(ComputeCycleStrategy(spec, connectivity)) {}

CUDD::BDD CycleCover::CoveredRegion() const {
	return covered_region_;
}

const CycleStrategy& CycleCover::Strategy() const {
	return cycle_strategy_;
}

std::vector<CycleCover::ImplicationPredicates>
CycleCover::ComputeImplicationPredicates(
    const SeparationGrkSpec& spec,
    const SpaceConnectivity& connectivity) const {
	CUDD::BDD environment_bipath = connectivity.EnvironmentBipathRelation();
	CUDD::BDD system_bipath = connectivity.SystemBipathRelation();

	std::vector<ImplicationPredicates> predicates;

	for (const auto& implication : spec.JusticeImplications()) {
		ImplicationPredicates p;

		// env-side: can the environment cycle through the assumptions?
		// P2R assumptions are first closed into an alive region.
		if (implication.Type() == ImplicationType::P2R) {  // P2R
			CUDD::BDD alive_env = ComputeAliveRegion(
				spec.SafetyAssumptions(), implication.Assumptions(),
				vars_->PrimedInputs());
			p.can_satisfy_assumptions = HasCycle(environment_bipath, alive_env);
		} else {  // R2R or R2P
			p.can_satisfy_assumptions = mgr_->bddOne();
			for (const auto& assumption : implication.Assumptions()) {
				p.can_satisfy_assumptions &=
					HasCycle(environment_bipath, assumption);
			}
		}

		// sys-side: the two guarantee fields are complementary — each is consumed
		// by exactly one half of the implication types:
		//   can_satisfy_guarantees → read for R2R / P2R   (covered region check
		//                                                  in ComputeCoveredRegion)
		//   conjoined_guarantees   → read for R2P         (R2P demanded region
		//                                                  in ComputeArtifacts)
		// Only build the one each implication's type actually needs; leave the
		// other default-constructed.
		if (implication.Type() == ImplicationType::R2P) {
			p.conjoined_guarantees = mgr_->bddOne();
			for (const auto& guarantee : implication.Guarantees()) {
				p.conjoined_guarantees &= guarantee;
			}
		} else {  // P2R or R2R
			p.can_satisfy_guarantees = mgr_->bddOne();
			for (const auto& guarantee : implication.Guarantees()) {
				p.can_satisfy_guarantees &= HasCycle(system_bipath, guarantee);
			}
		}

		predicates.push_back(p);
	}

	return predicates;
}

CycleCover::Artifacts CycleCover::ComputeArtifacts(
    const SeparationGrkSpec& spec,
    const SpaceConnectivity& connectivity) const {
	Artifacts a;
	a.alive = mgr_->bddZero();
	a.restricted_transition = mgr_->bddZero();
	a.restricted_bipath = mgr_->bddZero();

	// The alive region (and everything derived from it) is only needed when R2P
	// is present (Combinations: R2P, R2R_R2P). Anything else returns early.
	if (profile_.R2PIndices().empty()) {
		return a;
	}

	// R2P alive region: shared by the covered region and the cycle strategy.
	CUDD::BDD r2p_demanded = mgr_->bddOne();
	for (std::size_t i : profile_.R2PIndices()) {
		r2p_demanded &= !predicates_[i].can_satisfy_assumptions |
			predicates_[i].conjoined_guarantees;
	}
	a.alive = ComputeStateDependentAliveRegion(
		spec.SafetyGuarantees(), r2p_demanded, vars_->PrimedOutputs());

	// R2R + R2P only: R2R goals must cycle within the alive region. Restrict the
	// relations to alive and precompute the per-R2R reachability strategies once.
	if (profile_.Kind() == Combination::R2R_R2P) {
		a.restricted_transition = spec.SafetyGuarantees() &
			a.alive & vars_->OutputUnprimedToPrimed(a.alive);
		a.restricted_bipath = connectivity.SystemBipathRelation() &
			a.alive & vars_->OutputUnprimedToPrimed(a.alive);

		for (std::size_t i : profile_.R2RIndices()) {
			a.r2r_restricted_strategies.emplace_back(
				i, ComputePathStrategy(a.restricted_transition, a.restricted_bipath,
				                       spec.JusticeImplications()[i].Guarantees()));
		}
	}

	return a;
}

MemorylessStrategy CycleCover::ComputeReachabilityStrategy(
    const CUDD::BDD& transition_relation,
    const CUDD::BDD& bipath_relation,
    const CUDD::BDD& goal) const {
	// States_0(s) = Goal(s)
	CUDD::BDD states = goal;

	// This strategy might be called when the game is already in a goal state,
	// so need to be sure the move from the goal state can come back to the goal
	//
	// Moves_0(s, s') = States_0(s) & T(s, s') & Bipath(s, s')
	CUDD::BDD moves = states & transition_relation & bipath_relation;

	while (true) {
		// Moves_i(s, s') = Moves_{i-1}(s, s') | (!States_{i-1}(s) & T(s, s') &
		//                                        Bipath(s, s') &
		//                                        States_{i-1}(s'))
		CUDD::BDD new_moves = moves |	(!states & transition_relation &
			                             bipath_relation &
			                             vars_->UnprimedToPrimed(states));

		// States_i(s) = Exists y' . Moves_i(s, s')
		CUDD::BDD new_states = vars_->Exists(vars_->PrimedVars(), new_moves);

		if (new_states == states) {
			CUDD::BDD winning_moves = new_moves;

			return MemorylessStrategy::Determinize(mgr_, vars_, winning_moves);
		}

		states = new_states;
		moves = new_moves;
	}
}

PathStrategy CycleCover::ComputePathStrategy(
    const CUDD::BDD& transition_relation,
    const CUDD::BDD& bipath_relation,
    const std::vector<CUDD::BDD>& goals) const {
	std::vector<MemorylessStrategy> strategy_parts;
	std::vector<CUDD::BDD> stopping_conditions;
	CUDD::BDD realizable_region = mgr_->bddOne();
	
	for (const CUDD::BDD& goal : goals) {
		MemorylessStrategy strategy_part =
			ComputeReachabilityStrategy(transition_relation, bipath_relation, goal);

		strategy_parts.push_back(strategy_part);
		stopping_conditions.push_back(vars_->UnprimedToPrimed(goal));
		realizable_region &= strategy_part.RealizableRegion();
	}

	return PathStrategy(realizable_region, std::move(strategy_parts), goals);
}

CycleStrategy CycleCover::ComputeCycleStrategy(
    const SeparationGrkSpec& spec,
    const SpaceConnectivity& connectivity) const {
	CUDD::BDD transition_relation = spec.SafetyGuarantees();
	CUDD::BDD bipath_relation = connectivity.SystemBipathRelation();

	if (profile_.Kind() == Combination::R2R_R2P) {  // R2R + R2P
		// R2R + R2P: restricted cycling within the alive region.
		MemorylessStrategy idle_strategy =
			MemorylessStrategy::Determinize(mgr_, vars_,
				artifacts_.restricted_transition & artifacts_.restricted_bipath);

		CycleStrategy cycle_strategy(mgr_, vars_, idle_strategy);

		for (const auto& indexed_strategy : artifacts_.r2r_restricted_strategies) {
			cycle_strategy.Merge(indexed_strategy.second);
		}

		// Reach-to-alive recovery phase: covers states inside the covered region
		// but outside the R2P alive region (the R2P clause of ComputeCoveredRegion
		// guarantees these are reachable to alive via the system bipath). The idle
		// strategy and R2R reachability strategies above are all alive-restricted,
		// so without this merge the cycle strategy would have no defined behavior
		// at outside-alive states. Uses the UNRESTRICTED transition/bipath because
		// outside alive we cannot stay alive-only. Realizable region restricted to
		// !alive so it does not compete with the R2R strategies inside alive.
		MemorylessStrategy reach_to_alive_strategy =
			ComputeReachabilityStrategy(transition_relation, bipath_relation,
			                            artifacts_.alive);
		CUDD::BDD outside_alive_realizable =
			reach_to_alive_strategy.RealizableRegion() & !artifacts_.alive;
		if (!outside_alive_realizable.IsZero()) {
			std::vector<MemorylessStrategy> reach_parts = { reach_to_alive_strategy };
			std::vector<CUDD::BDD> reach_stops = {
				vars_->UnprimedToPrimed(artifacts_.alive)
			};
			PathStrategy reach_to_alive(outside_alive_realizable,
			                            std::move(reach_parts),
			                            std::move(reach_stops));
			cycle_strategy.Merge(reach_to_alive);
		}

		return cycle_strategy;

	} else {  // pure R2R, pure P2R, pure R2P, or R2R+P2R
		// Pure R2R/P2R, pure R2P, or R2R+P2R: existing logic
		MemorylessStrategy idle_strategy =
			MemorylessStrategy::Determinize(mgr_, vars_,
			                                transition_relation & bipath_relation);

		CycleStrategy cycle_strategy(mgr_, vars_, idle_strategy);

		// All cycling-style implications (R2R + P2R) handled uniformly, in spec
		// order — both demand GF on the guarantee side.
		for (std::size_t i : profile_.CyclingIndices()) {
			PathStrategy path_strategy = ComputePathStrategy(
				transition_relation, bipath_relation,
				spec.JusticeImplications()[i].Guarantees());
			cycle_strategy.Merge(path_strategy);
		}

		if (profile_.Kind() == Combination::R2P &&
		    !artifacts_.alive.IsZero()) {  // pure R2P sub-case
			PathStrategy path_strategy = ComputeR2PPathStrategy(
				transition_relation, bipath_relation, artifacts_.alive);
			cycle_strategy.Merge(path_strategy);
		}

		return cycle_strategy;
	}
}

CUDD::BDD CycleCover::HasCycle(const CUDD::BDD& connected,
                               const CUDD::BDD& prop) const {
	// Exists s' . Connected(s, s') & Prop(s')
	return vars_->Exists(vars_->PrimedVars(),
	                     connected & vars_->UnprimedToPrimed(prop));
}

CUDD::BDD CycleCover::ComputeAliveRegion(
    const CUDD::BDD& safety_constraint,
    const std::vector<CUDD::BDD>& properties,
    const CUDD::BDD& primed_quantification_vars) const {
	// Conjunction of all properties: states where ALL hold simultaneously
	CUDD::BDD all_g = mgr_->bddOne();
	for (const auto& g : properties) {
		all_g &= g;
	}

	// Safety fixpoint: largest subset of all_g that is closed
	// under transitions (every state has a successor in the set)
	CUDD::BDD alive = all_g;
	while (true) {
		CUDD::BDD new_alive = alive &
			vars_->Exists(primed_quantification_vars,
				safety_constraint & vars_->UnprimedToPrimed(alive));
		if (new_alive == alive) return alive;
		alive = new_alive;
	}
}

CUDD::BDD CycleCover::ComputeStateDependentAliveRegion(
    const CUDD::BDD& safety_constraint,
    const CUDD::BDD& demanded,
    const CUDD::BDD& primed_quantification_vars) const {
	CUDD::BDD alive = demanded;
	while (true) {
		CUDD::BDD new_alive = alive &
			vars_->Exists(primed_quantification_vars,
				safety_constraint & vars_->OutputUnprimedToPrimed(alive));
		if (new_alive == alive) return alive;
		alive = new_alive;
	}
}

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

	// OR (not AND) because the two phases operate in disjoint state regions:
	// Phase 0 (reach) activates OUTSIDE alive, Phase 1 (maintain) activates INSIDE.
	// AND would restrict the realizable region to just alive (dominated by maintain),
	// making the reach phase dead code — the cycle strategy would never activate it
	// from states outside alive, falling back to idle instead of driving toward alive.
	CUDD::BDD realizable = reach_strategy.RealizableRegion() |
	                        maintain_strategy.RealizableRegion();
	return PathStrategy(realizable, std::move(parts), std::move(stops));
}

CUDD::BDD CycleCover::ComputeCoveredRegion(
    const SeparationGrkSpec& spec,
    const SpaceConnectivity& connectivity) const {
	CUDD::BDD valid_states =
		connectivity.ValidStates();
	CUDD::BDD bipath_relation =
		connectivity.BipathRelation();
	CUDD::BDD system_bipath_relation =
		connectivity.SystemBipathRelation();

	CUDD::BDD cycle_states = valid_states & vars_->Exists(vars_->PrimedVars(),
	                                                      bipath_relation &
	                                                      vars_->Reflexive());

	CUDD::BDD covered_region = cycle_states;

	if (profile_.Kind() == Combination::R2R_R2P) {  // R2R + R2P
		// R2R + R2P: R2R goals must be cycleable within the alive region. Use the
		// per-R2R reachability strategies precomputed in artifacts_.
		for (const auto& indexed_strategy : artifacts_.r2r_restricted_strategies) {
			std::size_t i = indexed_strategy.first;
			CUDD::BDD can_satisfy_guarantees =
				indexed_strategy.second.RealizableRegion();
			covered_region &= !predicates_[i].can_satisfy_assumptions |
				can_satisfy_guarantees;
		}

		// R2P clause: system must be able to reach alive
		CUDD::BDD can_satisfy_r2p_assumptions = mgr_->bddOne();
		for (std::size_t i : profile_.R2PIndices()) {
			can_satisfy_r2p_assumptions &= predicates_[i].can_satisfy_assumptions;
		}
		CUDD::BDD can_satisfy_r2p = vars_->Exists(vars_->PrimedOutputs(),
			system_bipath_relation & vars_->OutputUnprimedToPrimed(artifacts_.alive));
		covered_region &= !can_satisfy_r2p_assumptions | can_satisfy_r2p;

	} else {  // pure R2R, pure P2R, pure R2P, or R2R+P2R
		// All cycling-style implications (R2R + P2R): the standard
		// covered-region clause is "env can't cycle assumptions OR system can".
		for (std::size_t i : profile_.CyclingIndices()) {
			covered_region &= !predicates_[i].can_satisfy_assumptions |
				predicates_[i].can_satisfy_guarantees;
		}

		// R2P clause (pure R2P only — R2R+R2P is handled in the other branch,
		// and R2P+P2R is rejected by ImplicationProfile::Classify): system must
		// be able to reach alive.
		if (!profile_.R2PIndices().empty()) {
			CUDD::BDD can_satisfy_r2p = vars_->Exists(vars_->PrimedOutputs(),
				system_bipath_relation & vars_->OutputUnprimedToPrimed(artifacts_.alive));

			covered_region &= can_satisfy_r2p;
		}
	}

	return covered_region;
}

}
