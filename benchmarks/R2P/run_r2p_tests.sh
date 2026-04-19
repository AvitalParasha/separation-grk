#!/bin/bash
MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
SGRK="${MYDIR}/../../bin/sgrk"

# Default timeout in seconds (0 = no timeout)
TIMEOUT=${TIMEOUT:-120}

# Portable timeout (works on macOS without coreutils)
source "${MYDIR}/../timeout_helper.sh"

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
        run_with_timeout "$TIMEOUT" "$SGRK" "$f"
        result="$_timeout_output"
        exit_code=$_timeout_exit
        if [[ $exit_code -eq 142 ]]; then
            echo "TIMEOUT (${TIMEOUT}s)"
            SKIP=$((SKIP + 1))
            continue
        fi
    else
        result=$("$SGRK" "$f" 2>&1)
    fi

    echo -n "$result"

    # Determine expected result from directory and filename
    case "$dir" in
        forced_oscillation|noc_enforcement)
            if [[ "$name" == *"realizable"* ]]; then
                expected="Realizable"
            else
                expected="Unrealizable"
            fi ;;
        power_grid)
            if [[ "$name" == *"realizable"* ]]; then
                expected="Realizable"
            else
                expected="Unrealizable"
            fi ;;
        *)
            expected="Realizable" ;;
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
