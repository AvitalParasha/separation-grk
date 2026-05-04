#!/bin/bash
# Portable timeout helper.
# Uses GNU `timeout` on Linux, falls back to watchdog on macOS.
#
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

    if command -v timeout &>/dev/null; then
        # Linux: use GNU timeout with --kill-after and process group kill
        timeout --kill-after=5s --signal=TERM "${limit}s" "$@" > "$tmpout" 2>"$tmperr"
        local rc=$?
        # GNU timeout returns 124 on timeout
        if [[ $rc -eq 124 || $rc -eq 137 ]]; then
            _timeout_exit=142
        else
            _timeout_exit=$rc
        fi
    else
        # macOS fallback: background watchdog
        "$@" > "$tmpout" 2>"$tmperr" &
        local pid=$!

        ( sleep "$limit"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null ) &
        local watchdog=$!

        wait "$pid" 2>/dev/null
        local rc=$?

        kill "$watchdog" 2>/dev/null
        wait "$watchdog" 2>/dev/null

        if [[ $rc -eq 143 || $rc -eq 137 ]]; then
            _timeout_exit=142
        else
            _timeout_exit=$rc
        fi
    fi

    _timeout_output=$(cat "$tmpout")
    _timeout_stderr=$(cat "$tmperr")
    rm -f "$tmpout" "$tmperr"
}
