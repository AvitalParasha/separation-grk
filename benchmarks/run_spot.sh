#!/bin/bash
# Unified Spot (ltlsynt) benchmark runner with timing tables.
# Converts .sgrk files to LTL format and runs them through ltlsynt.
# Works across all formula types (R2R, R2P, P2R).
#
# Usage: bash run_spot.sh [--spot=<path>] [--timeout=SECONDS] [R2R|R2P|P2R|all]

MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
TOSTRIX="${MYDIR}/to_strix.py"  # Same LTL format works for both Strix and Spot

# Defaults
SPOT="ltlsynt"
TIMEOUT=1800
CATEGORY="all"

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --spot=*)    SPOT="${arg#*=}" ;;
        --timeout=*) TIMEOUT="${arg#*=}" ;;
        R2R|R2P|P2R|all) CATEGORY="$arg" ;;
        --help)
            echo "Usage: $(basename "$0") [--spot=<path>] [--timeout=SECONDS] [R2R|R2P|P2R|all]"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

if ! command -v "$SPOT" &>/dev/null; then
    echo "Error: ltlsynt not found at $SPOT"
    echo "Install Spot or specify path: $(basename "$0") --spot=<path-to-ltlsynt>"
    exit 1
fi

echo "Using: $($SPOT --version 2>&1 | head -1)"
echo ""

# Determine which categories to run
if [[ "$CATEGORY" == "all" ]]; then
    CATEGORIES=(R2R R2P P2R)
else
    CATEGORIES=("$CATEGORY")
fi

# Portable timeout (works on macOS without coreutils)
source "${MYDIR}/timeout_helper.sh"

for cat in "${CATEGORIES[@]}"; do
    cat_dir="${MYDIR}/${cat}"
    if [[ ! -d "$cat_dir" ]]; then
        continue
    fi

    echo "========================================"
    echo "  ${cat} Benchmarks (Spot/ltlsynt)"
    echo "========================================"
    echo ""

    for family_dir in "${cat_dir}"/*/; do
        [[ ! -d "$family_dir" ]] && continue
        family="$(basename "$family_dir")"

        # Collect .sgrk files, skip mixed test files
        sgrk_files=()
        while IFS= read -r line; do
            sgrk_files+=("$line")
        done < <(find "$family_dir" -maxdepth 1 -name "*.sgrk" ! -name "mixed_*" | sort -V)

        if [[ ${#sgrk_files[@]} -eq 0 ]]; then
            continue
        fi

        echo "=== ${cat} / ${family} ==="

        # Print table header
        printf "%-45s %10s %10s %12s  %-15s\n" "Test" "Seconds" "ms" "us" "Result"
        printf "%-45s %10s %10s %12s  %-15s\n" "----" "-------" "--" "--" "------"

        spot_runtime_file="${family_dir}/spot_runtime"
        printf "%-45s %10s %10s %12s  %-15s\n" "Test" "Seconds" "ms" "us" "Result" > "$spot_runtime_file"
        printf "%-45s %10s %10s %12s  %-15s\n" "----" "-------" "--" "--" "------" >> "$spot_runtime_file"

        hit_timeout=false

        for f in "${sgrk_files[@]}"; do
            name="$(basename "$f")"

            # Cascade skip on timeout
            if [[ "$hit_timeout" == true ]]; then
                printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "SKIPPED"
                printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "SKIPPED" >> "$spot_runtime_file"
                continue
            fi

            # Convert to LTL format (same as Strix)
            strix_file="${f}.strix"
            if [[ ! -s "$strix_file" ]]; then
                python3 "$TOSTRIX" "$f" > "$strix_file" 2>/dev/null
            fi

            if [[ ! -s "$strix_file" ]]; then
                printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "CONVERT_ERROR"
                printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "CONVERT_ERROR" >> "$spot_runtime_file"
                continue
            fi

            # Extract input and output variables
            ins=$(grep -o '"in:[^"]*"' "$f" | sort -u | sed 's/"//g' | paste -sd, -)
            outs=$(grep -o '"out:[^"]*"' "$f" | sort -u | sed 's/"//g' | paste -sd, -)

            # Read formula from file
            formula=$(cat "$strix_file")

            # Run ltlsynt with timing
            # ltlsynt exits 0 for REALIZABLE, 1 for UNREALIZABLE
            start_time=$(python3 -c "import time; print(time.time())")
            run_with_timeout "$TIMEOUT" "$SPOT" -f "$formula" --ins="$ins" --outs="$outs" --realizability
            result="$_timeout_output"
            exit_code=$_timeout_exit
            end_time=$(python3 -c "import time; print(time.time())")

            if [[ $exit_code -eq 142 ]]; then
                result="TIMEOUT"
                hit_timeout=true
                printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "TIMEOUT"
                printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "TIMEOUT" >> "$spot_runtime_file"
                continue
            fi

            elapsed_us=$(python3 -c "print(int((${end_time} - ${start_time}) * 1000000))")
            elapsed_ms=$(python3 -c "print(int((${end_time} - ${start_time}) * 1000))")
            elapsed_s=$(python3 -c "print(f'{${end_time} - ${start_time}:.3f}')")

            printf "%-45s %9ss %8sms %10sus  %-15s\n" "$name" "$elapsed_s" "$elapsed_ms" "$elapsed_us" "$result"
            printf "%-45s %9ss %8sms %10sus  %-15s\n" "$name" "$elapsed_s" "$elapsed_ms" "$elapsed_us" "$result" >> "$spot_runtime_file"
        done

        echo ""
    done
done

echo "Done. Runtime files written to each family directory as spot_runtime."
