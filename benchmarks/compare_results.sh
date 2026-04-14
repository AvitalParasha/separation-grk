#!/bin/bash
# Cross-tool comparison: runs both sgrk and Strix on all benchmarks,
# compares realizability results, and presents a side-by-side table.
# Works across all formula types (R2R, R2P, P2R).
#
# By default, uses cached results from existing runtime/strix_runtime files.
# Only tests missing from the cache are actually executed.
# Use --force to ignore the cache and re-run everything.
#
# Usage: bash compare_results.sh [--strix=<path>] [--timeout=SECONDS] [--force] [R2R|R2P|P2R|all]

MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
SGRK="${MYDIR}/../bin/sgrk"
TOSTRIX="${MYDIR}/to_strix.py"

# Defaults
STRIX="/tmp/strix-extract/strix"
TIMEOUT=5400
STRIX_TIMEOUT=5400
CATEGORY="all"
USE_CACHE=true

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --strix=*)         STRIX="${arg#*=}" ;;
        --timeout=*)       TIMEOUT="${arg#*=}" ;;
        --strix-timeout=*) STRIX_TIMEOUT="${arg#*=}" ;;
        --force)           USE_CACHE=false ;;
        R2R|R2P|P2R|all)   CATEGORY="$arg" ;;
        --help)
            echo "Usage: $(basename "$0") [--strix=<path>] [--timeout=SECONDS] [--strix-timeout=SECONDS] [--force] [R2R|R2P|P2R|all]"
            echo ""
            echo "  --timeout        sgrk timeout per benchmark (default: 120)"
            echo "  --strix-timeout  Strix timeout per benchmark (default: 1800)"
            echo "  --force          Ignore cached results and re-run all tests"
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

if [[ ! -x "$STRIX" ]]; then
    echo "Error: Strix binary not found at $STRIX"
    echo "Usage: $(basename "$0") --strix=<path-to-strix-binary>"
    exit 1
fi

# Portable timeout (works on macOS without coreutils)
source "${MYDIR}/timeout_helper.sh"

# Normalize result strings for comparison (case-insensitive)
normalize_result() {
    local r="$1"
    case "$(echo "$r" | tr '[:upper:]' '[:lower:]')" in
        realizable)   echo "REALIZABLE" ;;
        unrealizable) echo "UNREALIZABLE" ;;
        *)            echo "$r" ;;
    esac
}

# Look up a cached result line from a runtime file.
# Usage: get_cached_line <file> <test_name>
# Prints the full line if found, returns 1 if not.
get_cached_line() {
    local file="$1" test_name="$2"
    [[ ! -f "$file" ]] && return 1
    awk -v name="$test_name" '$1 == name { print; exit }' "$file"
}

# Parse the result field (last column) from a runtime line.
parse_result() { echo "$1" | awk '{print $NF}'; }

# Parse the seconds field (second column, e.g. "0.013s") from a runtime line.
parse_time() { echo "$1" | awk '{print $2}'; }

# Determine which categories to run
if [[ "$CATEGORY" == "all" ]]; then
    CATEGORIES=(R2R R2P P2R)
else
    CATEGORIES=("$CATEGORY")
fi

TOTAL_MATCH=0
TOTAL_MISMATCH=0
TOTAL_SKIP=0
HAS_MISMATCH=false

if [[ "$USE_CACHE" == true ]]; then
    echo "(Using cached results where available. Use --force to re-run all.)"
    echo ""
fi

# Escape underscores for LaTeX
latex_escape() { echo "$1" | sed 's/_/\\_/g'; }

# Format a time value for LaTeX (strip trailing 's', add \,s)
latex_time() {
    local t="$1"
    if [[ "$t" == "-" ]]; then
        echo "---"
    else
        echo "${t%s}"
    fi
}

