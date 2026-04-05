#!/bin/bash
MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
SGRK="${MYDIR}/../../bin/sgrk"

# Default timeout in seconds (0 = no timeout)
TIMEOUT=${TIMEOUT:-120}

echo "=== R2P Benchmarks ==="
PASS=0
FAIL=0
SKIP=0

for f in "${MYDIR}"/**/*.sgrk; do
    name="$(basename "$f")"
    dir="$(basename "$(dirname "$f")")"

    # Skip the mixed test file — tested separately
    if [[ "$name" == "mixed_r2r_r2p.sgrk" ]]; then
        continue
    fi

    echo -n "${dir}/${name}: "

    if [[ "$TIMEOUT" -gt 0 ]]; then
        result=$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$SGRK" "$f" 2>&1)
        exit_code=$?
        if [[ $exit_code -eq 142 ]]; then
            echo "TIMEOUT (${TIMEOUT}s)"
            SKIP=$((SKIP + 1))
            continue
        fi
    else
        result=$("$SGRK" "$f" 2>&1)
    fi

    echo -n "$result"

    # Determine expected result from directory name
    case "$dir" in
        forced_oscillation) expected="Unrealizable" ;;
        *)                  expected="Realizable" ;;
    esac

    if [[ "$result" == "$expected" ]]; then
        echo " (OK)"
        PASS=$((PASS + 1))
    else
        echo " (MISMATCH: expected $expected)"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "R2P: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
