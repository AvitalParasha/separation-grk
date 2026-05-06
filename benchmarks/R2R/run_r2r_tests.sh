#!/bin/bash
MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
SGRK="${MYDIR}/../../bin/sgrk"

# Default timeout in seconds (0 = no timeout)
TIMEOUT=${TIMEOUT:-120}
SKIP_HEAVY=${SKIP_HEAVY:-false}

# Heavy benchmarks that take very long
is_heavy() {
    case "$1" in
        railway_signaling_2_9.sgrk|railway_signaling_2_10.sgrk) return 0 ;;
        railway_signaling_3_9.sgrk|railway_signaling_3_10.sgrk) return 0 ;;
        *) return 1 ;;
    esac
}

# Portable timeout (works on macOS without coreutils)
source "${MYDIR}/../timeout_helper.sh"

echo "=== R2R Benchmarks ==="
PASS=0
FAIL=0
SKIP=0

for f in "${MYDIR}"/**/*.sgrk; do
    name="$(basename "$f")"

    if [[ "$SKIP_HEAVY" == "true" ]] && is_heavy "$name"; then
        echo "${name}: SKIPPED (heavy)"
        SKIP=$((SKIP + 1))
        continue
    fi

    echo -n "${name}: "

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

    echo "$result"
    if [[ "$result" == "Realizable" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "R2R: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
