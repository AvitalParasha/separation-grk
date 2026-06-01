#include "CycleCover.h"

#include <numeric>

namespace SGrk {

CycleCover::CycleCover(std::shared_ptr<CUDD::Cudd> mgr,
                       std::shared_ptr<VarMgr> vars,
                       const SeparationGrkSpec& spec,
                       const SpaceConnectivity& connectivity)
	  : mgr_(std::move(mgr))
	  , vars_(std::move(vars))
	  , predicates_(ComputeImplicationPredicates(spec, connectivity))
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
		if (implication.Type() == ImplicationType::P2R) {
			CUDD::BDD alive_env = ComputeAliveRegion(
				spec.SafetyAssumptions(), implication.Assumptions(),
				vars_->PrimedInputs());
			p.can_satisfy_assumptions = HasCycle(environment_bipath, alive_env);
		} else {
			p.can_satisfy_assumptions = mgr_->bddOne();
			for (const auto& assumption : implication.Assumptions()) {
				p.can_satisfy_assumptions &=
					HasCycle(environment_bipath, assumption);
			}
		}

		// sys-side: can the system cycle through all the guarantees?
		p.can_satisfy_guarantees = mgr_->bddOne();
		for (const auto& guarantee : implication.Guarantees()) {
			p.can_satisfy_guarantees &= HasCycle(system_bipath, guarantee);
		}

		// raw conjunction of the guarantee formulas (for the R2P demanded region)
		p.conjoined_guarantees = mgr_->bddOne();
		for (const auto& guarantee : implication.Guarantees()) {
			p.conjoined_guarantees &= guarantee;
		}

