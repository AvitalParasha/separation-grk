#include "ImplicationProfile.h"

#include <stdexcept>

namespace SGrk {

ImplicationProfile::ImplicationProfile(
    std::vector<std::size_t> r2r,
    std::vector<std::size_t> r2p,
    std::vector<std::size_t> p2r,
    std::vector<std::size_t> cycling,
    Combination combination)
	: r2r_indices_(std::move(r2r))
	, r2p_indices_(std::move(r2p))
	, p2r_indices_(std::move(p2r))
	, cycling_indices_(std::move(cycling))
	, combination_(combination) {}

ImplicationProfile ImplicationProfile::Classify(const SeparationGrkSpec& spec) {
	std::vector<std::size_t> r2r, r2p, p2r, cycling;
	bool has_p2p = false;

	const auto& implications = spec.JusticeImplications();
	for (std::size_t i = 0; i < implications.size(); ++i) {
		switch (implications[i].Type()) {
			case ImplicationType::R2R:
				r2r.push_back(i);
				cycling.push_back(i);  // GF-guarantee, cycles
				break;
			case ImplicationType::R2P:
				r2p.push_back(i);
				break;
			case ImplicationType::P2R:
				p2r.push_back(i);
				cycling.push_back(i);  // GF-guarantee, cycles
				break;
			case ImplicationType::P2P:
				has_p2p = true;
				break;
		}
	}

	if (has_p2p) {
		throw std::runtime_error(
			"P2P (FG->FG) implications are not supported.");
	}

	bool has_r2r = !r2r.empty();
	bool has_r2p = !r2p.empty();
	bool has_p2r = !p2r.empty();

	if (has_r2p && has_p2r) {
		throw std::runtime_error(
			"R2P (GF->FG) + P2R (FG->GF) mixed implications are not supported.");
	}

	Combination combination;
	if (!has_r2r && !has_r2p && !has_p2r) {
		combination = Combination::Empty;
	} else if (has_r2r && has_r2p) {
		combination = Combination::R2R_R2P;
	} else if (has_r2r && has_p2r) {
		combination = Combination::R2R_P2R;
	} else if (has_r2p) {
		combination = Combination::R2P;
	} else if (has_p2r) {
		combination = Combination::P2R;
	} else {
		combination = Combination::R2R;
	}

	return ImplicationProfile(std::move(r2r), std::move(r2p), std::move(p2r),
	                          std::move(cycling), combination);
}

Combination ImplicationProfile::Kind() const {
	return combination_;
}

const std::vector<std::size_t>& ImplicationProfile::R2RIndices() const {
	return r2r_indices_;
}

const std::vector<std::size_t>& ImplicationProfile::R2PIndices() const {
	return r2p_indices_;
}

const std::vector<std::size_t>& ImplicationProfile::P2RIndices() const {
	return p2r_indices_;
}

const std::vector<std::size_t>& ImplicationProfile::CyclingIndices() const {
	return cycling_indices_;
}

}
