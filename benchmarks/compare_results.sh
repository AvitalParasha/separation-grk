#!/bin/bash
# Cross-tool comparison: runs sgrk, Strix, and Spot (ltlsynt) on all benchmarks,
# compares realizability results, and presents a side-by-side table.
# Works across all formula types (R2R, R2P, P2R).
#
# By default, uses cached results from existing runtime/strix_runtime/spot_runtime files.
# Only tests missing from the cache are actually executed.
# Use --force to ignore the cache and re-run everything.
#
# Usage: bash compare_results.sh [--strix=<path>] [--spot=<path>] [--timeout=SECONDS] [--force] [R2R|R2P|P2R|Mixed|all]

MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
SGRK="${MYDIR}/../bin/sgrk"
TOSTRIX="${MYDIR}/to_strix.py"

# Defaults
STRIX="/tmp/strix-extract/strix"
SPOT="ltlsynt"
TIMEOUT=5400
STRIX_TIMEOUT=5400
SPOT_TIMEOUT=5400
CATEGORY="all"
USE_CACHE=true

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --strix=*)         STRIX="${arg#*=}" ;;
        --spot=*)          SPOT="${arg#*=}" ;;
        --timeout=*)       TIMEOUT="${arg#*=}" ;;
        --strix-timeout=*) STRIX_TIMEOUT="${arg#*=}" ;;
        --spot-timeout=*)  SPOT_TIMEOUT="${arg#*=}" ;;
        --force)           USE_CACHE=false ;;
        R2R|R2P|P2R|Mixed|all)   CATEGORY="$arg" ;;
        --help)
            echo "Usage: $(basename "$0") [OPTIONS] [R2R|R2P|P2R|Mixed|all]"
            echo ""
            echo "  --strix=<path>      Path to Strix binary"
            echo "  --spot=<path>       Path to ltlsynt binary (default: ltlsynt)"
            echo "  --timeout=SECONDS   sgrk timeout (default: 5400)"
            echo "  --strix-timeout=S   Strix timeout (default: 5400)"
            echo "  --spot-timeout=S    Spot timeout (default: 5400)"
            echo "  --force             Ignore cached results"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

if [[ ! -x "$SGRK" ]]; then
    echo "Error: sgrk binary not found at $SGRK. Run 'make' first."
    exit 1
fi

HAS_STRIX=false
if [[ -x "$STRIX" ]]; then
    HAS_STRIX=true
    echo "Strix: $STRIX"
else
    echo "Warning: Strix not found at $STRIX — skipping Strix"
fi

HAS_SPOT=false
if command -v "$SPOT" &>/dev/null; then
    HAS_SPOT=true
    echo "Spot:  $($SPOT --version 2>&1 | head -1)"
else
    echo "Warning: ltlsynt not found at $SPOT — skipping Spot"
fi

if [[ "$HAS_STRIX" == false && "$HAS_SPOT" == false ]]; then
    echo "Error: neither Strix nor Spot found. Need at least one comparison tool."
    exit 1
fi

# Portable timeout (works on macOS without coreutils)
source "${MYDIR}/timeout_helper.sh"

normalize_result() {
    local r="$1"
    case "$(echo "$r" | tr '[:upper:]' '[:lower:]')" in
        realizable)   echo "REALIZABLE" ;;
        unrealizable) echo "UNREALIZABLE" ;;
        timeout)      echo "TIMEOUT" ;;
        skipped)      echo "SKIPPED" ;;
        n/a)          echo "N/A" ;;
        convert_error) echo "N/A" ;;
        *)            echo "N/A" ;;  # Tool errors (e.g. Spot acceptance set limit) → N/A
    esac
}

get_cached_line() {
    local file="$1" test_name="$2"
    [[ ! -f "$file" ]] && return 1
    awk -v name="$test_name" '$1 == name { print; exit }' "$file"
}

parse_result() { echo "$1" | awk '{print $NF}'; }
parse_time() { echo "$1" | awk '{print $2}'; }

