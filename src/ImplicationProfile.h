#ifndef IMPLICATION_PROFILE_H
#define IMPLICATION_PROFILE_H

#include <cstddef>
#include <vector>

#include "SeparationGrkSpec.h"

namespace SGrk {

// The supported combinations of justice-implication types. R2R is the base and
// may be combined with one of the other two; the unsupported combinations
// (any P2P, or R2P together with P2R) are rejected during classification.
enum class Combination { Empty, R2R, R2P, P2R, R2R_R2P, R2R_P2R };

// Single owner of the implication-type support matrix: partitions a spec's
// justice implications by type, names the resulting combination, and rejects
// unsupported combinations with a clear message.
//
// Buckets are stored as INDICES into spec.JusticeImplications() (rather than
// pointers) so a profile is a value type with no lifetime dependency on the
// spec — safe to store, move, and pass by value. Consumers join an index
// back to its implication via spec.JusticeImplications()[i].
class ImplicationProfile {
	std::vector<std::size_t> r2r_indices_;
	std::vector<std::size_t> r2p_indices_;
	std::vector<std::size_t> p2r_indices_;
	std::vector<std::size_t> cycling_indices_;  // union of R2R + P2R in spec order
	Combination combination_;

	ImplicationProfile(std::vector<std::size_t> r2r,
	                   std::vector<std::size_t> r2p,
	                   std::vector<std::size_t> p2r,
	                   std::vector<std::size_t> cycling,
	                   Combination combination);

 public:

	// Throws std::runtime_error with a human-readable message if the spec
	// contains any P2P (FG->FG) implication, or mixes R2P (GF->FG) with P2R
	// (FG->GF).
	static ImplicationProfile Classify(const SeparationGrkSpec& spec);

	Combination Kind() const;

	// Indices of each implication type in spec.JusticeImplications(), preserved
	// in spec order. Use as: `for (std::size_t i : profile.R2RIndices()) { ... }`.
	const std::vector<std::size_t>& R2RIndices() const;
	const std::vector<std::size_t>& R2PIndices() const;
	const std::vector<std::size_t>& P2RIndices() const;

	// Union of R2R and P2R indices in spec order — the implication types whose
	// guarantee side is GF (cycle-through) rather than FG (stabilize). These
	// are handled uniformly by ComputeCycleStrategy. Precomputed in Classify.
	const std::vector<std::size_t>& CyclingIndices() const;
};

}

#endif // IMPLICATION_PROFILE_H
