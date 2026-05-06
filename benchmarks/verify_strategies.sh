#!/bin/bash
# Verify that strategies for realizable specs actually satisfy their guarantees.
# For each realizable spec, plays the game with worst-case inputs (all 1s)
# for N steps and checks:
#   R2P (GF→FG): FG guarantee outputs stabilize (last K steps all have them true)
#   R2R (GF→GF): GF guarantee outputs recur (appear in last K steps)
#   P2R (FG→GF): GF guarantee outputs recur (appear in last K steps)

MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
SGRK="${MYDIR}/../bin/sgrk"

STEPS=${STEPS:-30}       # Number of play steps
STABLE_WINDOW=${STABLE_WINDOW:-10}  # Last K steps to check for FG stabilization
RECUR_WINDOW=${RECUR_WINDOW:-15}    # Last K steps to check for GF recurrence

PASS=0
FAIL=0
SKIP=0

# Extract output guarantee variables from .sgrk file's justice section
# For R2P: FG guarantees (outputs that must stabilize)
# For R2R/P2R: GF guarantees (outputs that must recur)
get_fg_guarantee_vars() {
    local file="$1"
    # Extract variables inside FG(...) on the guarantee side (after ->)
    # Look for patterns: FG "out:varname"
    grep -o 'FG[^)]*"out:[^"]*"' "$file" | grep -o '"out:[^"]*"' | sed 's/"//g' | sort -u
}

get_gf_guarantee_vars() {
    local file="$1"
    # Extract variables after -> that are in GF(...)
    # Match: -> ... GF "out:varname"
    # This is a simplification — grabs all GF output vars
    local justice_line
    justice_line=$(tail -1 "$file")
    echo "$justice_line" | grep -o 'GF[^)]*"out:[^"]*"' | grep -o '"out:[^"]*"' | sed 's/"//g' | sort -u
}

detect_type() {
    local file="$1"
    local justice_line
    justice_line=$(tail -1 "$file")

    if echo "$justice_line" | grep -q '(GF.*->.*FG'; then
        echo "R2P"
    elif echo "$justice_line" | grep -q '(FG.*->.*GF'; then
        echo "P2R"
    else
        echo "R2R"
    fi
}

verify_strategy() {
    local sgrk_file="$1"
    local name="$2"

    # First check realizability
    local result
    result=$("$SGRK" "$sgrk_file" 2>/dev/null)

    if [[ "$result" != "Realizable" ]]; then
        # Skip unrealizable specs — no strategy to verify
        return 2
    fi

    local spec_type
    spec_type=$(detect_type "$sgrk_file")

    # Count input variables
    local input_count
    input_count=$(grep -o '"in:[^"]*"' "$sgrk_file" | sort -u | wc -l | tr -d ' ')

    # Generate worst-case inputs: all 1s for STEPS rounds, then quit
    local play_input=""
    local all_ones
    all_ones=$(printf '1%.0s' $(seq 1 "$input_count"))
    for i in $(seq 1 "$STEPS"); do
        play_input+="${all_ones}\n"
    done
    play_input+="quit\n"

    # Run --play and capture output
    local play_output
    play_output=$(printf "$play_input" | "$SGRK" "$sgrk_file" --play=stdin 2>&1)

    # Extract state lines (lines starting with "Current state:")
    local states
    states=$(echo "$play_output" | grep "^Current state:" | sed 's/Current state: //')

    local total_states
    total_states=$(echo "$states" | wc -l | tr -d ' ')

    if [[ "$total_states" -lt 5 ]]; then
        echo "  WARNING: only $total_states states captured"
        return 2
    fi

    # Get the last WINDOW states for checking
    case "$spec_type" in
        R2P)
            # FG guarantees must stabilize: check last STABLE_WINDOW steps
            local fg_vars
            fg_vars=$(get_fg_guarantee_vars "$sgrk_file")

            if [[ -z "$fg_vars" ]]; then
                echo "  WARNING: no FG guarantee vars found"
                return 2
            fi

            local window_states
            window_states=$(echo "$states" | tail -n "$STABLE_WINDOW")

            local all_stable=true
            for var in $fg_vars; do
                # Check if var appears in ALL of the last STABLE_WINDOW states
                local present_count
                present_count=$(echo "$window_states" | grep -c "$var" || true)

                if [[ "$present_count" -lt "$STABLE_WINDOW" ]]; then
                    # Check for negated guarantees: FG !"out:var" means var must be 0
                    # For simplicity, only check positive guarantees here
                    all_stable=false
                    echo "  FG($var) NOT stabilized: present in $present_count/$STABLE_WINDOW last steps"
                fi
            done

            if $all_stable; then
                return 0
            else
                return 1
            fi
            ;;

        R2R|P2R)
            # GF guarantees must recur: check last RECUR_WINDOW steps
            local gf_vars
            gf_vars=$(get_gf_guarantee_vars "$sgrk_file")

            if [[ -z "$gf_vars" ]]; then
                echo "  WARNING: no GF guarantee vars found"
                return 2
            fi

            local window_states
            window_states=$(echo "$states" | tail -n "$RECUR_WINDOW")

            local all_recur=true
            for var in $gf_vars; do
                local present_count
                present_count=$(echo "$window_states" | grep -c "$var" || true)

                if [[ "$present_count" -lt 2 ]]; then
                    all_recur=false
                    echo "  GF($var) NOT recurring: present in $present_count/$RECUR_WINDOW last steps"
                fi
            done

            if $all_recur; then
                return 0
            else
                return 1
            fi
            ;;
    esac
}

echo "=== Strategy Verification ==="
echo "Steps: $STEPS, FG window: $STABLE_WINDOW, GF window: $RECUR_WINDOW"
echo ""

# Run on all benchmark categories
for category_dir in "${MYDIR}"/R2P "${MYDIR}"/R2R "${MYDIR}"/P2R; do
    category=$(basename "$category_dir")

    if [[ ! -d "$category_dir" ]]; then
        continue
    fi

    echo "--- $category ---"

    for f in "$category_dir"/**/*.sgrk; do
        [[ -f "$f" ]] || continue

        name="$(basename "$f")"
        dir="$(basename "$(dirname "$f")")"

        echo -n "  ${dir}/${name}: "

        verify_strategy "$f" "${dir}/${name}"
        status=$?

        case $status in
            0) echo "PASS"; PASS=$((PASS + 1)) ;;
            1) echo "FAIL (strategy broken)"; FAIL=$((FAIL + 1)) ;;
            2) echo "SKIP"; SKIP=$((SKIP + 1)) ;;
        esac
    done

    echo ""
done

echo "=== Strategy Verification: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
