#include "SeparationCheck.h"

#include <set>
#include <stdexcept>
#include <string>

namespace SGrk {

namespace {

enum class AllowedSide { INPUT, OUTPUT };

// Build the set of BDD variable indices belonging to the allowed side
// (counting both unprimed and primed). Indices are CUDD's per-variable global
// indices, the same ones returned by BDD::SupportIndices().
std::set<unsigned int> AllowedIndices(const VarMgr& vars, AllowedSide side) {
	CUDD::BDD unprimed_cube = (side == AllowedSide::INPUT)
		? vars.UnprimedInputs() : vars.UnprimedOutputs();
	CUDD::BDD primed_cube = (side == AllowedSide::INPUT)
		? vars.PrimedInputs() : vars.PrimedOutputs();

	std::set<unsigned int> allowed;
	for (unsigned int idx : unprimed_cube.SupportIndices()) allowed.insert(idx);
	for (unsigned int idx : primed_cube.SupportIndices()) allowed.insert(idx);
	return allowed;
}

// Throw on the first variable in `formula`'s support that isn't allowed.
void VerifyFormula(const CUDD::BDD& formula, const std::set<unsigned int>& allowed,
                   const std::string& formula_name,
                   const std::string& expected_side) {
	for (unsigned int idx : formula.SupportIndices()) {
		if (allowed.find(idx) == allowed.end()) {
			throw std::runtime_error(
				"Separation violated in " + formula_name +
				": references a variable that is not " + expected_side +
				". Assumptions must use only `in:` variables; " +
				"guarantees must use only `out:` variables.");
		}
	}
}

}  // namespace

void CheckSeparation(const SeparationGrkSpec& spec, const VarMgr& vars) {
	std::set<unsigned int> input_side = AllowedIndices(vars, AllowedSide::INPUT);
	std::set<unsigned int> output_side = AllowedIndices(vars, AllowedSide::OUTPUT);

	VerifyFormula(spec.InitialAssumptions(), input_side,
	              "initial assumptions", "an input");
	VerifyFormula(spec.InitialGuarantees(), output_side,
	              "initial guarantees", "an output");
	VerifyFormula(spec.SafetyAssumptions(), input_side,
	              "safety assumptions", "an input");
	VerifyFormula(spec.SafetyGuarantees(), output_side,
	              "safety guarantees", "an output");

	std::size_t idx = 0;
	for (const SeparationGrkImplication& impl : spec.JusticeImplications()) {
		for (std::size_t a = 0; a < impl.Assumptions().size(); ++a) {
			VerifyFormula(impl.Assumptions()[a], input_side,
			              "implication " + std::to_string(idx) +
			              " assumption " + std::to_string(a),
			              "an input");
		}
		for (std::size_t g = 0; g < impl.Guarantees().size(); ++g) {
			VerifyFormula(impl.Guarantees()[g], output_side,
			              "implication " + std::to_string(idx) +
			              " guarantee " + std::to_string(g),
			              "an output");
		}
		++idx;
	}
}

}
