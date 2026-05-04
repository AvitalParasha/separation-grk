#!/usr/bin/env python3
"""
R2R NoC Router benchmark generator.
Conjoins all 7 Type 1 (GF->GF) specs from Noc_Example.tex.
Parameterized by n input ports and k output ports.

Virtual Channels: each output port has 3 named VCs:
  - rd  (Read):        bulk memory read transactions
  - wr  (Write):       bulk memory write transactions
  - ll  (Low-Latency): high-priority signaling/control traffic
A flit arriving at input port i, destined for output port j, is assigned
to one of j's VCs by the routing/VC-allocation logic.

State machines:
  - Wormhole channel locking per (output port, VC) [Specs 1.1, 1.3, 1.7]
  - Conditional round-robin arbiter pointer [Spec 1.5]
  - NACK retry cooldown per input port [Specs 1.2, 1.4]

Specs per (input i, output j, VC v):
  1.1 Pipelined Deterministic Routing
  1.3 RDC Backpressure Protection

Specs per input port i:
  1.2 Security Firewall Enforcement
  1.4 Deadlock Timeout Resolution (per output j, VC v)

Specs per consecutive input pair (i, i+1):
  1.5 Switch Allocation Anti-Starvation
  1.6 QoS Preemptive Arbitration

Specs per output port j, per VC pair (v1, v2):
  1.7 Virtual Channel Bypass Multiplexing
"""

import sys

if len(sys.argv) < 3:
    print("Usage: " + sys.argv[0] + " <n_inputs> <k_outputs>")
    sys.exit(1)

n = int(sys.argv[1])  # input ports
k = int(sys.argv[2])  # output ports
if n < 1 or k < 1:
    print("n and k must be >= 1")
    sys.exit(1)

# Named virtual channels per output port
VCS = ["rd", "wr", "ll"]  # Read, Write, Low-Latency


def inv(name, i):
    return '"in:' + name + str(i) + '"'


def inv_vc(name, j, vc):
    """Input variable per (output port, VC)"""
    return '"in:' + name + str(j) + '_' + vc + '"'


def outv(name, i):
    return '"out:' + name + str(i) + '"'


def outv_vc(name, j, vc):
    """Output variable per (output port, VC)"""
    return '"out:' + name + str(j) + '_' + vc + '"'


def pair(name, i, j):
    return '"out:' + name + str(i) + '_' + str(j) + '"'


def ipair(name, i, j):
    return '"in:' + name + str(i) + '_' + str(j) + '"'


# ── Section 1: in_init ──
in_init = "1"

# ── Section 2: out_init (all outputs start false) ──
out_init_parts = []
# Per input port
for i in range(n):
    out_init_parts.append("!" + outv("nack_response", i))
    out_init_parts.append("!" + outv("nack_cooldown", i))
# Per output port
for j in range(k):
    out_init_parts.append("!" + outv("transmit_flit", j))
    # Wormhole lock and release per (output, VC)
    for vc in VCS:
        out_init_parts.append("!" + outv_vc("locked", j, vc))
        out_init_parts.append("!" + outv_vc("release_lock", j, vc))
# Per (input, output) pair
for i in range(n):
    for j in range(k):
        out_init_parts.append("!" + pair("forward_packet", i, j))
        out_init_parts.append("!" + pair("backpressure_data", i, j))
# Per consecutive input pair
for i in range(n - 1):
    out_init_parts.append("!" + outv("rr_arbitrate", i))
    out_init_parts.append("!" + outv("preempt_traffic", i))
# Round-robin state
for i in range(n):
    out_init_parts.append(("" if i == 0 else "!") + outv("rr_ptr", i))
out_init_parts.append("!" + outv("rr_mode", 0))
out_init = " &\n".join(out_init_parts)

# ── Section 3: in_trans (environment safety) ──
in_trans_parts = []
# Credit-reset exclusion per (output port, VC)
for j in range(k):
    for vc in VCS:
        in_trans_parts.append("(" + inv_vc("credit_received", j, vc) +
                              " -> !" + inv("reset_active", j) + ")")