# Run a tool on a single test, with caching and timeout.
# Sets: tool_result, tool_time
# Args: tool_binary tool_args... cache_file runtime_file timeout hit_timeout_var name
run_external_tool() {
    local cache_file="$1" runtime_file="$2" tool_timeout="$3"
    local hit_timeout_var="$4" name="$5"
    shift 5
    local tool_cmd=("$@")

    local cached_line=""
    if [[ -n "$cache_file" && -f "$cache_file" ]]; then
        cached_line=$(get_cached_line "$cache_file" "$name")
    fi

    if [[ -n "$cached_line" ]]; then
        tool_result=$(parse_result "$cached_line")
        tool_time=$(parse_time "$cached_line")
        echo "$cached_line" >> "$runtime_file"
        if [[ "$tool_result" == "TIMEOUT" ]]; then
            eval "$hit_timeout_var=true"
        fi
        return
    fi

    if [[ "${!hit_timeout_var}" == true ]]; then
        tool_result="SKIPPED"
        tool_time="-"
        printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "SKIPPED" >> "$runtime_file"
        return
    fi

    # Convert to LTL format if needed
    local strix_file="${CURRENT_SGRK_FILE}.strix"
    if [[ ! -s "$strix_file" ]]; then
        python3 "$TOSTRIX" "$CURRENT_SGRK_FILE" > "$strix_file" 2>/dev/null
    fi

    if [[ ! -s "$strix_file" ]]; then
        tool_result="CONVERT_ERROR"
        tool_time="-"
        printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "CONVERT_ERROR" >> "$runtime_file"
        return
    fi

    local start_time end_time
    start_time=$(python3 -c "import time; print(time.time())")
    run_with_timeout "$tool_timeout" "${tool_cmd[@]}"
    tool_result="$_timeout_output"
    local exit_code=$_timeout_exit
    end_time=$(python3 -c "import time; print(time.time())")

    if [[ $exit_code -eq 142 ]]; then
        tool_result="TIMEOUT"
        tool_time="-"
        eval "$hit_timeout_var=true"
        printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "TIMEOUT" >> "$runtime_file"
    else
        tool_time="$(python3 -c "print(f'{${end_time} - ${start_time}:.3f}s')")"
        local tool_us=$(python3 -c "print(int((${end_time} - ${start_time}) * 1000000))")
        local tool_ms=$(python3 -c "print(int((${end_time} - ${start_time}) * 1000))")
        local tool_s=$(python3 -c "print(f'{${end_time} - ${start_time}:.3f}')")
        printf "%-45s %9ss %8sms %10sus  %-15s\n" "$name" "$tool_s" "$tool_ms" "$tool_us" "$tool_result" >> "$runtime_file"
    fi
}

latex_escape() { echo "$1" | sed 's/_/\\_/g'; }
latex_time() { local t="$1"; [[ "$t" == "-" ]] && echo "---" || echo "${t%s}"; }

latex_speedup() {
    local sgrk_t="$1" other_t="$2" other_r="$3" other_timeout="$4"
    if [[ "$other_r" == "TIMEOUT" ]]; then
        local sgrk_num="${sgrk_t%s}"
        if [[ "$sgrk_num" != "-" ]]; then
            local bound=$(python3 -c "print(f'{${other_timeout} / ${sgrk_num}:,.0f}')" 2>/dev/null)
            echo ">\$${bound}\\times\$"
        else echo "---"; fi
    elif [[ "$other_r" == "SKIPPED" || "$other_r" == "CONVERT_ERROR" || "$sgrk_t" == "-" || "$other_t" == "-" ]]; then
        echo "---"
    else
        local sgrk_num="${sgrk_t%s}" other_num="${other_t%s}"
        local speedup=$(python3 -c "s=${other_num}/${sgrk_num}; print(f'{s:,.0f}' if s>=100 else f'{s:.1f}')" 2>/dev/null)
        echo "\$${speedup}\\times\$"
    fi
}

if [[ "$CATEGORY" == "all" ]]; then
    CATEGORIES=(R2R R2P P2R Mixed)
else
    CATEGORIES=("$CATEGORY")
fi

TOTAL_MATCH=0
TOTAL_MISMATCH=0
TOTAL_SKIP=0
HAS_MISMATCH=false

if [[ "$USE_CACHE" == true ]]; then
    echo "(Using cached results where available. Use --force to re-run all.)"
fi
echo ""

