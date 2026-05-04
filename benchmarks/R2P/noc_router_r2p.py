#!/usr/bin/env python3
"""
R2P NoC Router benchmark generator.
Conjoins all 6 Type 4 (GF->FG) specs from Noc_Example.tex.
Parameterized by n input ports and k output ports.

Virtual Channels: each output port has 3 named VCs (rd, wr, ll).
Spec 4.2 uses VCs via vc_timeout per (output port, VC).

Spec 4.5 uses separate indices: bist_fault_detected(i) is per input port
(faulty block), spare_resource_available(j) and reconfigure_spare(j) are per
output port (the spare replaces an output link). This creates n*k implications.

State constraints:
  - Escalation monotonicity [Specs 4.1-4.6]
  - Escalation ordering: bypass_faulty_block(i) requires revoke_grant(i) [Specs 4.5, 4.6]
  - Sequential escalation per input port [Specs 4.1-4.4, 4.6]
  - Sequential escalation per output port [Spec 4.5]
  - One escalation per step [Specs 4.1-4.6]
  - Spare mutual exclusion per output port [Spec 4.5]
"""

import sys

if len(sys.argv) < 3:
    print("Usage: " + sys.argv[0] + " <n_inputs> <k_outputs>")
    sys.exit(1)

n = int(sys.argv[1])
k = int(sys.argv[2])
if n < 1 or k < 1:
    print("n and k must be >= 1")
    sys.exit(1)

VCS = ["rd", "wr", "ll"]


def inv(name, i):
    return '"in:' + name + str(i) + '"'


def inv_vc(name, j, vc):
    return '"in:' + name + str(j) + '_' + vc + '"'


def outv(name, i):
    return '"out:' + name + str(i) + '"'


def outv_j(name, j):
    """Output variable indexed by output port"""
    return '"out:' + name + '_o' + str(j) + '"'


# ── Section 1: in_init ──
in_init = "1"

# ── Section 2: out_init ──
out_init_parts = []
# Per input port: bound_injection, revoke_grant, bypass_faulty_block
for i in range(n):
    out_init_parts.append("!" + outv("bound_injection", i))
    out_init_parts.append("!" + outv("revoke_grant", i))
    out_init_parts.append("!" + outv("bypass_faulty_block", i))
# Per output port: reconfigure_spare
for j in range(k):
    out_init_parts.append("!" + outv_j("reconfigure_spare", j))
out_init = " &\n".join(out_init_parts) if out_init_parts else "1"

# ── Section 3: in_trans ──
in_trans_parts = []
# Fault type exclusion per input port
for i in range(n):
    bist = inv("bist_fault_detected", i)
    ecc = inv("ecc_uncorrectable_error", i)
    in_trans_parts.append("!(" + bist + " & " + ecc + ")")
# Spare mutual exclusion per OUTPUT port (one spare at a time)
for j in range(k):
    for j2 in range(j + 1, k):
        in_trans_parts.append("!(" + inv("spare_resource_available_o", j) +
                              " & " + inv("spare_resource_available_o", j2) + ")")
in_trans = " &\n".join(in_trans_parts) if in_trans_parts else "1"

# ── Section 4: out_trans ──
out_trans_parts = []

# Collect all output variables for one-escalation-per-step
all_outputs = []

# -- Per input port: bound_injection, revoke_grant, bypass_faulty_block --
for i in range(n):
    bi = outv("bound_injection", i)
    rg = outv("revoke_grant", i)
    bf = outv("bypass_faulty_block", i)
    all_outputs += [bi, rg, bf]

    # Escalation ordering: bypass requires revoke (same domain, both per input i)
    out_trans_parts.append("(X " + bf + " -> X " + rg + ")")

    # Escalation monotonicity
    out_trans_parts.append("(" + rg + " -> X " + rg + ")")
    out_trans_parts.append("(" + bi + " -> X " + bi + ")")
    out_trans_parts.append("(" + bf + " -> X " + bf + ")")

# Sequential escalation per input port
for i in range(n - 1):
    i2 = i + 1
    out_trans_parts.append("(X " + outv("revoke_grant", i2) +
                           " -> X " + outv("revoke_grant", i) + ")")
    out_trans_parts.append("(X " + outv("bound_injection", i2) +
                           " -> X " + outv("bound_injection", i) + ")")
    out_trans_parts.append("(X " + outv("bypass_faulty_block", i2) +
                           " -> X " + outv("bypass_faulty_block", i) + ")")

# -- Per output port: reconfigure_spare --
for j in range(k):
    rs = outv_j("reconfigure_spare", j)
    all_outputs.append(rs)

    # Escalation monotonicity
    out_trans_parts.append("(" + rs + " -> X " + rs + ")")

# Sequential escalation per output port
for j in range(k - 1):
    j2 = j + 1
    out_trans_parts.append("(X " + outv_j("reconfigure_spare", j2) +
                           " -> X " + outv_j("reconfigure_spare", j) + ")")

# -- One escalation per step (across ALL outputs, both input and output indexed) --
for a in range(len(all_outputs)):
    for b in range(a + 1, len(all_outputs)):
        va = all_outputs[a]
        vb = all_outputs[b]
        out_trans_parts.append("!((!" + va + " & X " + va +
                               ") & (!" + vb + " & X " + vb + "))")

out_trans = " &\n".join(out_trans_parts) if out_trans_parts else "1"

# ── Section 5: R2P implications (GF -> FG) ──
impls = []
for i in range(n):
    hpp = inv("high_priority_preempt", i)
    hsv = inv("hready_stall_violation", i)
    ua = inv("unauthorized_access", i)
    bist = inv("bist_fault_detected", i)
    ecc = inv("ecc_uncorrectable_error", i)
    fcv = inv("flow_control_violation", i)
    bi = outv("bound_injection", i)
    rg = outv("revoke_grant", i)
    bf = outv("bypass_faulty_block", i)

    # 4.1 QoS Priority Bounding
    impls.append("((G F " + hpp + ") -> (F G " + bi + "))")
    # 4.2 DoS Injection Suppression — per (output port j, VC v)
    for j in range(k):
        for vc in VCS:
            vt = inv_vc("vc_timeout", j, vc)
            impls.append("((G F " + vt + ") -> (F G " + bi + "))")
    # 4.3 Bus Lock Violation Penalty
    impls.append("((G F " + hsv + ") -> (F G " + rg + "))")
    # 4.4 Malicious Node Isolation
    impls.append("((G F " + ua + ") -> (F G " + rg + "))")
    # 4.5 Compound BIST-Based Reconfiguration — per (input i, output j)
    # Fault on input i, spare replaces output j
    for j in range(k):
        spare = inv("spare_resource_available_o", j)
        rs = outv_j("reconfigure_spare", j)
        impls.append("((G F " + bist + " & G F " + spare +
                     ") -> (F G " + bf + " & F G " + rs + "))")
    # 4.6 Hardware Fault Containment
    impls.append("((G F " + ecc + " & G F " + fcv +
                 ") -> (F G " + rg + " & F G " + bi + "))")

fairness = " &\n".join(impls)

print(" ;\n".join([in_init, out_init, in_trans, out_trans, fairness]))
