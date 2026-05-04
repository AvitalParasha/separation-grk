#!/bin/bash
# ============================================================================
# compare_results_HPC.sh — Parallel Slurm benchmark runner
# ============================================================================
#
# Submits one Slurm job per (tool, family) combination, all in parallel.
# Each job gets 1 CPU, 16G RAM, qos=normal.
# Monitors progress and generates comparison tables on the fly.
#
# Usage: bash compare_results_HPC.sh [OPTIONS] [R2R|R2P|P2R|all]
#
# Options:
#   --strix=<path>         Path to Strix binary (default: ~/work/strix)
#   --spot=<path>          Path to ltlsynt (default: ltlsynt)
#   --timeout=SECONDS      Per-test timeout for all tools (default: 5400)
#   --strix-timeout=S      Strix-specific timeout
#   --spot-timeout=S       Spot-specific timeout
#   --force                Clear cached results before running
#   --mem=<size>           Memory per job (default: 16G)
#   --qos=<name>           Slurm QoS (default: normal)
#   --node=<name>          Pin all jobs to a specific compute node (for fair timing)
#   --poll=SECONDS         Status poll interval (default: 30)
#   --help                 Show this help
# ============================================================================

set -uo pipefail

MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
SGRK="${MYDIR}/../bin/sgrk"
WORKER="${MYDIR}/run_single_family.sh"

# Defaults
STRIX="$HOME/work/strix"
SPOT="ltlsynt"
TIMEOUT=5400
STRIX_TIMEOUT=""
SPOT_TIMEOUT=""
CATEGORY="all"
FORCE=false
MEM="16G"
QOS="normal"
NODE=""
CONSTRAINT="gold6130"
POLL_INTERVAL=30

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --strix=*)         STRIX="${arg#*=}" ;;
        --spot=*)          SPOT="${arg#*=}" ;;
        --timeout=*)       TIMEOUT="${arg#*=}" ;;
        --strix-timeout=*) STRIX_TIMEOUT="${arg#*=}" ;;
        --spot-timeout=*)  SPOT_TIMEOUT="${arg#*=}" ;;
        --force)           FORCE=true ;;
        --mem=*)           MEM="${arg#*=}" ;;
        --qos=*)           QOS="${arg#*=}" ;;
        --node=*)          NODE="${arg#*=}" ;;
        --constraint=*)    CONSTRAINT="${arg#*=}" ;;
        --poll=*)          POLL_INTERVAL="${arg#*=}" ;;
        R2R|R2P|P2R|all)   CATEGORY="$arg" ;;
        --help)
            head -20 "$0" | grep -E "^#" | sed 's/^# //'
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# Apply default tool-specific timeouts
[[ -z "$STRIX_TIMEOUT" ]] && STRIX_TIMEOUT="$TIMEOUT"
[[ -z "$SPOT_TIMEOUT" ]] && SPOT_TIMEOUT="$TIMEOUT"

# Validate
if [[ ! -x "$SGRK" ]]; then
    echo "Error: sgrk binary not found at $SGRK"
    exit 1
fi
if [[ ! -f "$WORKER" ]]; then
    echo "Error: Worker script not found at $WORKER"
    exit 1
fi

# Detect tools
TOOLS=(sgrk)
HAS_STRIX=false
HAS_SPOT=false

if [[ -x "$STRIX" ]]; then
    HAS_STRIX=true
    TOOLS+=(strix)
    echo "Strix: $STRIX"
else
    echo "Warning: Strix not found at $STRIX — skipping Strix"
fi

if command -v "$SPOT" &>/dev/null; then
    HAS_SPOT=true
    TOOLS+=(spot)
    echo "Spot:  $($SPOT --version 2>&1 | head -1)"
else
    echo "Warning: ltlsynt not found — skipping Spot"
fi

echo "Tools: ${TOOLS[*]}"
echo "Timeout: sgrk=${TIMEOUT}s, strix=${STRIX_TIMEOUT}s, spot=${SPOT_TIMEOUT}s"
echo "Slurm: --mem=${MEM} --qos=${QOS} --constraint=${CONSTRAINT}"
echo ""

# Determine categories
if [[ "$CATEGORY" == "all" ]]; then
    CATEGORIES=(R2R R2P P2R)
else
    CATEGORIES=("$CATEGORY")
fi

# Create log directory
LOG_DIR="${MYDIR}/results/logs"
mkdir -p "$LOG_DIR"

# Discover families and submit jobs
declare -a JOB_IDS=()
declare -a JOB_LABELS=()
TOTAL_JOBS=0

