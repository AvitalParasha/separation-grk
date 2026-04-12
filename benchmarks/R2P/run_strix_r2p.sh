#!/bin/bash
# Run all R2P examples through Strix and measure runtime.
# If test_i times out, skip test_i+1..10 for that example family.
# Usage: bash run_strix_r2p.sh [path-to-strix-binary]

MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
STRIX="${1:-/tmp/strix-extract/strix}"

if [[ ! -x "$STRIX" ]]; then
    echo "Error: Strix binary not found at $STRIX"
    echo "Usage: $0 <path-to-strix-binary>"
    exit 1
fi

TIMEOUT=1800

for example_dir in "${MYDIR}"/*/; do
    dir_name="$(basename "$example_dir")"
    strix_dir="${example_dir}strix_example"

    if [[ ! -d "$strix_dir" ]]; then
        continue
    fi

    echo "=== ${dir_name} ==="
    runtime_file="${strix_dir}/runtime.txt"
    echo "# Strix runtime results for ${dir_name}" > "$runtime_file"
    echo "# Format: filename | result | time" >> "$runtime_file"
    echo "# Timeout: ${TIMEOUT}s (30 minutes)" >> "$runtime_file"
    echo "" >> "$runtime_file"

    hit_timeout=false

    # Sort files numerically
    while IFS= read -r strix_file; do
        if [[ ! -f "$strix_file" ]]; then
            continue
        fi

        base="$(basename "$strix_file" .sgrk.strix)"

        # If a previous test timed out, skip the rest
        if [[ "$hit_timeout" == true ]]; then
            echo "  ${base}: SKIPPED (previous test timed out)"
            echo "${base}.sgrk.strix | SKIPPED | -" >> "$runtime_file"
            continue
        fi

        sgrk_file="${example_dir}${base}.sgrk"

        if [[ ! -f "$sgrk_file" ]]; then
            echo "  ${base}: SKIP (no .sgrk file)"
            echo "${base}.sgrk.strix | SKIP | -" >> "$runtime_file"
            continue
        fi

        # Extract input and output variables from the .sgrk file
        ins=$(grep -o '"in:[^"]*"' "$sgrk_file" | sort -u | sed 's/"//g' | paste -sd, -)
        outs=$(grep -o '"out:[^"]*"' "$sgrk_file" | sort -u | sed 's/"//g' | paste -sd, -)

        # Run Strix with timing
        start_time=$(python3 -c "import time; print(time.time())")
        result=$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$STRIX" -r -F "$strix_file" --ins "$ins" --outs "$outs" 2>&1)
        exit_code=$?
        end_time=$(python3 -c "import time; print(time.time())")

        elapsed=$(python3 -c "print(f'{${end_time} - ${start_time}:.3f}')")

        if [[ $exit_code -eq 142 ]]; then
            result="TIMEOUT"
            hit_timeout=true
        fi

        echo "  ${base}: ${result} (${elapsed}s)"
        echo "${base}.sgrk.strix | ${result} | ${elapsed}s" >> "$runtime_file"
    done < <(find "$strix_dir" -name "*.sgrk.strix" | sort -t_ -k99 -n 2>/dev/null || find "$strix_dir" -name "*.sgrk.strix" | sort -V)

    echo ""
done

echo "Done. Runtime files written to each strix_example/ directory."