# Flit presence per input port
for i in range(n):
    in_trans_parts.append("(" + inv("unauthorized_access", i) +
                          " -> " + inv("flit_ready", i) + ")")
# vc_timeout and blocked require flit present — these are per (output, VC)
# but the flit must exist at some input port destined for that output
# (modeled as: timeout/blocked at output j implies some input targets j)
# Deterministic routing: each input destined for at most one output
for i in range(n):
    for j1 in range(k):
        for j2 in range(j1 + 1, k):
            in_trans_parts.append("!(" + ipair("destined", i, j1) +
                                  " & " + ipair("destined", i, j2) + ")")
in_trans = " &\n".join(in_trans_parts) if in_trans_parts else "1"

# ── Section 4: out_trans (system safety) ──
out_trans_parts = []

# -- Wormhole channel locking per (output port, VC) [Specs 1.1, 1.3, 1.7] --
# System-controlled lock: forward locks a VC, release_lock frees it.
# All variables are outputs — no input/output mixing.
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
        # Release requires transmit (tail flit exits the port)
        out_trans_parts.append("(" + rl + " -> " + tf + ")")
    # Can't forward and release same output same step (minimum 2-step lock)
    for vc in VCS:
        rl = outv_vc("release_lock", j, vc)
        out_trans_parts.append("((" + any_fwd_j + ") -> !" + rl + ")")
    # At most one VC newly locked per forward
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
    # Forward requires at least one free VC on output j
    all_locked = " & ".join([outv_vc("locked", j, vc) for vc in VCS])
    for i in range(n):
        out_trans_parts.append("((" + all_locked + ") -> !" +
                               pair("forward_packet", i, j) + ")")
    # Pipeline staging: can't forward and transmit on same output same step [Spec 1.1]
    for i in range(n):
        out_trans_parts.append("!(" + pair("forward_packet", i, j) + " & " + tf + ")")

# -- Input port exclusion: each input can forward to at most one output per cycle --
for i in range(n):
    for j1 in range(k):
        for j2 in range(j1 + 1, k):
            out_trans_parts.append("!(" + pair("forward_packet", i, j1) +
                                   " & " + pair("forward_packet", i, j2) + ")")

# -- Backpressure prevents forwarding on same (i,j) [Spec 1.3 vs 1.1] --
for i in range(n):
    for j in range(k):
        out_trans_parts.append("!(" + pair("backpressure_data", i, j) +
                               " & " + pair("forward_packet", i, j) + ")")

# -- NACK retry cooldown per input port [Specs 1.2, 1.4] --
for i in range(n):
    nr = outv("nack_response", i)
    nc = outv("nack_cooldown", i)
    out_trans_parts.append("(" + nr + " -> X " + nc + ")")
    out_trans_parts.append("(" + nc + " -> !X " + nr + ")")
    out_trans_parts.append("(" + nc + " -> !X " + nc + ")")
    out_trans_parts.append("((!" + nr + " & !" + nc + ") -> !X " + nc + ")")

# -- NACK/forward mutual exclusion [Specs 1.2/1.4 vs 1.1] --
for i in range(n):
    nr = outv("nack_response", i)
    for j in range(k):
        out_trans_parts.append("!(" + nr + " & " + pair("forward_packet", i, j) + ")")

# -- Crossbar per-output-port exclusion [Spec 1.5, 1.6] --
# Two inputs can't forward to the SAME output simultaneously,
# but can forward to DIFFERENT outputs in the same cycle
for j in range(k):
    for i1 in range(n):
        for i2 in range(i1 + 1, n):
            out_trans_parts.append("!(X " + pair("forward_packet", i1, j) +
                                   " & X " + pair("forward_packet", i2, j) + ")")

