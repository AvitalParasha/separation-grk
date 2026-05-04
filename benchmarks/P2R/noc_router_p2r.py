#!/usr/bin/env python3
"""
P2R NoC Router benchmark generator.
Conjoins all 5 Type 2 (FG->GF) specs from Noc_Example.tex.
Parameterized by n input ports and k output ports.

Virtual Channels: each output port has 3 named VCs:
  - rd  (Read):        bulk memory read transactions
  - wr  (Write):       bulk memory write transactions
  - ll  (Low-Latency): high-priority signaling/control traffic

State machines:
  - Wormhole channel locking per (output port, VC) [Specs 2.1, 2.2]
  - NACK retry cooldown per input port [Spec 2.3]

Specs per (input i, output j, VC v):
  2.1 Pipelined Deterministic Routing

Specs per (input i, output j):
  2.2 Sustained RDC Backpressure Protection

Specs per input port i:
  2.3 Persistent Security Firewall Enforcement

Specs per consecutive input pair (i, i+1):
  2.4 Starvation Freedom under Permanent Preemption

Specs per output port j, per VC v:
  2.5 Permanent VC Congestion Bypass
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


def outv_vc(name, j, vc):
    return '"out:' + name + str(j) + '_' + vc + '"'


def pair(name, i, j):
    return '"out:' + name + str(i) + '_' + str(j) + '"'


def ipair(name, i, j):
    return '"in:' + name + str(i) + '_' + str(j) + '"'


# ── Section 1: in_init ──
in_init = "1"

# ── Section 2: out_init ──
out_init_parts = []
for i in range(n):
    out_init_parts.append("!" + outv("nack_response", i))
    out_init_parts.append("!" + outv("nack_cooldown", i))
for j in range(k):
    out_init_parts.append("!" + outv("transmit_flit", j))
    for vc in VCS:
        out_init_parts.append("!" + outv_vc("locked", j, vc))
        out_init_parts.append("!" + outv_vc("release_lock", j, vc))
for i in range(n):
    for j in range(k):
        out_init_parts.append("!" + pair("forward_packet", i, j))
        out_init_parts.append("!" + pair("backpressure_data", i, j))
out_init = " &\n".join(out_init_parts)

# ── Section 3: in_trans ──
in_trans_parts = []
for j in range(k):
    for vc in VCS:
        in_trans_parts.append("(" + inv_vc("credit_received", j, vc) +
                              " -> !" + inv("reset_active", j) + ")")
for i in range(n):
    in_trans_parts.append("(" + inv("unauthorized_access", i) +
                          " -> " + inv("flit_ready", i) + ")")
for i in range(n):
    for j1 in range(k):
        for j2 in range(j1 + 1, k):
            in_trans_parts.append("!(" + ipair("destined", i, j1) +
                                  " & " + ipair("destined", i, j2) + ")")
in_trans = " &\n".join(in_trans_parts) if in_trans_parts else "1"

# ── Section 4: out_trans ──
out_trans_parts = []

# Wormhole locking per (output, VC) [Specs 2.1, 2.2]
# System-controlled lock: forward locks a VC, release_lock frees it.
for j in range(k):
    tf = outv("transmit_flit", j)
    any_fwd_j = " | ".join([pair("forward_packet", i, j) for i in range(n)])
    for vc in VCS:
        lk = outv_vc("locked", j, vc)
        rl = outv_vc("release_lock", j, vc)
        # Locked + release -> free next step
        out_trans_parts.append("((" + lk + " & " + rl + ") -> !X " + lk + ")")
        # Locked + no release -> stays locked
        out_trans_parts.append("((" + lk + " & !" + rl + ") -> X " + lk + ")")
        # Free + no forward -> stays free
        out_trans_parts.append("((!" + lk + " & !(" + any_fwd_j + ")) -> !X " + lk + ")")
        # Release only when locked
        out_trans_parts.append("(" + rl + " -> " + lk + ")")
        # Release requires transmit (tail flit exits)
        out_trans_parts.append("(" + rl + " -> " + tf + ")")
    # Can't forward and release same output same step (minimum 2-step lock)
    for vc in VCS:
        rl = outv_vc("release_lock", j, vc)
        out_trans_parts.append("((" + any_fwd_j + ") -> !" + rl + ")")
    # At most one VC newly locked per step
    for vc1_idx in range(len(VCS)):
        for vc2_idx in range(vc1_idx + 1, len(VCS)):
            lk1 = outv_vc("locked", j, VCS[vc1_idx])
            lk2 = outv_vc("locked", j, VCS[vc2_idx])
            out_trans_parts.append("!(((!" + lk1 + " & X " + lk1 +
                                   ") & (!" + lk2 + " & X " + lk2 + ")))")
    # Forward MUST lock exactly one VC (wormhole invariant)
    newly_locked = [("(!" + outv_vc("locked", j, vc) + " & X " + outv_vc("locked", j, vc) + ")")
                    for vc in VCS]
    out_trans_parts.append("((" + any_fwd_j + ") -> (" + " | ".join(newly_locked) + "))")
    # Forward requires at least one free VC
    all_locked = " & ".join([outv_vc("locked", j, vc) for vc in VCS])
    for i in range(n):
        out_trans_parts.append("((" + all_locked + ") -> !" +
                               pair("forward_packet", i, j) + ")")
    # Pipeline staging
    for i in range(n):
        out_trans_parts.append("!(" + pair("forward_packet", i, j) + " & " + tf + ")")

# Input port exclusion: each input forwards to at most one output per cycle
for i in range(n):
    for j1 in range(k):
        for j2 in range(j1 + 1, k):
            out_trans_parts.append("!(" + pair("forward_packet", i, j1) +
                                   " & " + pair("forward_packet", i, j2) + ")")

# Backpressure prevents forwarding on same (i,j) [Spec 2.2 vs 2.1]
for i in range(n):
    for j in range(k):
        out_trans_parts.append("!(" + pair("backpressure_data", i, j) +
                               " & " + pair("forward_packet", i, j) + ")")

# NACK cooldown per input port [Spec 2.3]
for i in range(n):
    nr = outv("nack_response", i)
    nc = outv("nack_cooldown", i)
    out_trans_parts.append("(" + nr + " -> X " + nc + ")")
    out_trans_parts.append("(" + nc + " -> !X " + nr + ")")
    out_trans_parts.append("(" + nc + " -> !X " + nc + ")")
    out_trans_parts.append("((!" + nr + " & !" + nc + ") -> !X " + nc + ")")

# NACK/forward exclusion
for i in range(n):
    nr = outv("nack_response", i)
    for j in range(k):
        out_trans_parts.append("!(" + nr + " & " + pair("forward_packet", i, j) + ")")

# Crossbar per-output-port exclusion
# Two inputs can't forward to the SAME output simultaneously,
# but can forward to DIFFERENT outputs in the same cycle
for j in range(k):
    for i1 in range(n):
        for i2 in range(i1 + 1, n):
            out_trans_parts.append("!(X " + pair("forward_packet", i1, j) +
                                   " & X " + pair("forward_packet", i2, j) + ")")

out_trans = " &\n".join(out_trans_parts) if out_trans_parts else "1"

# ── Section 5: P2R implications (FG -> GF) ──
impls = []

# 2.1: per (input i, output j, VC v)
for i in range(n):
    fr = inv("flit_ready", i)
    for j in range(k):
        de = ipair("destined", i, j)
        ra = inv("reset_active", j)
        fp = pair("forward_packet", i, j)
        tf = outv("transmit_flit", j)
        bp = pair("backpressure_data", i, j)
        for vc in VCS:
            cr = inv_vc("credit_received", j, vc)
            # 2.1 Pipelined Deterministic Routing
            impls.append("((F G (" + fr + " & " + de + " & " + cr +
                         ")) -> (G F " + fp + " & G F " + tf + "))")
        # 2.2 Sustained RDC Backpressure Protection (not VC-specific)
        impls.append("((F G (" + fr + " & " + de + " & " + ra +
                     ")) -> (G F " + bp + "))")

# 2.3: per input port
for i in range(n):
    fr = inv("flit_ready", i)
    ua = inv("unauthorized_access", i)
    nr = outv("nack_response", i)
    impls.append("((F G (" + fr + " & " + ua +
                 ")) -> (G F " + nr + "))")

# 2.4: Starvation freedom under permanent preemption — per consecutive input pair
for i in range(n - 1):
    i2 = i + 1
    hpp = inv("high_priority_preempt", i)
    for j in range(k):
        fp_k = pair("forward_packet", i2, j)
        impls.append("((F G " + hpp +
                     ") -> (G F " + fp_k + "))")

# 2.5: Permanent VC congestion bypass — per output port j, per VC v
for j in range(k):
    tf = outv("transmit_flit", j)
    for vc in VCS:
        bl = inv_vc("blocked", j, vc)
        impls.append("((F G " + bl +
                     ") -> (G F " + tf + "))")

fairness = " &\n".join(impls)

print(" ;\n".join([in_init, out_init, in_trans, out_trans, fairness]))
