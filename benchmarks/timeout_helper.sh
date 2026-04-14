#!/bin/bash
# Portable timeout helper for macOS (no coreutils needed).
# Source this file: source "$(dirname "$0")/timeout_helper.sh"
#
# Usage: run_with_timeout <seconds> <command> [args...]
# After call, check:
#   _timeout_output  — captured stdout
#   _timeout_stderr  — captured stderr
#   _timeout_exit    — 0 = normal, 142 = timed out

run_with_timeout() {
    local limit="$1"; shift
    local tmpout=$(mktemp)
    local tmperr=$(mktemp)

    "$@" > "$tmpout" 2>"$tmperr" &
    local pid=$!

    # Background watchdog: SIGTERM first, then SIGKILL after 2s grace
    ( sleep "$limit"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null ) &
    local watchdog=$!

    wait "$pid" 2>/dev/null
    local rc=$?

    # Kill watchdog if process finished on its own
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null

    _timeout_output=$(cat "$tmpout")
    _timeout_stderr=$(cat "$tmperr")
    rm -f "$tmpout" "$tmperr"

    # Killed by signal → treat as timeout (128+15=143 for SIGTERM, 128+9=137 for SIGKILL)
    if [[ $rc -eq 143 || $rc -eq 137 ]]; then
        _timeout_exit=142
    else
        _timeout_exit=$rc
    fi
}
