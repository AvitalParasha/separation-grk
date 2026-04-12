import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from formulas import *

if len(sys.argv) < 2:
    print("Usage: " + sys.argv[0] + " <#bits>")
else:
    n = int(sys.argv[1])

    if n < 1:
        print("Number of bits must be a positive integer, defaulting to 1")
        n = 1

    bits = ["out:bit" + str(i) for i in range(n)]

    # Initial assumptions: true
    in_init = "1"

    # Initial guarantees: all bits start false
    out_init = " &\n".join([Not(Var(b)) for b in bits])

    # Safety assumptions: true
    in_trans = "1"

    # Safety guarantees: true (bits can freely toggle)
    out_trans = "1"

    # P2R fairness: (FG trigger) -> (GF bit_i & GF !bit_i) for each bit
    # Each bit must both be set and unset infinitely often
    fairness = " &\n".join(
        ['((FG "in:trigger") -> (GF ' + Var(b) + ' & GF ' + Not(Var(b)) + '))'
         for b in bits])

    print(" ;\n".join([in_init, out_init, in_trans, out_trans, fairness]))
