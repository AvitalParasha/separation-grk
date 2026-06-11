#ifndef SEPARATION_CHECK_H
#define SEPARATION_CHECK_H

#include "SeparationGrkSpec.h"
#include "VarMgr.h"

namespace SGrk {

// Verifies the "separation" property the synthesis algorithm relies on:
// assumption formulas must depend only on input variables (current and primed),
// and guarantee formulas only on output variables. Walks every formula's BDD
// support and checks each variable index is on the expected side.
//
// Throws std::runtime_error with a human-readable message listing the offending
// formula + offending variable on the first violation found. Cheap — one
// linear walk per formula at startup, no fixpoint.
void CheckSeparation(const SeparationGrkSpec& spec, const VarMgr& vars);

}

#endif // SEPARATION_CHECK_H
