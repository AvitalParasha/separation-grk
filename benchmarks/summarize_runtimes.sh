#!/bin/bash
# Summarize cached runtime results from existing runtime/strix_runtime files.
# Does NOT re-run any benchmarks — reads only from cached data.
#
# Produces three tables:
#   Table 1: sgrk runtimes (per test)
#   Table 2: Strix runtimes (per test)
#   Table 3: Per-family comparison summary (min/max/total, speedup)
#   Table 4: Per-instance side-by-side comparison (sgrk vs Strix, per family)
#
# Usage: bash summarize_runtimes.sh [R2R|R2P|P2R|all]

MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"

CATEGORY="all"

for arg in "$@"; do
    case "$arg" in
        R2R|R2P|P2R|all) CATEGORY="$arg" ;;
        --help)
            echo "Usage: $(basename "$0") [R2R|R2P|P2R|all]"
            echo "Reads cached runtime/strix_runtime files and prints summary tables."
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

if [[ "$CATEGORY" == "all" ]]; then
    CATEGORIES=(R2R R2P P2R)
else
    CATEGORIES=("$CATEGORY")
fi

# ──────────────────────────────────────────────────────────
#  Helper: parse data rows from a runtime file.
#  Skips header lines (starting with "Test" or "----").
#  Outputs: test_name seconds_with_s result
# ──────────────────────────────────────────────────────────
parse_runtime() {
    local file="$1"
    [[ ! -f "$file" ]] && return
    awk 'NR <= 2 { next }          # skip header
         $1 == "" { next }
         { print $1, $2, $NF }' "$file"
}

# ──────────────────────────────────────────────────────────
#  Table 1: sgrk Runtimes
# ──────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                          Table 1: sgrk Runtimes                            ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""

for cat in "${CATEGORIES[@]}"; do
    cat_dir="${MYDIR}/${cat}"
    [[ ! -d "$cat_dir" ]] && continue

    has_data=false
    for family_dir in "${cat_dir}"/*/; do
        [[ ! -f "${family_dir}/runtime" ]] && continue
        has_data=true
    done
    [[ "$has_data" == false ]] && continue

    echo "── ${cat} ──────────────────────────────────────────────────────────────"
    printf "  %-40s %12s  %-15s\n" "Test" "Time" "Result"
    printf "  %-40s %12s  %-15s\n" "────" "────" "──────"

    for family_dir in "${cat_dir}"/*/; do
        [[ ! -f "${family_dir}/runtime" ]] && continue
        family="$(basename "$family_dir")"

        while IFS=' ' read -r name time_s result; do
            printf "  %-40s %12s  %-15s\n" "$name" "$time_s" "$result"
        done < <(parse_runtime "${family_dir}/runtime")
    done
    echo ""
done

# ──────────────────────────────────────────────────────────
#  Table 2: Strix Runtimes
# ──────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                         Table 2: Strix Runtimes                            ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""

any_strix=false
for cat in "${CATEGORIES[@]}"; do
    cat_dir="${MYDIR}/${cat}"
    [[ ! -d "$cat_dir" ]] && continue

    has_data=false
    for family_dir in "${cat_dir}"/*/; do
        [[ -f "${family_dir}/strix_runtime" ]] && has_data=true
    done
    [[ "$has_data" == false ]] && continue

    any_strix=true
    echo "── ${cat} ──────────────────────────────────────────────────────────────"
    printf "  %-40s %12s  %-15s\n" "Test" "Time" "Result"
    printf "  %-40s %12s  %-15s\n" "────" "────" "──────"

    for family_dir in "${cat_dir}"/*/; do
        [[ ! -f "${family_dir}/strix_runtime" ]] && continue

        while IFS=' ' read -r name time_s result; do
            printf "  %-40s %12s  %-15s\n" "$name" "$time_s" "$result"
        done < <(parse_runtime "${family_dir}/strix_runtime")
    done
    echo ""
done

