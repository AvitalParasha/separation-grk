#!/bin/bash
MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
SGRK="${MYDIR}/../bin/sgrk"

usage() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --timeout=SECONDS   Per-benchmark timeout (default: 120, 0 = no timeout)"
    echo "  --skip-heavy        Skip benchmarks known to take very long"
    echo "  --help              Show this help"
}

# Parse arguments
export TIMEOUT=120
export SKIP_HEAVY=false

for arg in "$@"; do
    case "$arg" in
        --timeout=*)  export TIMEOUT="${arg#*=}" ;;
        --skip-heavy) export SKIP_HEAVY=true ;;
        --help)       usage; exit 0 ;;
        *)            echo "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

echo "Settings: timeout=${TIMEOUT}s, skip-heavy=${SKIP_HEAVY}"
echo ""

# Mixed type rejection test
echo "=== Mixed Type Rejection Test ==="

MIXED_PASS=0
MIXED_FAIL=0

for f in "${MYDIR}/R2R/mixed_r2r_r2p.sgrk" "${MYDIR}/R2P/mixed_r2r_r2p.sgrk" "${MYDIR}/P2R/mixed_p2r_r2r.sgrk"; do
    if [[ ! -f "$f" ]]; then
        continue
    fi
    echo -n "$(basename "$f") (from $(basename "$(dirname "$f")")): "
    result=$("$SGRK" "$f" 2>&1)
    exit_code=$?
    if [[ $exit_code -eq 1 ]] && echo "$result" | grep -q "mixed implication types"; then
        echo "correctly rejected"
        MIXED_PASS=$((MIXED_PASS + 1))
    else
        echo "UNEXPECTED: $result (exit code $exit_code)"
        MIXED_FAIL=$((MIXED_FAIL + 1))
    fi
done

echo "Mixed: ${MIXED_PASS} passed, ${MIXED_FAIL} failed"
echo ""

# Run R2R tests
bash "${MYDIR}/R2R/run_r2r_tests.sh"
echo ""

# Run R2P tests
bash "${MYDIR}/R2P/run_r2p_tests.sh"
echo ""

# Run P2R tests
bash "${MYDIR}/P2R/run_p2r_tests.sh"
