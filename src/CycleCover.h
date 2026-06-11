#ifndef CYCLE_COVER_H
#define CYCLE_COVER_H

#include <memory>
#include <utility>
#include <vector>

#include "cuddObj.hh"

#include "CycleStrategy.h"
#include "MemorylessStrategy.h"
#include "SeparationGrkSpec.h"
#include "SpaceConnectivity.h"
#include "VarMgr.h"

namespace SGrk {

class CycleCover {
	std::shared_ptr<CUDD::Cudd> mgr_;
	std::shared_ptr<VarMgr> vars_;

	// Per-implication satisfiability predicates, computed once and reused by
	// both ComputeCoveredRegion and ComputeCycleStrategy. Indexed in the same
	// order as spec.JusticeImplications().
	struct ImplicationPredicates {
		// env-side: can the environment cycle through this implication's
		// assumptions? (For P2R, the assumptions are first closed into an alive
		// region.)
		CUDD::BDD can_satisfy_assumptions;
		// sys-side: can the system cycle through all of this implication's
		// guarantees?
		CUDD::BDD can_satisfy_guarantees;
		// raw conjunction of this implication's guarantee formulas (used to
		// build the R2P demanded region).
		CUDD::BDD conjoined_guarantees;
	};

	std::vector<ImplicationPredicates> predicates_;

	// Shared artifacts computed once and consumed by both ComputeCoveredRegion
	// and ComputeCycleStrategy, so the expensive fixpoints (the R2P alive region
	// and the per-R2R reachability strategies) are not computed twice.
	struct Artifacts {
		bool has_r2p = false;
		bool has_r2r = false;
		// The R2P alive region (valid when has_r2p). bddZero otherwise.
		CUDD::BDD alive;
		// System transition/bipath relations restricted to the alive region
		// (valid when has_r2p && has_r2r). bddZero otherwise.
		CUDD::BDD restricted_transition;
		CUDD::BDD restricted_bipath;
		// Per-R2R reachability strategies computed within the alive restriction
		// (when has_r2p && has_r2r), paired with the implication's index so the
		// covered region can match each against predicates_[i]. Built in spec
		// order, which is the order the cycle strategy merges them.
		std::vector<std::pair<std::size_t, PathStrategy>> r2r_restricted_strategies;
	};

	Artifacts artifacts_;
	// IMPORTANT — DO NOT REORDER the four members above and below.
	// C++ initializes members in DECLARATION order (in this class), NOT in
	// the order written in the constructor's initializer list. Initialization
	// dependencies:
	//   artifacts_      reads predicates_     (must come after predicates_)
	//   covered_region_ reads predicates_ and artifacts_
	//   cycle_strategy_ reads predicates_ and artifacts_
	// Reordering will silently produce wrong results — empty/default BDDs
	// being read before they're built. The matching initializer-list order in
	// CycleCover.cpp is only cosmetic; this declaration order is what the
	// compiler actually obeys.
	CUDD::BDD covered_region_;
	CycleStrategy cycle_strategy_;

	// Builds the predicates_ table: walks the implications once and precomputes
	// each implication's reusable satisfiability predicates (see
	// ImplicationPredicates). Called once from the constructor.
	std::vector<ImplicationPredicates> ComputeImplicationPredicates(
	    const SeparationGrkSpec& spec,
	    const SpaceConnectivity& connectivity) const;

	// Builds the artifacts_ struct: the R2P alive region and the
	// alive-restricted relations/strategies shared by ComputeCoveredRegion and
	// ComputeCycleStrategy. Reads predicates_, so it must run after it. Called
	// once from the constructor.
	Artifacts ComputeArtifacts(
	    const SeparationGrkSpec& spec,
	    const SpaceConnectivity& connectivity) const;

	MemorylessStrategy ComputeReachabilityStrategy(
	  const CUDD::BDD& transition_relation,
	  const CUDD::BDD& bipath_relation,
	  const CUDD::BDD& goal) const;

	PathStrategy ComputePathStrategy(
    const CUDD::BDD& transition_relation,
    const CUDD::BDD& bipath_relation,
    const std::vector<CUDD::BDD>& goals) const;

	CycleStrategy ComputeCycleStrategy(
    const SeparationGrkSpec& spec,
    const SpaceConnectivity& connectivity) const;

	CUDD::BDD HasCycle(const CUDD::BDD& connected, const CUDD::BDD& prop) const;

	CUDD::BDD ComputeAliveRegion(
	    const CUDD::BDD& safety_constraint,
	    const std::vector<CUDD::BDD>& properties,
	    const CUDD::BDD& primed_quantification_vars) const;

	PathStrategy ComputeR2PPathStrategy(
	    const CUDD::BDD& transition_relation,
	    const CUDD::BDD& bipath_relation,
	    const CUDD::BDD& alive_region) const;

	CUDD::BDD ComputeStateDependentAliveRegion(
	    const CUDD::BDD& safety_constraint,
	    const CUDD::BDD& demanded,
	    const CUDD::BDD& primed_quantification_vars) const;

	CUDD::BDD ComputeCoveredRegion(const SeparationGrkSpec& spec,
	                               const SpaceConnectivity& connectivity) const;
	
 public:

	CycleCover(std::shared_ptr<CUDD::Cudd> mgr, std::shared_ptr<VarMgr> vars,
	           const SeparationGrkSpec& spec,
	           const SpaceConnectivity& connectivity);

	CUDD::BDD CoveredRegion() const;
	const CycleStrategy& Strategy() const;
};

}

#endif // CYCLE_COVER_H
