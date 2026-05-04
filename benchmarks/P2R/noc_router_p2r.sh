#!/bin/bash
MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
export PYTHONPATH="${MYDIR}/..:${PYTHONPATH}"

# VCs are fixed: rd (read), wr (write), ll (low-latency)
for n in {1..10}; do
    for k in {1..4}; do
        python3 "${MYDIR}/noc_router_p2r.py" ${n} ${k} > "${MYDIR}/noc_router_p2r/noc_router_p2r_${n}_${k}.sgrk"
    done
done