if [[ "$any_strix" == false ]]; then
    echo "  (No Strix runtime data found. Run: bash benchmarks/run_strix.sh)"
    echo ""
fi

# ──────────────────────────────────────────────────────────
#  Table 3: Per-Family Comparison Summary
# ──────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════════════════════════════════════════════════╗"
echo "║                              Table 3: Per-Family Comparison Summary                                       ║"
echo "╚══════════════════════════════════════════════════════════════════════════════════════════════════════════════╝"
echo ""
printf "  %-28s %-5s %6s  %10s %10s %10s  %10s %10s %10s  %8s\n" \
    "Family" "Type" "Tests" "sgrk Min" "sgrk Max" "sgrk Tot" "Strix Min" "Strix Max" "Strix Tot" "Speedup"
printf "  %-28s %-5s %6s  %10s %10s %10s  %10s %10s %10s  %8s\n" \
    "──────" "────" "─────" "────────" "────────" "────────" "─────────" "─────────" "─────────" "───────"

for cat in "${CATEGORIES[@]}"; do
    cat_dir="${MYDIR}/${cat}"
    [[ ! -d "$cat_dir" ]] && continue

    for family_dir in "${cat_dir}"/*/; do
        [[ ! -f "${family_dir}/runtime" ]] && continue
        family="$(basename "$family_dir")"

        # Parse sgrk times (skip TIMEOUT/-/SKIPPED — only numeric values like "0.035s")
        sgrk_stats=$(parse_runtime "${family_dir}/runtime" | awk '
            $2 != "-" && $2 ~ /^[0-9]/ {
                gsub(/s$/, "", $2)
                n++
                sum += $2
                if (n == 1 || $2 < min) min = $2
                if (n == 1 || $2 > max) max = $2
            }
            END {
                if (n > 0)
                    printf "%d %.3f %.3f %.3f", n, min, max, sum
                else
                    printf "0 0 0 0"
            }')

        sgrk_n=$(echo "$sgrk_stats" | awk '{print $1}')
        sgrk_min=$(echo "$sgrk_stats" | awk '{printf "%.3fs", $2}')
        sgrk_max=$(echo "$sgrk_stats" | awk '{printf "%.3fs", $3}')
        sgrk_tot=$(echo "$sgrk_stats" | awk '{printf "%.3fs", $4}')
        sgrk_tot_raw=$(echo "$sgrk_stats" | awk '{print $4}')

        # Parse Strix times
        strix_min="-"
        strix_max="-"
        strix_tot="-"
        speedup="-"

        if [[ -f "${family_dir}/strix_runtime" ]]; then
            strix_stats=$(parse_runtime "${family_dir}/strix_runtime" | awk '
                $2 != "-" && $2 ~ /^[0-9]/ {
                    gsub(/s$/, "", $2)
                    n++
                    sum += $2
                    if (n == 1 || $2 < min) min = $2
                    if (n == 1 || $2 > max) max = $2
                }
                END {
                    if (n > 0)
                        printf "%d %.3f %.3f %.3f", n, min, max, sum
                    else
                        printf "0 0 0 0"
                }')

            strix_n=$(echo "$strix_stats" | awk '{print $1}')
            if [[ "$strix_n" -gt 0 ]]; then
                strix_min=$(echo "$strix_stats" | awk '{printf "%.3fs", $2}')
                strix_max=$(echo "$strix_stats" | awk '{printf "%.3fs", $3}')
                strix_tot=$(echo "$strix_stats" | awk '{printf "%.3fs", $4}')
                strix_tot_raw=$(echo "$strix_stats" | awk '{print $4}')

                if [[ $(echo "$sgrk_tot_raw" | awk '{print ($1 > 0)}') == "1" ]]; then
                    speedup=$(awk "BEGIN { printf \"%.1fx\", ${strix_tot_raw} / ${sgrk_tot_raw} }")
                fi
            fi
        fi

        printf "  %-28s %-5s %6s  %10s %10s %10s  %10s %10s %10s  %8s\n" \
            "$family" "$cat" "$sgrk_n" "$sgrk_min" "$sgrk_max" "$sgrk_tot" \
            "$strix_min" "$strix_max" "$strix_tot" "$speedup"
    done
done

echo ""
echo "(Speedup = Strix total / sgrk total, computed only where both tools completed the same tests)"

# ──────────────────────────────────────────────────────────
#  Table 4: Per-Instance Side-by-Side (one sub-table per family)
# ──────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════════════════════════════════════════════════╗"
echo "║                          Table 4: Per-Instance Comparison (sgrk vs Strix)                                 ║"
echo "╚══════════════════════════════════════════════════════════════════════════════════════════════════════════════╝"
echo ""

for cat in "${CATEGORIES[@]}"; do
    cat_dir="${MYDIR}/${cat}"
    [[ ! -d "$cat_dir" ]] && continue

    for family_dir in "${cat_dir}"/*/; do
        [[ ! -f "${family_dir}/runtime" ]] && continue
        family="$(basename "$family_dir")"
        has_strix=false
        [[ -f "${family_dir}/strix_runtime" ]] && has_strix=true

        echo "── ${cat} / ${family} ──────────────────────────────────────────────────"
        if [[ "$has_strix" == true ]]; then
            printf "  %-6s  %-40s %12s  %12s  %10s  %-15s\n" \
                "#" "Test" "sgrk" "Strix" "Speedup" "Result"
            printf "  %-6s  %-40s %12s  %12s  %10s  %-15s\n" \
                "─" "────" "────" "─────" "───────" "──────"
        else
            printf "  %-6s  %-40s %12s  %-15s\n" "#" "Test" "sgrk" "Result"
            printf "  %-6s  %-40s %12s  %-15s\n" "─" "────" "────" "──────"
        fi

        # Build associative-style lookup: write sgrk data to temp file
        sgrk_tmp=$(mktemp)
        parse_runtime "${family_dir}/runtime" > "$sgrk_tmp"

        strix_tmp=$(mktemp)
        if [[ "$has_strix" == true ]]; then
            parse_runtime "${family_dir}/strix_runtime" > "$strix_tmp"
        fi

        idx=0
        while IFS=' ' read -r name sgrk_time sgrk_result; do
            idx=$((idx + 1))

            if [[ "$has_strix" == true ]]; then
                # Look up matching Strix line
                strix_line=$(awk -v n="$name" '$1 == n { print $2, $NF }' "$strix_tmp")
                strix_time=$(echo "$strix_line" | awk '{print $1}')
                strix_result=$(echo "$strix_line" | awk '{print $2}')

                if [[ -z "$strix_time" ]]; then
                    strix_time="-"
                    strix_result="-"
                fi

                # Compute per-instance speedup
                inst_speedup="-"
                if [[ "$sgrk_time" =~ ^[0-9] && "$strix_time" =~ ^[0-9] ]]; then
                    sgrk_val=$(echo "$sgrk_time" | sed 's/s$//')
                    strix_val=$(echo "$strix_time" | sed 's/s$//')
                    if [[ $(awk "BEGIN { print ($sgrk_val > 0) }") == "1" ]]; then
                        inst_speedup=$(awk "BEGIN { printf \"%.1fx\", ${strix_val} / ${sgrk_val} }")
                    fi
                fi

                printf "  %-6s  %-40s %12s  %12s  %10s  %-15s\n" \
                    "$idx" "$name" "$sgrk_time" "$strix_time" "$inst_speedup" "$sgrk_result"
            else
                printf "  %-6s  %-40s %12s  %-15s\n" \
                    "$idx" "$name" "$sgrk_time" "$sgrk_result"
            fi
        done < "$sgrk_tmp"

        rm -f "$sgrk_tmp" "$strix_tmp"
        echo ""
    done
done
