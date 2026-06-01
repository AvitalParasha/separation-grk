#ifndef IMPLICATION_PROFILE_H
#define IMPLICATION_PROFILE_H

#include <vector>

#include "SeparationGrkSpec.h"

namespace SGrk {

// The supported combinations of justice-implication types. R2R is the base and
// may be combined with one of the other two; the unsupported combinations
// (any P2P, or R2P together with P2R) are rejected during classification.
enum class Combination { Empty, R2R, R2P, P2R, R2R_R2P, R2R_P2R };

// Single owner of the implication-type support matrix: partitions a spec's
// justice implications by type and names the resulting combination, rejecting
// unsupported combinations with a clear message.
//
// The returned profile holds pointers into the spec's implication vector, so it
// must not outlive the spec it was classified from.
class ImplicationProfile {
	std::vector<const SeparationGrkImplication*> r2r_;
	std::vector<const SeparationGrkImplication*> r2p_;
	std::vector<const SeparationGrkImplication*> p2r_;
	Combination combination_;

	ImplicationProfile(std::vector<const SeparationGrkImplication*> r2r,
	                   std::vector<const SeparationGrkImplication*> r2p,
	                   std::vector<const SeparationGrkImplication*> p2r,
	                   Combination combination);

 public:

	// Throws std::runtime_error with a human-readable message if the spec
	// contains any P2P (FG->FG) implication, or mixes R2P (GF->FG) with P2R
	// (FG->GF).
	static ImplicationProfile Classify(const SeparationGrkSpec& spec);

	Combination Kind() const;
	const std::vector<const SeparationGrkImplication*>& R2R() const;
	const std::vector<const SeparationGrkImplication*>& R2P() const;
	const std::vector<const SeparationGrkImplication*>& P2R() const;
};

}

#endif // IMPLICATION_PROFILE_H
