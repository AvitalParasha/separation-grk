#include "ImplicationProfile.h"

#include <stdexcept>

namespace SGrk {

ImplicationProfile::ImplicationProfile(
    std::vector<const SeparationGrkImplication*> r2r,
    std::vector<const SeparationGrkImplication*> r2p,
    std::vector<const SeparationGrkImplication*> p2r,
    Combination combination)
	: r2r_(std::move(r2r))
	, r2p_(std::move(r2p))
	, p2r_(std::move(p2r))
	, combination_(combination) {}

ImplicationProfile ImplicationProfile::Classify(const SeparationGrkSpec& spec) {
	std::vector<const SeparationGrkImplication*> r2r, r2p, p2r;
	bool has_p2p = false;

	for (const SeparationGrkImplication& implication : spec.JusticeImplications()) {
		switch (implication.Type()) {
			case ImplicationType::R2R: r2r.push_back(&implication); break;
			case ImplicationType::R2P: r2p.push_back(&implication); break;
			case ImplicationType::P2R: p2r.push_back(&implication); break;
			case ImplicationType::P2P: has_p2p = true; break;
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
	                          combination);
}

Combination ImplicationProfile::Kind() const {
	return combination_;
}

const std::vector<const SeparationGrkImplication*>&
ImplicationProfile::R2R() const {
	return r2r_;
}

const std::vector<const SeparationGrkImplication*>&
ImplicationProfile::R2P() const {
	return r2p_;
}

const std::vector<const SeparationGrkImplication*>&
ImplicationProfile::P2R() const {
	return p2r_;
}

}
