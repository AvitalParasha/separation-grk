import sys

from formulas import *

if len(sys.argv) < 2:
    print("Usage: " + sys.argv[0] + " <#pairs>")
else:
    n = int(sys.argv[1])

    if n < 1:
        print("Number of pairs must be a positive integer, defaulting to 1")
        n = 1

    a_vars = ["out:a" + str(i) for i in range(n)]
    b_vars = ["out:b" + str(i) for i in range(n)]

    # Initial assumptions: true
    in_init = "1"

    # Initial guarantees: all outputs start false
    out_init = " &\n".join(
        [Not(Var(v)) for v in a_vars + b_vars])

    # Safety assumptions: true
    in_trans = "1"

    # Safety guarantees:
    #   (a_i & !b_i) -> !X a_i     (trap: from (1,0), a must reset)
    #   (a_i &  b_i) ->  X a_i     (absorbing: from (1,1), a stays)
    #   (a_i &  b_i) ->  X b_i     (absorbing: from (1,1), b stays)
    out_trans = " &\n".join(
        [IfThen(And(Var(a_vars[i]), Not(Var(b_vars[i]))),
                Not(Next(Var(a_vars[i])))) + " &\n" +
         IfThen(And(Var(a_vars[i]), Var(b_vars[i])),
                Next(Var(a_vars[i]))) + " &\n" +
         IfThen(And(Var(a_vars[i]), Var(b_vars[i])),
                Next(Var(b_vars[i])))
         for i in range(n)])

    # Fairness: (GF trigger) -> (FG a_i) for each pair
    fairness = " &\n".join(
        ['((GF "in:trigger") -> (FG ' + Var(a_vars[i]) + '))'
         for i in range(n)])

    print(" ;\n".join([in_init, out_init, in_trans, out_trans, fairness]))
