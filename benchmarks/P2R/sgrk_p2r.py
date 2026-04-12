from formulas import *

def format_persistences(persistences):
    return BigAnd(list(map(lambda p: "FG " + p, persistences)))

def format_justices(justices):
    return BigAnd(list(map(lambda justice: "GF " + justice, justices)))

def format_p2r_implication(impl):
    lhs, rhs = impl
    return IfThen(format_persistences(lhs),
                  format_justices(rhs))

def format_sgrk_p2r(in_init, out_init, in_trans, out_trans, impls):
    components = [" &\n".join(component)
                  for component in [in_init, out_init, in_trans, out_trans,
                                    list(map(format_p2r_implication, impls))]]

    return " ;\n".join(components)
