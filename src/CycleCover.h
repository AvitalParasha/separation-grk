#ifndef CYCLE_COVER_H
#define CYCLE_COVER_H

#include <memory>
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
	CUDD::BDD covered_region_;
	CycleStrategy cycle_strategy_;

	std::vector<ImplicationPredicates> ComputeImplicationPredicates(
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