for cat in "${CATEGORIES[@]}"; do
    cat_dir="${MYDIR}/${cat}"
    [[ ! -d "$cat_dir" ]] && continue

    for family_dir in "${cat_dir}"/*/; do
        [[ ! -d "$family_dir" ]] && continue
        family="$(basename "$family_dir")"

        # Check if family has .sgrk files
        sgrk_count=$(find "$family_dir" -maxdepth 1 -name "*.sgrk" ! -name "mixed_*" 2>/dev/null | wc -l)
        [[ "$sgrk_count" -eq 0 ]] && continue

        for tool in "${TOOLS[@]}"; do
            # Determine timeout for this tool
            case "$tool" in
                sgrk)  tool_timeout="$TIMEOUT" ;;
                strix) tool_timeout="$STRIX_TIMEOUT" ;;
                spot)  tool_timeout="$SPOT_TIMEOUT" ;;
            esac

            # Clear cached results if --force
            if [[ "$FORCE" == true ]]; then
                case "$tool" in
                    sgrk)  rm -f "${family_dir}/runtime" ;;
                    strix) rm -f "${family_dir}/strix_runtime" ;;
                    spot)  rm -f "${family_dir}/spot_runtime" ;;
                esac
            fi

            label="${tool}_${cat}_${family}"
            log_file="${LOG_DIR}/${label}.log"

            # Build sbatch options
            SBATCH_OPTS=(
                --job-name="bench_${label}"
                --cpus-per-task=1
                --mem="$MEM"
                --qos="$QOS"
                --exclude="gpu[1-8]"
                --output="$log_file"
                --error="$log_file"
                --parsable
            )
            [[ -n "$CONSTRAINT" ]] && SBATCH_OPTS+=(--constraint="$CONSTRAINT")
            [[ -n "$NODE" ]] && SBATCH_OPTS+=(--nodelist="$NODE")

            # Submit Slurm job
            job_id=$(sbatch "${SBATCH_OPTS[@]}" \
                --wrap="bash ${WORKER} ${tool} ${family_dir} ${tool_timeout} --strix=${STRIX} --spot=${SPOT}")

            if [[ $? -eq 0 && -n "$job_id" ]]; then
                JOB_IDS+=("$job_id")
                JOB_LABELS+=("$label")
                TOTAL_JOBS=$((TOTAL_JOBS + 1))
                echo "  Submitted: $label (job $job_id)"
            else
                echo "  FAILED to submit: $label"
            fi
        done
    done
done

echo ""
echo "========================================"
echo "Submitted $TOTAL_JOBS jobs. Monitoring..."
echo "========================================"
echo ""

if [[ $TOTAL_JOBS -eq 0 ]]; then
    echo "No jobs submitted. Check your benchmark directories."
    exit 1
fi

# Monitor loop
COMPLETED=0
LAST_COMPLETED=0

while true; do
    # Count remaining jobs
    RUNNING=0
    for jid in "${JOB_IDS[@]}"; do
        state=$(squeue -j "$jid" -h -o "%t" 2>/dev/null)
        if [[ -n "$state" ]]; then
            RUNNING=$((RUNNING + 1))
        fi
    done

    COMPLETED=$((TOTAL_JOBS - RUNNING))

    if [[ $COMPLETED -ne $LAST_COMPLETED ]]; then
        echo "[$(date +%H:%M:%S)] Progress: $COMPLETED / $TOTAL_JOBS jobs done ($RUNNING running)"
        LAST_COMPLETED=$COMPLETED
    fi

    if [[ $RUNNING -eq 0 ]]; then
        break
    fi

    sleep "$POLL_INTERVAL"
done

echo ""
echo "========================================"
echo "All $TOTAL_JOBS jobs completed!"
echo "========================================"
echo ""

# ============================================================================
# Final comparison: read all runtime files and compare results
# ============================================================================

normalize_result() {
    local r="$1"
    case "$(echo "$r" | tr '[:upper:]' '[:lower:]')" in
        realizable)    echo "REALIZABLE" ;;
        unrealizable)  echo "UNREALIZABLE" ;;
        timeout)       echo "TIMEOUT" ;;
        skipped)       echo "SKIPPED" ;;
        n/a)           echo "N/A" ;;
        convert_error) echo "N/A" ;;
        *)             echo "N/A" ;;
    esac
}

parse_result() { echo "$1" | awk '{print $NF}'; }
parse_time()   { echo "$1" | awk '{print $2}'; }

get_line() {
    local file="$1" name="$2"
    [[ ! -f "$file" ]] && return
    awk -v n="$name" '$1 == n { print; exit }' "$file"
}

TOTAL_MATCH=0
TOTAL_MISMATCH=0
TOTAL_NA=0
TOTAL_SKIP=0

for cat in "${CATEGORIES[@]}"; do
    cat_dir="${MYDIR}/${cat}"
    [[ ! -d "$cat_dir" ]] && continue

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
        done < <(find "$family_dir" -maxdepth 1 -name "*.sgrk" ! -name "mixed_*" | sort -V)
        [[ ${#sgrk_files[@]} -eq 0 ]] && continue

        echo "=== ${cat} / ${family} ==="
        printf "%-30s %10s  %10s  %10s  %-10s\n" "Test" "sgrk" "Strix" "Spot" "Status"
        printf "%-30s %10s  %10s  %10s  %-10s\n" "----" "----" "-----" "----" "------"

        family_match=0; family_mismatch=0; family_na=0; family_skip=0

        for f in "${sgrk_files[@]}"; do
            name="$(basename "$f")"

            # Read results from runtime files
            sgrk_line=$(get_line "${family_dir}/runtime" "$name")
            sgrk_result=$(parse_result "$sgrk_line")
            sgrk_time=$(parse_time "$sgrk_line")
            [[ -z "$sgrk_result" ]] && sgrk_result="N/A"
            [[ -z "$sgrk_time" ]] && sgrk_time="-"

            strix_result="N/A"; strix_time="-"
            if [[ "$HAS_STRIX" == true ]]; then
                strix_line=$(get_line "${family_dir}/strix_runtime" "$name")
                [[ -n "$strix_line" ]] && strix_result=$(parse_result "$strix_line") && strix_time=$(parse_time "$strix_line")
            fi

            spot_result="N/A"; spot_time="-"
            if [[ "$HAS_SPOT" == true ]]; then
                spot_line=$(get_line "${family_dir}/spot_runtime" "$name")
                [[ -n "$spot_line" ]] && spot_result=$(parse_result "$spot_line") && spot_time=$(parse_time "$spot_line")
            fi

            # Normalize
            sgrk_norm=$(normalize_result "$sgrk_result")
            strix_norm=$(normalize_result "$strix_result")
            spot_norm=$(normalize_result "$spot_result")

            # Compare
            status="MATCH"
            if [[ "$sgrk_norm" == "TIMEOUT" ]]; then
                status="SKIP"
            elif [[ "$HAS_STRIX" == true && "$strix_norm" != "N/A" && "$strix_norm" != "TIMEOUT" && "$strix_norm" != "SKIPPED" && "$sgrk_norm" != "$strix_norm" ]]; then
                status="**MISMATCH(Strix)**"
            elif [[ "$HAS_SPOT" == true && "$spot_norm" != "N/A" && "$spot_norm" != "TIMEOUT" && "$spot_norm" != "SKIPPED" && "$sgrk_norm" != "$spot_norm" ]]; then
                status="**MISMATCH(Spot)**"
            elif [[ "$strix_norm" == "N/A" || "$spot_norm" == "N/A" ]]; then
                status="N/A"
            elif [[ "$strix_norm" == "TIMEOUT" || "$strix_norm" == "SKIPPED" || "$spot_norm" == "TIMEOUT" || "$spot_norm" == "SKIPPED" ]]; then
                status="SKIP"
            fi

            case "$status" in
                *MATCH*)    family_match=$((family_match + 1)) ;;
                *MISMATCH*) family_mismatch=$((family_mismatch + 1)) ;;
                N/A)        family_na=$((family_na + 1)) ;;
                SKIP)       family_skip=$((family_skip + 1)) ;;
            esac

            printf "%-30s %10s  %10s  %10s  %-10s\n" \
                "$name" "$sgrk_time" "$strix_time" "$spot_time" "$status"
        done

        echo ""
        echo "  Summary: ${family_match} MATCH, ${family_mismatch} MISMATCH, ${family_na} N/A, ${family_skip} SKIP"
        echo ""

        TOTAL_MATCH=$((TOTAL_MATCH + family_match))
        TOTAL_MISMATCH=$((TOTAL_MISMATCH + family_mismatch))
        TOTAL_NA=$((TOTAL_NA + family_na))
        TOTAL_SKIP=$((TOTAL_SKIP + family_skip))
    done
done

echo "========================================"
echo "Overall: ${TOTAL_MATCH} MATCH, ${TOTAL_MISMATCH} MISMATCH, ${TOTAL_NA} N/A, ${TOTAL_SKIP} SKIP"
echo "========================================"

# Final table generation
echo ""
echo "Generating final SVG tables and slideshow..."
sleep 5
python3 "${MYDIR}/generate_table_images.py" "$CATEGORY" "slideshow_HPC.html"
echo ""
echo "View results: benchmarks/results/slideshow_HPC.html"

# Print job log locations
echo ""
echo "Job logs: ${LOG_DIR}/"
for i in "${!JOB_IDS[@]}"; do
    echo "  ${JOB_LABELS[$i]}: ${LOG_DIR}/${JOB_LABELS[$i]}.log"
done

if [[ $TOTAL_MISMATCH -gt 0 ]]; then
    echo ""
    echo "WARNING: Mismatches detected!"
    exit 1
fi
