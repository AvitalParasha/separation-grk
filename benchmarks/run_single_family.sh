#!/bin/bash
# ============================================================================
# run_single_family.sh — Slurm worker: runs ONE tool on ONE benchmark family
# ============================================================================
#
# Called by compare_results_HPC.sh via sbatch. Not meant to be run directly.
#
# Usage: bash run_single_family.sh <tool> <family_dir> <timeout> [--strix=<path>] [--spot=<path>]
#   tool:       sgrk | strix | spot
#   family_dir: full path to family dir (e.g., /home/.../benchmarks/R2R/cleaning_robots)
#   timeout:    per-test timeout in seconds
# ============================================================================

set -uo pipefail

MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"

# Source environment
source ~/work/setup_env.sh 2>/dev/null || true

SGRK="${MYDIR}/../bin/sgrk"
TOSTRIX="${MYDIR}/to_strix.py"
source "${MYDIR}/timeout_helper.sh"

# Defaults
STRIX_BIN="${STRIX:-$HOME/work/strix}"
SPOT_BIN="${SPOT:-ltlsynt}"

# Parse arguments
TOOL="$1"
FAMILY_DIR="$2"
TIMEOUT="$3"
shift 3

for arg in "$@"; do
    case "$arg" in
        --strix=*) STRIX_BIN="${arg#*=}" ;;
        --spot=*)  SPOT_BIN="${arg#*=}" ;;
    esac
done

FAMILY="$(basename "$FAMILY_DIR")"
CATEGORY="$(basename "$(dirname "$FAMILY_DIR")")"

# Determine runtime file name
case "$TOOL" in
    sgrk)  RUNTIME_FILE="${FAMILY_DIR}/runtime" ;;
    strix) RUNTIME_FILE="${FAMILY_DIR}/strix_runtime" ;;
    spot)  RUNTIME_FILE="${FAMILY_DIR}/spot_runtime" ;;
    *)     echo "ERROR: Unknown tool: $TOOL"; exit 1 ;;
esac

# Collect .sgrk files
sgrk_files=()
while IFS= read -r line; do
    sgrk_files+=("$line")
done < <(find "$FAMILY_DIR" -maxdepth 1 -name "*.sgrk" ! -name "mixed_*" | sort -V)

if [[ ${#sgrk_files[@]} -eq 0 ]]; then
    echo "No .sgrk files in $FAMILY_DIR"
    exit 0
fi

echo "=== ${TOOL} on ${CATEGORY}/${FAMILY} (${#sgrk_files[@]} tests, timeout=${TIMEOUT}s) ==="

# Write header
printf "%-45s %10s %10s %12s  %-15s\n" "Test" "Seconds" "ms" "us" "Result" > "$RUNTIME_FILE"
printf "%-45s %10s %10s %12s  %-15s\n" "----" "-------" "--" "--" "------" >> "$RUNTIME_FILE"

hit_timeout=false

for f in "${sgrk_files[@]}"; do
    name="$(basename "$f")"

    # Cascade skip on timeout
    if [[ "$hit_timeout" == true ]]; then
        printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "SKIPPED" >> "$RUNTIME_FILE"
        echo "  $name: SKIPPED (cascade)"
        continue
    fi

    # Prepare strix/spot conversion if needed
    if [[ "$TOOL" == "strix" || "$TOOL" == "spot" ]]; then
        strix_file="${f}.strix"
        if [[ ! -s "$strix_file" ]]; then
            python3 "$TOSTRIX" "$f" > "$strix_file" 2>/dev/null
        fi
        if [[ ! -s "$strix_file" ]]; then
            printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "CONVERT_ERROR" >> "$RUNTIME_FILE"
            echo "  $name: CONVERT_ERROR"
            continue
        fi
        ins=$(grep -o '"in:[^"]*"' "$f" | sort -u | sed 's/"//g' | paste -sd, -)
        outs=$(grep -o '"out:[^"]*"' "$f" | sort -u | sed 's/"//g' | paste -sd, -)
    fi

    # Build command
    case "$TOOL" in
        sgrk)
            cmd=("$SGRK" "$f")
            ;;
        strix)
            cmd=("$STRIX_BIN" -r -F "$strix_file" --ins "$ins" --outs "$outs")
            ;;
        spot)
            formula=$(cat "$strix_file")
            cmd=("$SPOT_BIN" -f "$formula" --ins="$ins" --outs="$outs" --realizability)
            ;;
    esac

    # Run with timeout
    start_time=$(python3 -c "import time; print(time.time())")
    run_with_timeout "$TIMEOUT" "${cmd[@]}"
    result="$_timeout_output"
    exit_code=$_timeout_exit
    end_time=$(python3 -c "import time; print(time.time())")

    if [[ $exit_code -eq 142 ]]; then
        printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "TIMEOUT" >> "$RUNTIME_FILE"
        echo "  $name: TIMEOUT"
        hit_timeout=true
        continue
    fi

    # Normalize result — anything other than Realizable/Unrealizable is N/A
    result_lower=$(echo "$result" | tr '[:upper:]' '[:lower:]')
    if [[ "$result_lower" != "realizable" && "$result_lower" != "unrealizable" ]]; then
        result="N/A"
    fi

    elapsed_s=$(python3 -c "print(f'{${end_time} - ${start_time}:.3f}')")
    elapsed_ms=$(python3 -c "print(int((${end_time} - ${start_time}) * 1000))")
    elapsed_us=$(python3 -c "print(int((${end_time} - ${start_time}) * 1000000))")

    printf "%-45s %9ss %8sms %10sus  %-15s\n" "$name" "$elapsed_s" "$elapsed_ms" "$elapsed_us" "$result" >> "$RUNTIME_FILE"
    echo "  $name: ${elapsed_s}s  $result"
done

echo "=== Done: ${TOOL} on ${CATEGORY}/${FAMILY} ==="
echo "Results: $RUNTIME_FILE"
