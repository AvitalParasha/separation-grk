import sys

from formulas import *

if len(sys.argv) < 2:
    print("Usage: " + sys.argv[0] + " <#bits>")
else:
    n = int(sys.argv[1])

    if n < 1:
        print("Number of bits must be a positive integer, defaulting to 1")
        n = 1

    bits = ["out:bit" + str(i) for i in range(n)]

    # Initial assumptions: trigger starts true
    in_init = Var("in:trigger")

    # Initial guarantees: all bits start true
    out_init = " &\n".join([Var(b) for b in bits])

    # Safety assumptions: true
    in_trans = "1"

    # Safety guarantees: each bit must toggle every step
    out_trans = " &\n".join(
        [IfThen(Var(b), Not(Next(Var(b)))) + " &\n" +
         IfThen(Not(Var(b)), Next(Var(b)))
         for b in bits])

    # Fairness: (GF trigger) -> (FG bit_i) for each bit
    fairness = " &\n".join(
        ['((GF "in:trigger") -> (FG ' + Var(b) + '))'
         for b in bits])

    print(" ;\n".join([in_init, out_init, in_trans, out_trans, fairness]))