		predicates.push_back(p);
	}

	return predicates;
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

	const auto& implications = spec.JusticeImplications();

	bool has_r2p = false;
	bool has_r2r = false;
	for (const auto& implication : implications) {
		if (implication.Type() == ImplicationType::R2P) has_r2p = true;
		if (implication.Type() == ImplicationType::R2R) has_r2r = true;
	}

	if (has_r2p && has_r2r) {
		// R2R + R2P: restricted cycling within alive region
		CUDD::BDD r2p_demanded = mgr_->bddOne();

		for (std::size_t i = 0; i < implications.size(); ++i) {
			if (implications[i].Type() != ImplicationType::R2P) continue;
			r2p_demanded &= !predicates_[i].can_satisfy_assumptions |
				predicates_[i].conjoined_guarantees;
		}

		CUDD::BDD alive = ComputeStateDependentAliveRegion(
			spec.SafetyGuarantees(), r2p_demanded, vars_->PrimedOutputs());

		CUDD::BDD restricted_transition = transition_relation &
			alive & vars_->OutputUnprimedToPrimed(alive);
		CUDD::BDD restricted_bipath = bipath_relation &
			alive & vars_->OutputUnprimedToPrimed(alive);

		MemorylessStrategy idle_strategy =
			MemorylessStrategy::Determinize(mgr_, vars_,
			                                restricted_transition & restricted_bipath);

		CycleStrategy cycle_strategy(mgr_, vars_, idle_strategy);

		for (const auto& implication : spec.JusticeImplications()) {
			if (implication.Type() == ImplicationType::R2R) {
				PathStrategy path_strategy = ComputePathStrategy(
					restricted_transition, restricted_bipath,
					implication.Guarantees());
				cycle_strategy.Merge(path_strategy);
			}
		}

		return cycle_strategy;

	} else {
		// Pure R2R/P2R, pure R2P, or R2R+P2R: existing logic
		MemorylessStrategy idle_strategy =
			MemorylessStrategy::Determinize(mgr_, vars_,
			                                transition_relation & bipath_relation);

		CycleStrategy cycle_strategy(mgr_, vars_, idle_strategy);

		bool has_r2p_impl = false;

		for (const auto& implication : spec.JusticeImplications()) {
			if (implication.Type() == ImplicationType::R2R ||
			    implication.Type() == ImplicationType::P2R) {
				PathStrategy path_strategy = ComputePathStrategy(
					transition_relation, bipath_relation, implication.Guarantees());
				cycle_strategy.Merge(path_strategy);
			} else {
				has_r2p_impl = true;
			}
		}

		if (has_r2p_impl) {
			CUDD::BDD r2p_demanded = mgr_->bddOne();

			for (std::size_t i = 0; i < implications.size(); ++i) {
				if (implications[i].Type() != ImplicationType::R2P) continue;
				r2p_demanded &= !predicates_[i].can_satisfy_assumptions |
					predicates_[i].conjoined_guarantees;
			}

			CUDD::BDD alive = ComputeStateDependentAliveRegion(
				spec.SafetyGuarantees(), r2p_demanded, vars_->PrimedOutputs());

			if (!alive.IsZero()) {
				PathStrategy path_strategy = ComputeR2PPathStrategy(
					transition_relation, bipath_relation, alive);
				cycle_strategy.Merge(path_strategy);
			}
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

	const auto& implications = spec.JusticeImplications();

	bool has_r2p = false;
	bool has_r2r = false;
	for (const auto& implication : implications) {
		if (implication.Type() == ImplicationType::R2P) has_r2p = true;
		if (implication.Type() == ImplicationType::R2R) has_r2r = true;
	}

	if (has_r2p && has_r2r) {
		// R2R + R2P: R2R goals must be cycleable within alive

		// Compute R2P alive region
		CUDD::BDD r2p_demanded = mgr_->bddOne();
		for (std::size_t i = 0; i < implications.size(); ++i) {
			if (implications[i].Type() != ImplicationType::R2P) continue;
			r2p_demanded &= !predicates_[i].can_satisfy_assumptions |
				predicates_[i].conjoined_guarantees;
		}

		CUDD::BDD alive = ComputeStateDependentAliveRegion(
			spec.SafetyGuarantees(), r2p_demanded, vars_->PrimedOutputs());

		// Restrict transition and bipath to alive
		CUDD::BDD restricted_transition = spec.SafetyGuarantees() &
			alive & vars_->OutputUnprimedToPrimed(alive);
		CUDD::BDD restricted_bipath = system_bipath_relation &
			alive & vars_->OutputUnprimedToPrimed(alive);

		// R2R implications: check guarantees within alive
		for (std::size_t i = 0; i < implications.size(); ++i) {
			if (implications[i].Type() != ImplicationType::R2R) continue;

			PathStrategy restricted_strategy = ComputePathStrategy(
				restricted_transition, restricted_bipath,
				implications[i].Guarantees());
			CUDD::BDD can_satisfy_guarantees = restricted_strategy.RealizableRegion();

			covered_region &= !predicates_[i].can_satisfy_assumptions |
				can_satisfy_guarantees;
		}

		// R2P clause: system must be able to reach alive
		CUDD::BDD can_satisfy_r2p_assumptions = mgr_->bddOne();
		for (std::size_t i = 0; i < implications.size(); ++i) {
			if (implications[i].Type() != ImplicationType::R2P) continue;
			can_satisfy_r2p_assumptions &= predicates_[i].can_satisfy_assumptions;
		}
		CUDD::BDD can_satisfy_r2p = vars_->Exists(vars_->PrimedOutputs(),
			system_bipath_relation & vars_->OutputUnprimedToPrimed(alive));
		covered_region &= !can_satisfy_r2p_assumptions | can_satisfy_r2p;

	} else {
		// Pure R2R, pure P2R, pure R2P, or R2R+P2R: existing logic

		bool has_r2p_impl = false;

		for (std::size_t i = 0; i < implications.size(); ++i) {
			if (implications[i].Type() == ImplicationType::R2P) {
				has_r2p_impl = true;
				continue;
			}

			covered_region &= !predicates_[i].can_satisfy_assumptions |
				predicates_[i].can_satisfy_guarantees;
		}

		if (has_r2p_impl) {
			CUDD::BDD r2p_demanded = mgr_->bddOne();
			for (std::size_t i = 0; i < implications.size(); ++i) {
				if (implications[i].Type() != ImplicationType::R2P) continue;
				r2p_demanded &= !predicates_[i].can_satisfy_assumptions |
					predicates_[i].conjoined_guarantees;
			}

			CUDD::BDD alive = ComputeStateDependentAliveRegion(
				spec.SafetyGuarantees(), r2p_demanded, vars_->PrimedOutputs());

			CUDD::BDD can_satisfy_r2p = vars_->Exists(vars_->PrimedOutputs(),
				system_bipath_relation & vars_->OutputUnprimedToPrimed(alive));

			covered_region &= can_satisfy_r2p;
		}
	}

	return covered_region;
}

}