for cat in "${CATEGORIES[@]}"; do
    cat_dir="${MYDIR}/${cat}"
    [[ ! -d "$cat_dir" ]] && continue

    results_dir="${MYDIR}/results/${cat}"
    mkdir -p "$results_dir"

    echo "========================================"
    echo "  ${cat} Comparison (sgrk vs Strix vs Spot)"
    echo "========================================"
    echo ""

    for family_dir in "${cat_dir}"/*/; do
        [[ ! -d "$family_dir" ]] && continue
        family="$(basename "$family_dir")"

        sgrk_files=()
        while IFS= read -r line; do
            sgrk_files+=("$line")
        done < <(find "$family_dir" -maxdepth 1 -name "*.sgrk" | sort -V)

        [[ ${#sgrk_files[@]} -eq 0 ]] && continue

        echo "=== ${cat} / ${family} ==="
        printf "%-30s %10s  %10s  %10s  %-10s\n" "Test" "sgrk" "Strix" "Spot" "Status"
        printf "%-30s %10s  %10s  %10s  %-10s\n" "----" "----" "-----" "----" "------"

        family_match=0; family_mismatch=0; family_skip=0
        strix_hit_timeout=false; spot_hit_timeout=false

        # Cache setup
        sgrk_runtime_file="${family_dir}/runtime"
        strix_runtime_file="${family_dir}/strix_runtime"
        spot_runtime_file="${family_dir}/spot_runtime"

        sgrk_cache=""; strix_cache=""; spot_cache=""
        if [[ "$USE_CACHE" == true ]]; then
            [[ -f "$sgrk_runtime_file" ]] && sgrk_cache=$(mktemp) && cp "$sgrk_runtime_file" "$sgrk_cache"
            [[ -f "$strix_runtime_file" ]] && strix_cache=$(mktemp) && cp "$strix_runtime_file" "$strix_cache"
            [[ -f "$spot_runtime_file" ]] && spot_cache=$(mktemp) && cp "$spot_runtime_file" "$spot_cache"
        fi

        # Write fresh headers
        for rf in "$sgrk_runtime_file" "$strix_runtime_file" "$spot_runtime_file"; do
            printf "%-45s %10s %10s %12s  %-15s\n" "Test" "Seconds" "ms" "us" "Result" > "$rf"
            printf "%-45s %10s %10s %12s  %-15s\n" "----" "-------" "--" "--" "------" >> "$rf"
        done

        for f in "${sgrk_files[@]}"; do
            name="$(basename "$f")"
            CURRENT_SGRK_FILE="$f"

            # --- sgrk ---
            cached_sgrk_line=""
            [[ -n "$sgrk_cache" ]] && cached_sgrk_line=$(get_cached_line "$sgrk_cache" "$name")

            if [[ -n "$cached_sgrk_line" ]]; then
                sgrk_result=$(parse_result "$cached_sgrk_line")
                sgrk_time=$(parse_time "$cached_sgrk_line")
                echo "$cached_sgrk_line" >> "$sgrk_runtime_file"
            else
                start_time=$(python3 -c "import time; print(time.time())")
                run_with_timeout "$TIMEOUT" "$SGRK" "$f"
                sgrk_result="$_timeout_output"; sgrk_exit=$_timeout_exit
                end_time=$(python3 -c "import time; print(time.time())")

                if [[ $sgrk_exit -eq 142 ]]; then
                    sgrk_result="TIMEOUT"; sgrk_time="-"
                    printf "%-45s %10s %10s %12s  %-15s\n" "$name" "-" "-" "-" "TIMEOUT" >> "$sgrk_runtime_file"
                else
                    sgrk_time="$(python3 -c "print(f'{${end_time} - ${start_time}:.3f}s')")"
                    local_s=$(python3 -c "print(f'{${end_time} - ${start_time}:.3f}')")
                    local_ms=$(python3 -c "print(int((${end_time} - ${start_time}) * 1000))")
                    local_us=$(python3 -c "print(int((${end_time} - ${start_time}) * 1000000))")
                    printf "%-45s %9ss %8sms %10sus  %-15s\n" "$name" "$local_s" "$local_ms" "$local_us" "$sgrk_result" >> "$sgrk_runtime_file"
                fi
            fi

            # --- Strix ---
            strix_result="N/A"; strix_time="-"
            if [[ "$HAS_STRIX" == true ]]; then
                ins=$(grep -o '"in:[^"]*"' "$f" | sort -u | sed 's/"//g' | paste -sd, -)
                outs=$(grep -o '"out:[^"]*"' "$f" | sort -u | sed 's/"//g' | paste -sd, -)
                strix_file="${f}.strix"
                [[ ! -s "$strix_file" ]] && python3 "$TOSTRIX" "$f" > "$strix_file" 2>/dev/null
                run_external_tool "$strix_cache" "$strix_runtime_file" "$STRIX_TIMEOUT" \
                    "strix_hit_timeout" "$name" \
                    "$STRIX" -r -F "$strix_file" --ins "$ins" --outs "$outs"
                strix_result="$tool_result"; strix_time="$tool_time"
            fi

            # --- Spot ---
            spot_result="N/A"; spot_time="-"
            if [[ "$HAS_SPOT" == true ]]; then
                ins=$(grep -o '"in:[^"]*"' "$f" | sort -u | sed 's/"//g' | paste -sd, -)
                outs=$(grep -o '"out:[^"]*"' "$f" | sort -u | sed 's/"//g' | paste -sd, -)
                strix_file="${f}.strix"
                [[ ! -s "$strix_file" ]] && python3 "$TOSTRIX" "$f" > "$strix_file" 2>/dev/null
                formula=$(cat "$strix_file" 2>/dev/null)
                run_external_tool "$spot_cache" "$spot_runtime_file" "$SPOT_TIMEOUT" \
                    "spot_hit_timeout" "$name" \
                    "$SPOT" -f "$formula" --ins="$ins" --outs="$outs" --realizability
                spot_result="$tool_result"; spot_time="$tool_time"
            fi

            # --- Compare ---
            sgrk_norm=$(normalize_result "$sgrk_result")
            strix_norm=$(normalize_result "$strix_result")
            spot_norm=$(normalize_result "$spot_result")

            status="MATCH"
            if [[ "$sgrk_result" == "TIMEOUT" ]]; then
                status="SKIP"
            elif [[ "$HAS_STRIX" == true && "$strix_norm" != "N/A" && "$strix_norm" != "TIMEOUT" && "$strix_norm" != "SKIPPED" && "$sgrk_norm" != "$strix_norm" ]]; then
                status="**MISMATCH(Strix)**"
                HAS_MISMATCH=true
            elif [[ "$HAS_SPOT" == true && "$spot_norm" != "N/A" && "$spot_norm" != "TIMEOUT" && "$spot_norm" != "SKIPPED" && "$sgrk_norm" != "$spot_norm" ]]; then
                status="**MISMATCH(Spot)**"
                HAS_MISMATCH=true
            elif [[ "$strix_norm" == "N/A" || "$spot_norm" == "N/A" ]]; then
                status="N/A"
            elif [[ "$strix_result" == "TIMEOUT" || "$strix_result" == "SKIPPED" || "$spot_result" == "TIMEOUT" || "$spot_result" == "SKIPPED" ]]; then
                status="SKIP"
            fi

            case "$status" in
                *MATCH*) family_match=$((family_match + 1)) ;;
                *MISMATCH*) family_mismatch=$((family_mismatch + 1)) ;;
                N/A) family_skip=$((family_skip + 1)) ;;
                SKIP) family_skip=$((family_skip + 1)) ;;
            esac

            printf "%-30s %10s  %10s  %10s  %-10s\n" \
                "$name" "$sgrk_time" "$strix_time" "$spot_time" "$status"
        done

        [[ -n "$sgrk_cache" ]] && rm -f "$sgrk_cache"
        [[ -n "$strix_cache" ]] && rm -f "$strix_cache"
        [[ -n "$spot_cache" ]] && rm -f "$spot_cache"

        echo ""
        echo "  Summary: ${family_match} MATCH, ${family_mismatch} MISMATCH, ${family_skip} SKIP"
        echo ""

        TOTAL_MATCH=$((TOTAL_MATCH + family_match))
        TOTAL_MISMATCH=$((TOTAL_MISMATCH + family_mismatch))
        TOTAL_SKIP=$((TOTAL_SKIP + family_skip))
    done
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
    echo "ERROR: Mismatches detected!"
    exit 1
fi
