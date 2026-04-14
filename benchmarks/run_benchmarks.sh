#!/bin/bash
# Unified sgrk benchmark runner with timing tables.
# Runs bin/sgrk on all benchmarks in the specified category (R2R, R2P, P2R, or all).
# Outputs a per-family table with runtime in seconds, ms, and us.
#
# Usage: bash run_benchmarks.sh [--timeout=SECONDS] [R2R|R2P|P2R|all]

MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
SGRK="${MYDIR}/../bin/sgrk"

# Defaults
TIMEOUT=120
CATEGORY="all"

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --timeout=*) TIMEOUT="${arg#*=}" ;;
        R2R|R2P|P2R|all) CATEGORY="$arg" ;;
        --help)
            echo "Usage: $(basename "$0") [--timeout=SECONDS] [R2R|R2P|P2R|all]"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

if [[ ! -x "$SGRK" ]]; then
    echo "Error: sgrk binary not found at $SGRK"
    echo "Run 'make' first."
    exit 1
fi

# Portable timeout (works on macOS without coreutils)
source "${MYDIR}/timeout_helper.sh"

# Determine which categories to run
if [[ "$CATEGORY" == "all" ]]; then
    CATEGORIES=(R2R R2P P2R)
else
    CATEGORIES=("$CATEGORY")
fi

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

for cat in "${CATEGORIES[@]}"; do
    cat_dir="${MYDIR}/${cat}"
    if [[ ! -d "$cat_dir" ]]; then
        continue
    fi

    echo "========================================"
    echo "  ${cat} Benchmarks"
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

        runtime_file="${family_dir}/runtime"
        printf "%-45s %10s %10s %12s  %-15s\n" "Test" "Seconds" "ms" "us" "Result" > "$runtime_file"
        printf "%-45s %10s %10s %12s  %-15s\n" "----" "-------" "--" "--" "------" >> "$runtime_file"

        for f in "${sgrk_files[@]}"; do
            name="$(basename "$f")"

            if [[ "$TIMEOUT" -gt 0 ]]; then
                start_time=$(python3 -c "import time; print(time.time())")
                run_with_timeout "$TIMEOUT" "$SGRK" "$f"
                result="$_timeout_output"
                exit_code=$_timeout_exit
                end_time=$(python3 -c "import time; print(time.time())")

                if [[ $exit_code -eq 142 ]]; then
                    printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "TIMEOUT"
                    printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "TIMEOUT" >> "$runtime_file"
                    TOTAL_SKIP=$((TOTAL_SKIP + 1))
                    continue
                fi
            else
                start_time=$(python3 -c "import time; print(time.time())")
                result=$("$SGRK" "$f" 2>&1)
                end_time=$(python3 -c "import time; print(time.time())")
            fi

            elapsed_us=$(python3 -c "print(int((${end_time} - ${start_time}) * 1000000))")
            elapsed_ms=$(python3 -c "print(int((${end_time} - ${start_time}) * 1000))")
            elapsed_s=$(python3 -c "print(f'{${end_time} - ${start_time}:.3f}')")

            printf "%-45s %9ss %8sms %10sus  %-15s\n" "$name" "$elapsed_s" "$elapsed_ms" "$elapsed_us" "$result"
            printf "%-45s %9ss %8sms %10sus  %-15s\n" "$name" "$elapsed_s" "$elapsed_ms" "$elapsed_us" "$result" >> "$runtime_file"

            if [[ "$result" == "Realizable" || "$result" == "Unrealizable" ]]; then
                TOTAL_PASS=$((TOTAL_PASS + 1))
            else
                TOTAL_FAIL=$((TOTAL_FAIL + 1))
            fi
        done

        echo ""
    done
done

echo "========================================"
echo "Total: ${TOTAL_PASS} completed, ${TOTAL_FAIL} errors, ${TOTAL_SKIP} timeouts"
