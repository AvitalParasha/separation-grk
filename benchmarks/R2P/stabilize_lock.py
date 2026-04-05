import sys

from formulas import *

if len(sys.argv) < 2:
    print("Usage: " + sys.argv[0] + " <#locks>")
else:
    n = int(sys.argv[1])

    if n < 1:
        print("Number of locks must be a positive integer, defaulting to 1")
        n = 1

    locked = ["out:locked" + str(i) for i in range(n)]

    # Initial assumptions: true (no constraints on environment)
    in_init = "1"

    # Initial guarantees: all locks start false
    out_init = " &\n".join([Not(Var(l)) for l in locked])

    # Safety assumptions: true
    in_trans = "1"

    # Safety guarantees: once locked, stay locked
    out_trans = " &\n".join(
        [IfThen(Var(l), Next(Var(l))) for l in locked])

    # Fairness: (GF trigger) -> (FG locked_i) for each lock
    fairness = " &\n".join(
        ['((GF "in:trigger") -> (FG ' + Var(l) + '))'
         for l in locked])

    print(" ;\n".join([in_init, out_init, in_trans, out_trans, fairness]))
