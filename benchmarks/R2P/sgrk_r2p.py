from formulas import *

def format_persistences(persistences):
    return BigAnd(list(map(lambda p: "FG " + p, persistences)))

def format_justices(justices):
    return BigAnd(list(map(lambda justice: "GF " + justice, justices)))

def format_r2p_implication(impl):
    lhs, rhs = impl
    return IfThen(format_justices(lhs),
                  format_persistences(rhs))

def format_sgrk_r2p(in_init, out_init, in_trans, out_trans, impls):
    components = [" &\n".join(component)
                  for component in [in_init, out_init, in_trans, out_trans,
                                    list(map(format_r2p_implication, impls))]]

    return " ;\n".join(components)