# -- Conditional round-robin arbiter [Spec 1.5] --
rr_mode = outv("rr_mode", 0)
if n >= 2:
    for i in range(n):
        ptr_i = outv("rr_ptr", i)
        next_ptr = outv("rr_ptr", (i + 1) % n)
        if i < n - 1:
            arb_i = outv("rr_arbitrate", i)
            out_trans_parts.append("((" + rr_mode + " & " + ptr_i + " & " +
                                   arb_i + ") -> X " + next_ptr + ")")
        out_trans_parts.append("((" + ptr_i + " & !" + rr_mode + ") -> X " + ptr_i + ")")
    for i in range(n):
        for i2 in range(i + 1, n):
            out_trans_parts.append("!(X " + outv("rr_ptr", i) +
                                   " & X " + outv("rr_ptr", i2) + ")")
    out_trans_parts.append("(" + " | ".join(["X " + outv("rr_ptr", i)
                                             for i in range(n)]) + ")")
    for i in range(n - 1):
        out_trans_parts.append("((" + rr_mode + " & " + outv("rr_arbitrate", i) +
                               ") -> " + outv("rr_ptr", i) + ")")

out_trans = " &\n".join(out_trans_parts) if out_trans_parts else "1"

# ── Section 5: R2R implications (GF -> GF) ──
impls = []

# Spec 1.1: per (input i, output j, VC v) — credit on specific VC enables forwarding
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
            # 1.1 Pipelined Deterministic Routing
            impls.append("((G F (" + fr + " & " + de + " & " + cr +
                         ")) -> (G F " + fp + " & G F " + tf + "))")
        # 1.3 RDC Backpressure Protection (not VC-specific — reset affects whole port)
        impls.append("((G F (" + fr + " & " + de + " & " + ra +
                     ")) -> (G F " + bp + "))")

# Spec 1.2: per input port
for i in range(n):
    fr = inv("flit_ready", i)
    ua = inv("unauthorized_access", i)
    nr = outv("nack_response", i)
    # 1.2 Security Firewall Enforcement
    impls.append("((G F (" + fr + " & " + ua +
                 ")) -> (G F " + nr + "))")

# Spec 1.4: per (input i, output j, VC v) — timeout on specific output VC
for i in range(n):
    fr = inv("flit_ready", i)
    nr = outv("nack_response", i)
    for j in range(k):
        de = ipair("destined", i, j)
        for vc in VCS:
            vt = inv_vc("vc_timeout", j, vc)
            # 1.4 Deadlock Timeout Resolution
            impls.append("((G F (" + fr + " & " + de + " & " + vt +
                         ")) -> (G F " + nr + "))")

# Spec 1.5, 1.6: per consecutive input pair
for i in range(n - 1):
    i2 = i + 1
    fr_i = inv("flit_ready", i)
    fr_i2 = inv("flit_ready", i2)
    cfv = inv("contend_for_vc", i)
    qc = inv("qos_contention", i)
    rra = outv("rr_arbitrate", i)
    pt = outv("preempt_traffic", i)
    # 1.5 Switch Allocation Anti-Starvation
    impls.append("((G F (" + fr_i + " & " + fr_i2 + " & " + cfv +
                 ")) -> (G F " + rra + "))")
    # 1.6 QoS Preemptive Arbitration
    impls.append("((G F (" + fr_i + " & " + fr_i2 + " & " + qc +
                 ")) -> (G F " + pt + "))")

# Spec 1.7: VC bypass — per output port j, per VC pair (v1, v2)
# If VC v1 at output j is blocked but VC v2 has credits,
# the physical link j still transmits (from v2)
for j in range(k):
    tf = outv("transmit_flit", j)
    for v1 in VCS:
        for v2 in VCS:
            if v1 == v2:
                continue
            bl = inv_vc("blocked", j, v1)
            cr = inv_vc("credit_received", j, v2)
            # 1.7 Virtual Channel Bypass Multiplexing
            impls.append("((G F (" + bl + " & " + cr +
                         ")) -> (G F " + tf + "))")

fairness = " &\n".join(impls)

print(" ;\n".join([in_init, out_init, in_trans, out_trans, fairness]))