# Compute speedup string for LaTeX
latex_speedup() {
    local sgrk_t="$1" strix_t="$2" strix_r="$3"
    if [[ "$strix_r" == "TIMEOUT" ]]; then
        # Compute lower bound: timeout / sgrk_time
        local sgrk_num="${sgrk_t%s}"
        if [[ "$sgrk_num" != "-" ]]; then
            local bound
            bound=$(python3 -c "print(f'{${STRIX_TIMEOUT} / ${sgrk_num}:,.0f}')" 2>/dev/null)
            echo ">\$${bound}\\times\$"
        else
            echo "---"
        fi
    elif [[ "$strix_r" == "SKIPPED" || "$strix_r" == "CONVERT_ERROR" || "$sgrk_t" == "-" || "$strix_t" == "-" ]]; then
        echo "---"
    else
        local sgrk_num="${sgrk_t%s}"
        local strix_num="${strix_t%s}"
        local speedup
        speedup=$(python3 -c "
s = ${strix_num} / ${sgrk_num}
if s >= 100:
    print(f'{s:,.0f}')
elif s >= 10:
    print(f'{s:.1f}')
else:
    print(f'{s:.1f}')
" 2>/dev/null)
        echo "\$${speedup}\\times\$"
    fi
}

for cat in "${CATEGORIES[@]}"; do
    cat_dir="${MYDIR}/${cat}"
    if [[ ! -d "$cat_dir" ]]; then
        continue
    fi

    # Create results directory for LaTeX output
    results_dir="${MYDIR}/results/${cat}"
    mkdir -p "$results_dir"

    # Accumulate summary data for the category
    summary_families=()
    summary_tests=()
    summary_matches=()
    summary_timeouts=()
    summary_sgrk_min=()
    summary_sgrk_max=()
    summary_strix_min=()
    summary_strix_max=()

    echo "========================================"
    echo "  ${cat} Comparison (sgrk vs Strix)"
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
        printf "%-35s %-15s %10s  %-15s %10s  %-12s\n" \
            "Test" "sgrk Result" "sgrk Time" "Strix Result" "Strix Time" "Status"
        printf "%-35s %-15s %10s  %-15s %10s  %-12s\n" \
            "----" "-----------" "---------" "------------" "----------" "------"

        family_match=0
        family_mismatch=0
        family_skip=0
        strix_hit_timeout=false

        # Arrays to collect per-test data for LaTeX generation
        tex_names=()
        tex_sgrk_times=()
        tex_strix_times=()
        tex_sgrk_results=()
        tex_strix_results=()

        # Save existing runtime files as cache before overwriting
        sgrk_runtime_file="${family_dir}/runtime"
        strix_runtime_file="${family_dir}/strix_runtime"
        sgrk_cache=""
        strix_cache=""
        if [[ "$USE_CACHE" == true ]]; then
            if [[ -f "$sgrk_runtime_file" ]]; then
                sgrk_cache=$(mktemp)
                cp "$sgrk_runtime_file" "$sgrk_cache"
            fi
            if [[ -f "$strix_runtime_file" ]]; then
                strix_cache=$(mktemp)
                cp "$strix_runtime_file" "$strix_cache"
            fi
        fi

        # Write fresh headers
        printf "%-45s %10s %10s %12s  %-15s\n" "Test" "Seconds" "ms" "us" "Result" > "$sgrk_runtime_file"
        printf "%-45s %10s %10s %12s  %-15s\n" "----" "-------" "--" "--" "------" >> "$sgrk_runtime_file"
        printf "%-45s %10s %10s %12s  %-15s\n" "Test" "Seconds" "ms" "us" "Result" > "$strix_runtime_file"
        printf "%-45s %10s %10s %12s  %-15s\n" "----" "-------" "--" "--" "------" >> "$strix_runtime_file"

        for f in "${sgrk_files[@]}"; do
            name="$(basename "$f")"

            # --- sgrk: check cache first ---
            cached_sgrk_line=""
            if [[ -n "$sgrk_cache" ]]; then
                cached_sgrk_line=$(get_cached_line "$sgrk_cache" "$name")
            fi

            if [[ -n "$cached_sgrk_line" ]]; then
                sgrk_result=$(parse_result "$cached_sgrk_line")
                sgrk_time=$(parse_time "$cached_sgrk_line")
                echo "$cached_sgrk_line" >> "$sgrk_runtime_file"
            else
                # Run sgrk
                start_time=$(python3 -c "import time; print(time.time())")
                if [[ "$TIMEOUT" -gt 0 ]]; then
                    run_with_timeout "$TIMEOUT" "$SGRK" "$f"
                    sgrk_result="$_timeout_output"
                    sgrk_exit=$_timeout_exit
                else
                    sgrk_result=$("$SGRK" "$f" 2>&1)
                    sgrk_exit=$?
                fi
                end_time=$(python3 -c "import time; print(time.time())")

                if [[ $sgrk_exit -eq 142 ]]; then
                    sgrk_result="TIMEOUT"
                    sgrk_time="-"
                    printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "TIMEOUT" >> "$sgrk_runtime_file"
                else
                    sgrk_time="$(python3 -c "print(f'{${end_time} - ${start_time}:.3f}s')")"
                    sgrk_us=$(python3 -c "print(int((${end_time} - ${start_time}) * 1000000))")
                    sgrk_ms=$(python3 -c "print(int((${end_time} - ${start_time}) * 1000))")
                    sgrk_s=$(python3 -c "print(f'{${end_time} - ${start_time}:.3f}')")
                    printf "%-45s %9ss %8sms %10sus  %-15s\n" "$name" "$sgrk_s" "$sgrk_ms" "$sgrk_us" "$sgrk_result" >> "$sgrk_runtime_file"
                fi
            fi

            # --- Strix: check cache first ---
            cached_strix_line=""
            if [[ -n "$strix_cache" ]]; then
                cached_strix_line=$(get_cached_line "$strix_cache" "$name")
            fi

            if [[ -n "$cached_strix_line" ]]; then
                strix_result=$(parse_result "$cached_strix_line")
                strix_time=$(parse_time "$cached_strix_line")
                echo "$cached_strix_line" >> "$strix_runtime_file"
                # Maintain cascading timeout state from cache
                if [[ "$strix_result" == "TIMEOUT" ]]; then
                    strix_hit_timeout=true
                fi
            elif [[ "$strix_hit_timeout" == true ]]; then
                strix_result="SKIPPED"
                strix_time="-"
                printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "SKIPPED" >> "$strix_runtime_file"
            else
                # Convert to Strix format
                strix_file="${f}.strix"
                python3 "$TOSTRIX" "$f" > "$strix_file" 2>/dev/null

                if [[ ! -s "$strix_file" ]]; then
                    strix_result="CONVERT_ERROR"
                    strix_time="-"
                    printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "CONVERT_ERROR" >> "$strix_runtime_file"
                else
                    ins=$(grep -o '"in:[^"]*"' "$f" | sort -u | sed 's/"//g' | paste -sd, -)
                    outs=$(grep -o '"out:[^"]*"' "$f" | sort -u | sed 's/"//g' | paste -sd, -)

                    start_time=$(python3 -c "import time; print(time.time())")
                    run_with_timeout "$STRIX_TIMEOUT" "$STRIX" -r -F "$strix_file" --ins "$ins" --outs "$outs"
                    strix_result="$_timeout_output"
                    strix_exit=$_timeout_exit
                    end_time=$(python3 -c "import time; print(time.time())")

                    if [[ $strix_exit -eq 142 ]]; then
                        strix_result="TIMEOUT"
                        strix_time="-"
                        strix_hit_timeout=true
                        printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "TIMEOUT" >> "$strix_runtime_file"
                    else
                        strix_time="$(python3 -c "print(f'{${end_time} - ${start_time}:.3f}s')")"
                        strix_us=$(python3 -c "print(int((${end_time} - ${start_time}) * 1000000))")
                        strix_ms=$(python3 -c "print(int((${end_time} - ${start_time}) * 1000))")
                        strix_s=$(python3 -c "print(f'{${end_time} - ${start_time}:.3f}')")
                        printf "%-45s %9ss %8sms %10sus  %-15s\n" "$name" "$strix_s" "$strix_ms" "$strix_us" "$strix_result" >> "$strix_runtime_file"
                    fi
                fi
            fi

            # --- Collect data for LaTeX ---
            tex_names+=("$name")
            tex_sgrk_times+=("$sgrk_time")
            tex_strix_times+=("$strix_time")
            tex_sgrk_results+=("$sgrk_result")
            tex_strix_results+=("$strix_result")

            # --- Compare ---
            sgrk_norm=$(normalize_result "$sgrk_result")
            strix_norm=$(normalize_result "$strix_result")

            if [[ "$sgrk_result" == "TIMEOUT" || "$strix_result" == "TIMEOUT" || "$strix_result" == "SKIPPED" ]]; then
                status="SKIP"
                family_skip=$((family_skip + 1))
            elif [[ "$sgrk_norm" == "$strix_norm" ]]; then
                status="MATCH"
                family_match=$((family_match + 1))
            else
                status="**MISMATCH**"
                family_mismatch=$((family_mismatch + 1))
                HAS_MISMATCH=true
            fi

            printf "%-35s %-15s %10s  %-15s %10s  %-12s\n" \
                "$name" "$sgrk_result" "$sgrk_time" "$strix_result" "$strix_time" "$status"
        done

        # Clean up temp cache files
        [[ -n "$sgrk_cache" ]] && rm -f "$sgrk_cache"
        [[ -n "$strix_cache" ]] && rm -f "$strix_cache"

        echo ""
        echo "  Summary: ${family_match} MATCH, ${family_mismatch} MISMATCH, ${family_skip} SKIP"
        echo ""

        # --- Generate per-family LaTeX table ---
        family_tex="${results_dir}/${family}.tex"
        family_label="tab:${cat}_${family}"
        family_pretty=$(echo "$family" | sed 's/_/ /g')

        {
            echo "\\begin{table}[htbp]"
            echo "\\centering"
            echo "\\caption{${cat}: $(latex_escape "$family_pretty") -- sgrk vs.\\ Strix runtime comparison.}"
            echo "\\label{${family_label}}"
            echo "\\begin{tabular}{r r r r l}"
            echo "\\toprule"
            echo "\\# & sgrk (s) & Strix (s) & Speedup & Result \\\\"
            echo "\\midrule"

            for i in "${!tex_names[@]}"; do
                # Extract instance number from name (e.g., cleaning_robots_3.sgrk -> 3)
                instance=$(echo "${tex_names[$i]}" | sed 's/.*_\([0-9]*\)\.sgrk/\1/')
                # If no number found (single instance), use 1
                if [[ "$instance" == "${tex_names[$i]}" ]]; then
                    instance="1"
                fi

                st=$(latex_time "${tex_sgrk_times[$i]}")
                xt=$(latex_time "${tex_strix_times[$i]}")
                speedup=$(latex_speedup "${tex_sgrk_times[$i]}" "${tex_strix_times[$i]}" "${tex_strix_results[$i]}")

                # Normalize result for display
                res_norm=$(normalize_result "${tex_sgrk_results[$i]}")
                if [[ "$res_norm" == "REALIZABLE" ]]; then
                    res_display="Realizable"
                elif [[ "$res_norm" == "UNREALIZABLE" ]]; then
                    res_display="Unrealizable"
                else
                    res_display="${tex_sgrk_results[$i]}"
                fi

                # Mark Strix timeout/skipped
                if [[ "${tex_strix_results[$i]}" == "TIMEOUT" ]]; then
                    xt="T/O"
                elif [[ "${tex_strix_results[$i]}" == "SKIPPED" ]]; then
                    xt="---"
                fi

                echo "${instance} & ${st} & ${xt} & ${speedup} & ${res_display} \\\\"
            done

            echo "\\bottomrule"
            echo "\\end{tabular}"
            echo "\\end{table}"
        } > "$family_tex"

        echo "  LaTeX: ${family_tex}"

        # Accumulate summary data
        summary_families+=("$family")
        summary_tests+=("${#tex_names[@]}")
        summary_matches+=("$family_match")
        family_timeouts=$((family_skip))
        summary_timeouts+=("$family_timeouts")

        # Compute sgrk min/max
        sgrk_min="" ; sgrk_max=""
        for t in "${tex_sgrk_times[@]}"; do
            [[ "$t" == "-" ]] && continue
            val="${t%s}"
            if [[ -z "$sgrk_min" ]]; then
                sgrk_min="$val"; sgrk_max="$val"
            else
                sgrk_min=$(python3 -c "print(min($sgrk_min, $val))")
                sgrk_max=$(python3 -c "print(max($sgrk_max, $val))")
            fi
        done
        summary_sgrk_min+=("${sgrk_min:-N/A}")
        summary_sgrk_max+=("${sgrk_max:-N/A}")

        # Compute strix min/max (only completed tests)
        strix_min="" ; strix_max=""
        for i in "${!tex_strix_times[@]}"; do
            [[ "${tex_strix_times[$i]}" == "-" ]] && continue
            [[ "${tex_strix_results[$i]}" == "TIMEOUT" || "${tex_strix_results[$i]}" == "SKIPPED" ]] && continue
            val="${tex_strix_times[$i]%s}"
            if [[ -z "$strix_min" ]]; then
                strix_min="$val"; strix_max="$val"
            else
                strix_min=$(python3 -c "print(min($strix_min, $val))")
                strix_max=$(python3 -c "print(max($strix_max, $val))")
            fi
        done
        summary_strix_min+=("${strix_min:-N/A}")
        summary_strix_max+=("${strix_max:-N/A}")

        TOTAL_MATCH=$((TOTAL_MATCH + family_match))
        TOTAL_MISMATCH=$((TOTAL_MISMATCH + family_mismatch))
        TOTAL_SKIP=$((TOTAL_SKIP + family_skip))
    done

    # --- Generate category summary LaTeX table ---
    summary_tex="${results_dir}/summary.tex"
    {
        echo "\\begin{table}[htbp]"
        echo "\\centering"
        echo "\\caption{${cat} benchmark summary: sgrk vs.\\ Strix.}"
        echo "\\label{tab:${cat}_summary}"
        echo "\\begin{tabular}{l r r r r r}"
        echo "\\toprule"
        echo "Family & Tests & Match & Strix T/O & sgrk Range (s) & Strix Range (s) \\\\"
        echo "\\midrule"

        for i in "${!summary_families[@]}"; do
            fname=$(latex_escape "$(echo "${summary_families[$i]}" | sed 's/_/ /g')")
            tests="${summary_tests[$i]}"
            matches="${summary_matches[$i]}"
            timeouts="${summary_timeouts[$i]}"

            if [[ "${summary_sgrk_min[$i]}" == "${summary_sgrk_max[$i]}" ]]; then
                sgrk_range="${summary_sgrk_min[$i]}"
            else
                sgrk_range="${summary_sgrk_min[$i]}--${summary_sgrk_max[$i]}"
            fi

            if [[ "${summary_strix_min[$i]}" == "N/A" ]]; then
                strix_range="N/A"
            elif [[ "${summary_strix_min[$i]}" == "${summary_strix_max[$i]}" ]]; then
                strix_range="${summary_strix_min[$i]}"
            else
                strix_range="${summary_strix_min[$i]}--${summary_strix_max[$i]}"
            fi

            echo "${fname} & ${tests} & ${matches} & ${timeouts} & ${sgrk_range} & ${strix_range} \\\\"
        done

        echo "\\bottomrule"
        echo "\\end{tabular}"
        echo "\\end{table}"
    } > "$summary_tex"

    echo "  LaTeX summary: ${summary_tex}"
    echo ""
done

echo "========================================"
echo "Overall: ${TOTAL_MATCH} MATCH, ${TOTAL_MISMATCH} MISMATCH, ${TOTAL_SKIP} SKIP"
echo "========================================"

# Generate SVG images and HTML slideshow
echo ""
echo "Generating SVG tables and slideshow..."
python3 "${MYDIR}/generate_table_images.py" "$CATEGORY"

if [[ "$HAS_MISMATCH" == true ]]; then
    echo ""
    echo "ERROR: Mismatches detected between sgrk and Strix!"
    exit 1
fi
