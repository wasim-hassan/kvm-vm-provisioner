#!/bin/bash
# Shared library for fedora-v3 scripts
# Source with: source "${HOME}/fedora-v3/lib/common.sh"

# ---- Guard against double-source ----
[ -n "${COMMON_SH_SOURCED:-}" ] && return 0
COMMON_SH_SOURCED=true

# ---- Color definitions ----
readonly NC=$'\033[0m'
readonly GREEN=$'\033[0;32m'
readonly RED=$'\033[0;31m'
readonly YELLOW=$'\033[1;33m'

# ---- Core logger ----
# All output goes to stdout with ANSI colors.
# The caller should redirect stdout to a log file (e.g. via exec > >(tee ...))
# to capture both terminal and file output.

_log() {
    local level="$1"
    local color="$2"
    shift 2
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local formatted
    formatted=$(printf '%s  %-10s %s' "[$ts]" "[$level]" "$*")
    printf '%s%s%s\n' "${color}" "${formatted}" "${NC}"
}

info()       { _log "INFO"    "$GREEN"  "$@"; }
success()    { _log "SUCCESS" "$GREEN"  "$@"; }
error()      { _log "ERROR"   "$RED"    "$@"; }
skip()       { _log "SKIP"    "$YELLOW" "$@"; }
verify_msg() { _log "VERIFY"  "$GREEN"  "$@"; }
complete_msg() { _log "COMPLETE" "$GREEN" "$@"; }
logged()     { _log "LOGGED"  "$GREEN"  "$@"; }

heading() {
    local msg
    msg="==== $* ===="
    echo "$msg"
}

# ---- Tracking ----
FAILED_SECTIONS=()

# ---- Verification ----
_verify_init() {
    if [ -z "${VERIFY_DIR:-}" ]; then
        mkdir -p "$HOME/fedora-v3/logs/temp"
        VERIFY_DIR="$(mktemp -d "$HOME/fedora-v3/logs/temp/verify-XXXX")"
    fi
}

verify_check() {
    local label="$1"
    local cmd="$2"
    _verify_init
    if eval "$cmd" >/dev/null 2>&1; then
        echo "PASS|$label" >> "$VERIFY_DIR/verify.log"
    else
        echo "FAIL|$label" >> "$VERIFY_DIR/verify.log"
    fi
}

verify_check_file() {
    local label="$1"
    local path="$2"
    _verify_init
    if [ -e "$path" ]; then
        echo "PASS|$label" >> "$VERIFY_DIR/verify.log"
    else
        echo "FAIL|$label" >> "$VERIFY_DIR/verify.log"
    fi
}

verify_check_service() {
    local label="$1"
    local expected="$2"
    local service="$3"
    _verify_init
    local actual
    actual=$(systemctl is-enabled "$service" 2>/dev/null || echo "not-found")
    if [ "$actual" = "$expected" ]; then
        echo "PASS|$label" >> "$VERIFY_DIR/verify.log"
    else
        echo "FAIL|$label (expected $expected, got $actual)" >> "$VERIFY_DIR/verify.log"
    fi
}

verify_report() {
    local logfile="$VERIFY_DIR/verify.log"
    if [ ! -f "$logfile" ]; then
        return
    fi
    local pass=0 fail=0
    while IFS='|' read -r status label; do
        if [ "$status" = "PASS" ]; then
            ((pass++))
        else
            verify_msg "FAIL: $label"
            ((fail++))
        fi
    done < "$logfile"
    if [ "$fail" -eq 0 ]; then
        verify_msg "All $pass check(s) passed"
    else
        verify_msg "$pass passed, $fail failed"
        FAILED_SECTIONS+=("Verification: $fail check(s) failed")
    fi
}

# ---- Log cleanup ----
log_cleanup() {
    wait
    if [ -n "${LOGFILE:-}" ] && [ -f "$LOGFILE" ]; then
        sed -i 's/\x1b\[[0-9;]*m//g' "$LOGFILE"
    fi
}
