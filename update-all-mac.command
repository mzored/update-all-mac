#!/bin/bash

# Full macOS app and package updater
# Run by double-clicking in Finder or from Terminal
# Author: MZored
# Date: 2026-08-15
# Version: 3.4.0

# Important: do not use set -e, so later steps can continue after an error
set -uo pipefail

# Output colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

STEP_OK=0
STEP_WARN=10
STEP_SKIP=20
STEP_FAIL=30

LOG_FILE="${UPDATE_ALL_LOG_FILE:-$HOME/Library/Logs/update-all-mac.log}"
LOG_MAX_BYTES="${UPDATE_ALL_LOG_MAX_BYTES:-1048576}"
NET_TIMEOUT="${UPDATE_ALL_NET_TIMEOUT:-600}"
HEARTBEAT_SECONDS="${UPDATE_ALL_HEARTBEAT_SECONDS:-30}"
TEMP_MAX_AGE_MINUTES="${UPDATE_ALL_TEMP_MAX_AGE_MINUTES:-1440}"
DATE=$(date '+%Y-%m-%d %H:%M:%S')
START_EPOCH=$(date +%s)
LOCK_DIR="${UPDATE_ALL_LOCK_DIR:-/tmp/update-all-mac.lock}"
LOCK_HELD=0
RUN_TEMP_DIR=""
LAST_COMMAND_RECLAIMED=""
ACTIVE_HEARTBEAT_PID=""
PARALLEL_WORKER_PIDS=()

STEP_IDS=("homebrew" "npm" "mas" "ohmyzsh" "pip" "pipx" "uv" "rust" "mise" "asdf" "gcloud" "cleanup")
STEP_NAMES=("Homebrew" "npm" "Mac App Store" "Oh My Zsh" "pip" "pipx" "uv" "Rust" "mise" "asdf" "gcloud" "Cleanup")
STEP_FUNCS=("update_homebrew" "update_npm" "update_mas" "update_ohmyzsh" "check_pip" "update_pipx" "update_uv" "update_rust" "update_mise" "update_asdf" "update_gcloud" "run_cleanup")
STEP_STATUS=()
STEP_SELECTED=()
TOTAL_STEPS=${#STEP_NAMES[@]}
ONLY_STEPS_CSV="${UPDATE_ALL_ONLY:-}"
SKIP_STEPS_CSV="${UPDATE_ALL_SKIP:-}"
RUN_STEP_INDEXES=()
EXIT_ZERO=0
STRICT=0
FAIL_FAST=0
NO_COLOR=0
ENABLE_MACOS_STEP=0
LIST_STEPS=0
SHOW_HELP=0
BREW_GREEDY_CASKS=0
BREW_FORCE_CASK_REPAIR=0
PIPX_INCLUDE_INJECTED=1
MAS_ACCURATE=0
PARALLEL=0
DRY_RUN=0
DOCTOR=0
INSTALL_HOMEBREW=0
VERBOSE=0
DEEP_CLEAN=0

truthy() {
    case "${1:-0}" in
        1 | true | TRUE | yes | YES | on | ON) return 0 ;;
        *) return 1 ;;
    esac
}

if truthy "${UPDATE_ALL_EXIT_ZERO:-0}"; then EXIT_ZERO=1; fi
if truthy "${UPDATE_ALL_STRICT:-0}"; then STRICT=1; fi
if truthy "${UPDATE_ALL_FAIL_FAST:-0}"; then FAIL_FAST=1; fi
if truthy "${UPDATE_ALL_NO_COLOR:-0}"; then NO_COLOR=1; fi
if truthy "${UPDATE_ALL_MACOS:-0}"; then ENABLE_MACOS_STEP=1; fi
if truthy "${UPDATE_ALL_HOMEBREW_GREEDY_CASKS:-0}"; then BREW_GREEDY_CASKS=1; fi
if truthy "${UPDATE_ALL_FORCE_CASK_REPAIR:-0}"; then BREW_FORCE_CASK_REPAIR=1; fi
if truthy "${UPDATE_ALL_PIPX_INCLUDE_INJECTED:-1}"; then PIPX_INCLUDE_INJECTED=1; else PIPX_INCLUDE_INJECTED=0; fi
if truthy "${UPDATE_ALL_MAS_ACCURATE:-0}"; then MAS_ACCURATE=1; fi
if truthy "${UPDATE_ALL_PARALLEL:-0}"; then PARALLEL=1; fi
if truthy "${UPDATE_ALL_DRY_RUN:-0}"; then DRY_RUN=1; fi
if truthy "${UPDATE_ALL_INSTALL_HOMEBREW:-0}"; then INSTALL_HOMEBREW=1; fi
if truthy "${UPDATE_ALL_VERBOSE:-0}"; then VERBOSE=1; fi
if truthy "${UPDATE_ALL_DEEP_CLEAN:-0}"; then DEEP_CLEAN=1; fi

prepend_path_if_dir() {
    local dir="$1"

    [ -d "$dir" ] || return 0
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) PATH="$dir:$PATH" ;;
    esac
}

setup_path() {
    # .command files launched from Finder often get a minimal PATH.
    prepend_path_if_dir "/sbin"
    prepend_path_if_dir "/usr/sbin"
    prepend_path_if_dir "/bin"
    prepend_path_if_dir "/usr/bin"
    prepend_path_if_dir "$HOME/.local/bin"
    prepend_path_if_dir "/usr/local/sbin"
    prepend_path_if_dir "/usr/local/bin"
    prepend_path_if_dir "/opt/homebrew/sbin"
    prepend_path_if_dir "/opt/homebrew/bin"
    export PATH
}

print_steps() {
    local i=0
    while [ "$i" -lt "${#STEP_IDS[@]}" ]; do
        printf '%s\t%s\n' "${STEP_IDS[$i]}" "${STEP_NAMES[$i]}"
        i=$((i + 1))
    done
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --only <id1,id2>       Run only selected steps
  --skip <id1,id2>       Skip selected steps
  --fail-fast            Stop after first FAIL
  --strict               Exit non-zero on WARN
  --exit-zero            Always exit 0
  --no-color             Disable ANSI colors in stdout
  --macos                Add macOS updates check step (softwareupdate -l)
  --greedy-casks         Include Homebrew casks marked auto_updates/latest
  --force-cask-repair    Allow forced cask uninstall+install fallback
  --mas-accurate         Use slower, more accurate mas outdated detection
  --parallel             Run npm, pipx, and Mac App Store steps concurrently
  --dry-run              Show what would be updated without changing anything
  --install-homebrew     Install Homebrew if it is missing (bootstrap a Mac)
  --verbose              Stream full command output to the terminal
  --deep-clean           Purge reinstall caches in the Cleanup step
  --log-file <path>      Override log file path
  --lock-dir <path>      Override lock directory path
  --list-steps           Print available step IDs and exit
  --doctor               Report detected tools/versions and exit
  -h, --help             Show this help and exit

Step IDs:
$(print_steps | sed 's/^/  /')
EOF
}

# One line of the --doctor report: a label, the command that must exist, and an
# optional version command. Uses printf (not log) because --doctor runs before
# the log file descriptor is opened.
doctor_line() {
    local label="$1"
    local cmd="$2"
    shift 2
    local ver=""

    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf '%s\n' "  ${YELLOW}-${NC} ${label}: not installed"
        return 0
    fi

    if [ "$#" -gt 0 ]; then
        ver=$("$@" 2>/dev/null | head -n1 | tr -d '\r')
    fi
    printf '%s\n' "  ${GREEN}+${NC} ${label}: ${ver:-installed}"
}

# --doctor: report which managed tools are present and their versions so the
# user can see at a glance what this script can update on their Mac.
print_doctor() {
    printf '%s\n\n' "${BLUE}update-all-mac — doctor${NC}"
    printf '%s\n' "Detected tools:"
    doctor_line "Homebrew" brew brew --version
    doctor_line "npm" npm npm --version
    doctor_line "Mac App Store (mas)" mas mas version
    doctor_line "git" git git --version
    doctor_line "python3" python3 python3 --version
    doctor_line "pipx" pipx pipx --version
    doctor_line "uv" uv uv --version
    doctor_line "rustup" rustup rustup --version
    doctor_line "cargo" cargo cargo --version
    doctor_line "mise" mise mise --version
    doctor_line "asdf" asdf asdf --version
    doctor_line "gcloud" gcloud gcloud --version
    doctor_line "softwareupdate" softwareupdate

    if [ -d "$HOME/.oh-my-zsh" ]; then
        printf '%s\n' "  ${GREEN}+${NC} Oh My Zsh: installed"
    else
        printf '%s\n' "  ${YELLOW}-${NC} Oh My Zsh: not installed"
    fi

    printf '\n%s\n' "Configured steps: $(print_steps | awk '{print $1}' | tr '\n' ' ')"
    printf '%s\n' "Tip: add --dry-run to preview changes, or --parallel to speed up independent steps."
}

step_index_by_id() {
    local id="$1"
    local idx=0
    while [ "$idx" -lt "${#STEP_IDS[@]}" ]; do
        if [ "${STEP_IDS[$idx]}" = "$id" ]; then
            printf '%s' "$idx"
            return 0
        fi
        idx=$((idx + 1))
    done
    return 1
}

step_selected_by_id() {
    local id="$1"
    local idx=""

    if ! idx=$(step_index_by_id "$id"); then
        return 1
    fi

    [ "${STEP_SELECTED[$idx]:-0}" = "1" ]
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --only)
                if [ -z "${2:-}" ]; then
                    printf 'Missing value for --only\n' >&2
                    exit 2
                fi
                ONLY_STEPS_CSV="$2"
                shift 2
                ;;
            --skip)
                if [ -z "${2:-}" ]; then
                    printf 'Missing value for --skip\n' >&2
                    exit 2
                fi
                SKIP_STEPS_CSV="$2"
                shift 2
                ;;
            --exit-zero)
                EXIT_ZERO=1
                shift
                ;;
            --strict)
                STRICT=1
                shift
                ;;
            --fail-fast)
                FAIL_FAST=1
                shift
                ;;
            --lock-dir)
                if [ -z "${2:-}" ]; then
                    printf 'Missing value for --lock-dir\n' >&2
                    exit 2
                fi
                LOCK_DIR="$2"
                shift 2
                ;;
            --log-file)
                if [ -z "${2:-}" ]; then
                    printf 'Missing value for --log-file\n' >&2
                    exit 2
                fi
                LOG_FILE="$2"
                shift 2
                ;;
            --no-color)
                NO_COLOR=1
                shift
                ;;
            --macos)
                ENABLE_MACOS_STEP=1
                shift
                ;;
            --greedy-casks)
                BREW_GREEDY_CASKS=1
                shift
                ;;
            --force-cask-repair)
                BREW_FORCE_CASK_REPAIR=1
                shift
                ;;
            --mas-accurate)
                MAS_ACCURATE=1
                shift
                ;;
            --parallel)
                PARALLEL=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --install-homebrew)
                INSTALL_HOMEBREW=1
                shift
                ;;
            --verbose)
                VERBOSE=1
                shift
                ;;
            --deep-clean)
                DEEP_CLEAN=1
                shift
                ;;
            --list-steps)
                LIST_STEPS=1
                shift
                ;;
            --doctor)
                DOCTOR=1
                shift
                ;;
            -h | --help)
                SHOW_HELP=1
                shift
                ;;
            *)
                if [[ "$1" == --* ]]; then
                    printf 'Unknown option: %s\n' "$1" >&2
                    exit 2
                fi
                shift
                ;;
        esac
    done
}

apply_color_settings() {
    if [ "$NO_COLOR" -eq 1 ] || [ ! -t 1 ]; then
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        NC=''
    fi
}

maybe_enable_macos_step() {
    if [ "$ENABLE_MACOS_STEP" -ne 1 ]; then
        return 0
    fi

    STEP_IDS+=("macos")
    STEP_NAMES+=("macOS")
    STEP_FUNCS+=("check_macos_updates")
    TOTAL_STEPS=${#STEP_NAMES[@]}
}

init_step_selection() {
    local i=0
    local idx=""
    local id=""
    local only_ids=()
    local skip_ids=()

    STEP_SELECTED=()
    for ((i = 0; i < TOTAL_STEPS; i++)); do
        STEP_SELECTED+=("1")
    done

    if [ -n "$ONLY_STEPS_CSV" ]; then
        for ((i = 0; i < TOTAL_STEPS; i++)); do
            STEP_SELECTED[i]="0"
        done

        IFS=',' read -r -a only_ids <<<"$ONLY_STEPS_CSV"
        for id in "${only_ids[@]}"; do
            id="${id//[[:space:]]/}"
            [ -z "$id" ] && continue
            if ! idx=$(step_index_by_id "$id"); then
                printf 'Unknown step id in --only: %s\n' "$id" >&2
                exit 2
            fi
            STEP_SELECTED[idx]="1"
        done
    fi

    if [ -n "$SKIP_STEPS_CSV" ]; then
        IFS=',' read -r -a skip_ids <<<"$SKIP_STEPS_CSV"
        for id in "${skip_ids[@]}"; do
            id="${id//[[:space:]]/}"
            [ -z "$id" ] && continue
            if ! idx=$(step_index_by_id "$id"); then
                printf 'Unknown step id in --skip: %s\n' "$id" >&2
                exit 2
            fi
            STEP_SELECTED[idx]="0"
        done
    fi

    RUN_STEP_INDEXES=()
    for ((i = 0; i < TOTAL_STEPS; i++)); do
        if [ "${STEP_SELECTED[$i]}" = "1" ]; then
            RUN_STEP_INDEXES+=("$i")
        fi
    done
}

# Strip ANSI color/escape sequences from stdin.
strip_ansi() {
    sed -E $'s/\x1B\\[[0-9;]*[mK]//g'
}

# Line-buffered ANSI stripping for live command logs. GNU and BSD sed use
# different flags for unbuffered/line-buffered output, so detect the variant.
strip_ansi_stream() {
    if sed --version >/dev/null 2>&1; then
        sed -u -E $'s/\x1B\\[[0-9;]*[mK]//g'
    else
        sed -l -E $'s/\x1B\\[[0-9;]*[mK]//g'
    fi
}

# Drop known-benign macOS libmalloc diagnostics that some subprocesses (notably
# Homebrew's bundled ruby during cask upgrades) print to stderr. They are
# cosmetic and unrelated to a command's success, but pollute both the terminal
# and the log. Patterns are intentionally specific so genuine errors survive.
# --line-buffered (supported by macOS BSD grep) keeps live output streaming.
filter_benign_noise() {
    grep --line-buffered -v -E \
        -e "MallocStackLogging: can't turn off malloc stack logging because it was not enabled" \
        -e 'Nano zone abandoned due to inability to reserve vm space' \
        || true
}

# Logging helper. Writes the colored line to the terminal and a color-stripped
# copy to the log file descriptor (fd 9), opened by init_logging. Using a fd
# lets parallel workers redirect their log copy without touching globals.
log() {
    local message="$1"
    printf '%s\n' "$message"
    printf '%s\n' "$message" | strip_ansi >&9
}

# Detailed package tables stay in the canonical log by default. --verbose
# mirrors them to the terminal for users who want the complete command stream.
log_detail() {
    local message="$1"

    if [ "$VERBOSE" -eq 1 ]; then
        printf '%s\n' "$message"
    fi
    printf '%s\n' "$message" | strip_ansi >&9
}

# Run an external command, streaming a color-stripped copy to the log and, in
# verbose mode, mirroring it to the terminal. Returns the command's own exit
# code (not tee's), so callers can branch on success/failure as usual.
run_logged() {
    local tmp="" rc=0
    local heartbeat_pid=""

    LAST_COMMAND_RECLAIMED=""
    if ensure_run_temp_dir; then
        tmp=$(mktemp "$RUN_TEMP_DIR/command.XXXXXX" 2>/dev/null) || tmp=""
    fi
    if [ -z "$tmp" ]; then
        # Could not create a temp file; preserve live terminal and log output.
        start_heartbeat &
        heartbeat_pid=$!
        ACTIVE_HEARTBEAT_PID="$heartbeat_pid"
        if [ "$VERBOSE" -eq 1 ]; then
            "$@" 2>&1 | filter_benign_noise | strip_ansi_stream | tee /dev/fd/9
        else
            "$@" 2>&1 | filter_benign_noise | strip_ansi_stream >&9
        fi
        rc=${PIPESTATUS[0]}
        stop_heartbeat "$heartbeat_pid"
        return "$rc"
    fi

    # Keep a diagnostic tail while streaming every completed line into the
    # canonical log. The previous implementation flushed the temp file only
    # after command exit, losing the useful tail when a run was interrupted.
    start_heartbeat &
    heartbeat_pid=$!
    ACTIVE_HEARTBEAT_PID="$heartbeat_pid"
    if [ "$VERBOSE" -eq 1 ]; then
        "$@" 2>&1 | filter_benign_noise | tee "$tmp" | strip_ansi_stream | tee /dev/fd/9
    else
        "$@" 2>&1 | filter_benign_noise | tee "$tmp" | strip_ansi_stream >&9
    fi
    rc=${PIPESTATUS[0]}
    stop_heartbeat "$heartbeat_pid"
    if [ "$rc" -ne 0 ] && [ "$VERBOSE" -ne 1 ] && [ -s "$tmp" ]; then
        printf '%s\n' "  ↳ Last command output (full details: $LOG_FILE):"
        tail -n 20 "$tmp"
    fi
    LAST_COMMAND_RECLAIMED=$(sed -nE 's/.*(has freed|would free) approximately ([^ ]+) of disk space.*/\2/p' "$tmp" 2>/dev/null | tail -n 1)
    rm -f "$tmp"
    return "$rc"
}

start_heartbeat() {
    local elapsed=0

    [[ "$HEARTBEAT_SECONDS" =~ ^[1-9][0-9]*$ ]] || return 0
    while sleep "$HEARTBEAT_SECONDS"; do
        elapsed=$((elapsed + HEARTBEAT_SECONDS))
        printf '  … Still working (%ss; details: %s)\n' "$elapsed" "$LOG_FILE"
        if [ "$elapsed" -eq $((HEARTBEAT_SECONDS * 2)) ] && [ "$VERBOSE" -ne 1 ]; then
            printf '  … Compact mode hides command output; if input is expected, check the log or retry with --verbose.\n'
        fi
    done
}

stop_heartbeat() {
    local pid="${1:-}"

    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    if [ "$ACTIVE_HEARTBEAT_PID" = "$pid" ]; then
        ACTIVE_HEARTBEAT_PID=""
    fi
}

# Run "$@" under a timeout when gtimeout/timeout is available; otherwise run it
# unchanged. A timed-out command exits 124 (the timeout convention).
with_timeout() {
    local secs="$1"
    shift

    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    elif command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# Drop the existing log to a single rollover file once it grows past the cap,
# so the log does not grow without bound across many runs.
rotate_log_if_large() {
    local size=""

    [ -f "$LOG_FILE" ] || return 0
    size=$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d '[:space:]')
    [ -n "$size" ] || return 0
    if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
    fi
}

init_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    rotate_log_if_large
    printf '\n==== [%s] Update run started ====\n' "$DATE" >>"$LOG_FILE"
    # fd 9 is the canonical log sink used by log() and run_logged().
    exec 9>>"$LOG_FILE"
}

validate_lock_dir() {
    case "$LOCK_DIR" in
        "" | "/" | "/tmp" | "/var/tmp" | "$HOME" | "$HOME/")
            printf 'Unsafe --lock-dir value: %s\n' "$LOCK_DIR" >&2
            exit 2
            ;;
    esac
}

init_step_tracking() {
    local i
    STEP_STATUS=()
    for ((i = 0; i < TOTAL_STEPS; i++)); do
        STEP_STATUS+=("${YELLOW}⏭️${NC}")
    done
}

cleanup_runtime() {
    local temp_root="${TMPDIR:-/tmp}"
    local pid=""
    temp_root=${temp_root%/}

    stop_heartbeat "$ACTIVE_HEARTBEAT_PID"
    if [ ${#PARALLEL_WORKER_PIDS[@]} -gt 0 ]; then
        for pid in "${PARALLEL_WORKER_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
    fi
    PARALLEL_WORKER_PIDS=()

    if [ -n "$RUN_TEMP_DIR" ] && [ -d "$RUN_TEMP_DIR" ]; then
        case "$RUN_TEMP_DIR" in
            "$temp_root"/update-all-mac-run.*) rm -rf "$RUN_TEMP_DIR" ;;
        esac
    fi

    if [ "$LOCK_HELD" -eq 1 ]; then
        rm -rf "$LOCK_DIR"
        LOCK_HELD=0
    fi
}

handle_exit() {
    local rc=$?
    trap - EXIT INT TERM
    cleanup_runtime
    exit "$rc"
}

handle_interrupt() {
    local signal="$1"
    local rc=130

    [ "$signal" = "TERM" ] && rc=143
    trap - EXIT INT TERM
    cleanup_runtime
    exit "$rc"
}

install_runtime_traps() {
    trap 'handle_exit' EXIT
    trap 'handle_interrupt INT' INT
    trap 'handle_interrupt TERM' TERM
}

ensure_run_temp_dir() {
    local temp_root="${TMPDIR:-/tmp}"
    temp_root=${temp_root%/}

    if [ -n "$RUN_TEMP_DIR" ] && [ -d "$RUN_TEMP_DIR" ]; then
        return 0
    fi

    RUN_TEMP_DIR=$(mktemp -d "$temp_root/update-all-mac-run.XXXXXX" 2>/dev/null) || RUN_TEMP_DIR=""
    [ -n "$RUN_TEMP_DIR" ]
}

cleanup_stale_temp_artifacts() {
    local temp_root="${TMPDIR:-/tmp}"
    local path=""
    local current_uid=""

    [ "$DRY_RUN" -ne 1 ] || return 0
    [[ "$TEMP_MAX_AGE_MINUTES" =~ ^[1-9][0-9]*$ ]] || return 0
    temp_root=${temp_root%/}
    [ -d "$temp_root" ] || return 0
    current_uid=$(id -u)

    # Empty private run directories contain no recoverable diagnostics. Once
    # they are older than one minute, they cannot belong to this just-started
    # process and are safe to remove even before the general age threshold.
    while IFS= read -r -d '' path; do
        [ "$path" = "$RUN_TEMP_DIR" ] || rmdir "$path" 2>/dev/null || true
    done < <(find "$temp_root" -maxdepth 1 -type d -user "$current_uid" -name 'update-all-mac-run.*' -empty -mmin +1 -print0 2>/dev/null)

    while IFS= read -r -d '' path; do
        case "$path" in
            "$LOG_FILE" | "$LOG_FILE.1") continue ;;
        esac
        case "${path##*/}" in
            update-all-mac.*) rm -f "$path" ;;
        esac
    done < <(find "$temp_root" -maxdepth 1 -type f -user "$current_uid" -name 'update-all-mac.*' -mmin "+$TEMP_MAX_AGE_MINUTES" -print0 2>/dev/null)

    while IFS= read -r -d '' path; do
        case "${path##*/}" in
            update-all-mac-parallel.* | update-all-mac-run.*) rm -rf "$path" ;;
        esac
    done < <(find "$temp_root" -maxdepth 1 -type d -user "$current_uid" \( -name 'update-all-mac-parallel.*' -o -name 'update-all-mac-run.*' \) -mmin "+$TEMP_MAX_AGE_MINUTES" -print0 2>/dev/null)
}

setup_gui_password_prompt() {
    local helper=""

    [ "$DRY_RUN" -ne 1 ] || return 0
    step_selected_by_id "homebrew" || return 0
    [ -t 0 ] && [ -t 1 ] || return 0
    [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 0
    [ -x /usr/bin/osascript ] || return 0

    if [ -n "${SUDO_ASKPASS:-}" ]; then
        log "${BLUE}🔐 Administrator requests will use your configured password helper.${NC}"
        return 0
    fi

    if ! ensure_run_temp_dir; then
        log "${YELLOW}⚠️  Could not prepare the native password dialog; sudo may prompt in Terminal.${NC}"
        return 0
    fi

    helper="$RUN_TEMP_DIR/askpass"
    chmod 700 "$RUN_TEMP_DIR"
    # These variables intentionally expand later, inside the generated helper.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/bin/bash' \
        'message=${UPDATE_ALL_ASKPASS_CONTEXT:-"Homebrew needs administrator access. Your password is sent only to sudo and is not stored by update-all-mac."}' \
        'exec /usr/bin/osascript -e '\''on run argv'\'' -e '\''text returned of (display dialog (item 1 of argv) with title "update-all-mac · Homebrew" default answer "" with hidden answer buttons {"Cancel", "Authorize Homebrew"} default button "Authorize Homebrew" with icon note)'\'' -e '\''end run'\'' "$message"' \
        >"$helper"
    chmod 700 "$helper"
    export SUDO_ASKPASS="$helper"
    export UPDATE_ALL_ASKPASS_CONTEXT="Homebrew needs administrator access. Your password is sent only to sudo and is not stored by update-all-mac."
    log "${BLUE}🔐 Homebrew password dialogs will name the operation; update-all-mac never stores the password.${NC}"
}

set_password_context() {
    export UPDATE_ALL_ASKPASS_CONTEXT="$1"
}

acquire_lock() {
    local pid_file="$LOCK_DIR/pid"
    local pid=""

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$pid_file" 2>/dev/null || true
        LOCK_HELD=1
        return 0
    fi

    # Lock already exists — try to detect stale lock and recover.
    if [ -f "$pid_file" ]; then
        IFS= read -r pid <"$pid_file" || pid=""
    fi

    if [ -z "$pid" ] || ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
        log "${YELLOW}⚠️  Found a stale lock (${LOCK_DIR}); removing it and trying again...${NC}"
        rm -rf "$LOCK_DIR" 2>/dev/null || true

        if mkdir "$LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" >"$pid_file" 2>/dev/null || true
            LOCK_HELD=1
            return 0
        fi
    fi

    log "${RED}⚠️  Another run appears to be active (${LOCK_DIR}).${NC}"
    log "${YELLOW}   Wait for the previous run to finish, then try again.${NC}"
    return 1
}

# Print the banner that introduces a step.
step_header() {
    local step_num="$1"
    local total_steps="$2"
    local step_name="${STEP_NAMES[$3]}"

    log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "${BLUE}📦 $step_num/$total_steps $step_name${NC}"
    log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Translate a step return code into a tracked status and a summary line.
# Returns 0 for OK/WARN/SKIP and 1 for a hard failure.
step_status_from_rc() {
    local step_idx="$1"
    local rc="$2"
    local step_name="${STEP_NAMES[$step_idx]}"

    case "$rc" in
        "$STEP_OK")
            STEP_STATUS[step_idx]="${GREEN}✅${NC}"
            log "${GREEN}  ✅ $step_name completed${NC}"
            return 0
            ;;
        "$STEP_WARN")
            STEP_STATUS[step_idx]="${YELLOW}⚠️${NC}"
            log "${YELLOW}  ⚠️  $step_name completed with warnings${NC}"
            ANY_STEP_WARN=1
            return 0
            ;;
        "$STEP_SKIP")
            STEP_STATUS[step_idx]="${BLUE}⏭️${NC}"
            log "${BLUE}  ⏭️  $step_name skipped${NC}"
            return 0
            ;;
        *)
            STEP_STATUS[step_idx]="${RED}❌${NC}"
            log "${RED}  ❌ $step_name failed${NC}"
            return 1
            ;;
    esac
}

# Run a step live (header + body + status) and track its result.
run_step() {
    local step_num="$1"
    local total_steps="$2"
    local step_idx="$3"
    local step_func="${STEP_FUNCS[$step_idx]}"
    local rc=0

    step_header "$step_num" "$total_steps" "$step_idx"

    "$step_func"
    rc=$?

    step_status_from_rc "$step_idx" "$rc"
}

# Steps that touch independent ecosystems and never call brew, so they are safe
# to run concurrently with the heavy sequential steps.
step_is_parallelizable() {
    case "${STEP_IDS[$1]}" in
        npm | mas | pipx) return 0 ;;
        *) return 1 ;;
    esac
}

# Background worker for parallel mode: run a step with its output captured to a
# segment file and its return code written to a separate file. No terminal or
# shared-log writes happen here, so concurrent steps never interleave.
run_step_worker() {
    local step_idx="$1"
    local seg="$2"
    local logseg="$3"
    local rcfile="$4"
    local step_func="${STEP_FUNCS[$step_idx]}"

    (
        # Keep terminal presentation separate from the complete log transport.
        # This preserves compact output without losing command diagnostics.
        exec >"$seg" 2>&1
        exec 9>"$logseg"
        # The parent reports one heartbeat while it waits. Worker heartbeats
        # would be stale by the time their captured segments are replayed.
        HEARTBEAT_SECONDS=0
        "$step_func"
        printf '%s' "$?" >"$rcfile"
    )
}

# Replay a captured step segment (header + body) and apply its status.
emit_step_segment() {
    local step_num="$1"
    local total_steps="$2"
    local step_idx="$3"
    local seg="$4"
    local logseg="$5"
    local rc="$6"

    step_header "$step_num" "$total_steps" "$step_idx"
    if [ -s "$seg" ]; then
        filter_benign_noise <"$seg"
    fi
    if [ -s "$logseg" ]; then
        strip_ansi <"$logseg" | filter_benign_noise >&9
    fi
    step_status_from_rc "$step_idx" "$rc"
}

# Sequential scheduler: run every selected step live, in canonical order. Also
# the fallback when parallel mode cannot allocate its scratch directory.
run_steps_sequential() {
    local total_steps="$1"
    local step_num=1
    local step_idx=""

    for step_idx in "${RUN_STEP_INDEXES[@]}"; do
        if ! run_step "$step_num" "$total_steps" "$step_idx"; then
            ANY_STEP_FAILED=1
            if [ "$FAIL_FAST" -eq 1 ]; then
                break
            fi
        fi
        log ""
        step_num=$((step_num + 1))
    done
}

# Parallel scheduler: launch the parallelizable steps in the background, run the
# remaining steps live in canonical order, then replay the background results.
# Step numbers stay canonical; the parallel blocks appear after the live ones.
run_steps_parallel() {
    local total_steps="$1"
    local tmp_root=""
    local idx=""
    local seg=""
    local logseg=""
    local rcfile=""
    local rc=0
    local num=0
    local i=0
    local wait_heartbeat_pid=""
    local -a disp_num=()
    local -a bg_idx=()
    local -a bg_pid=()

    if ensure_run_temp_dir; then
        tmp_root=$(mktemp -d "$RUN_TEMP_DIR/parallel.XXXXXX" 2>/dev/null) || tmp_root=""
    fi
    if [ -z "$tmp_root" ]; then
        log "${YELLOW}⚠️  Could not create a temp dir for parallel mode; running steps sequentially.${NC}"
        run_steps_sequential "$total_steps"
        return
    fi

    num=1
    for idx in "${RUN_STEP_INDEXES[@]}"; do
        disp_num[idx]=$num
        num=$((num + 1))
    done

    # Launch parallelizable steps in the background.
    for idx in "${RUN_STEP_INDEXES[@]}"; do
        if step_is_parallelizable "$idx"; then
            seg="$tmp_root/seg.$idx"
            logseg="$tmp_root/log.$idx"
            rcfile="$tmp_root/rc.$idx"
            : >"$seg"
            : >"$logseg"
            printf '%s' "$STEP_FAIL" >"$rcfile"
            run_step_worker "$idx" "$seg" "$logseg" "$rcfile" &
            bg_idx+=("$idx")
            bg_pid+=("$!")
            PARALLEL_WORKER_PIDS+=("$!")
        fi
    done

    # Run the remaining steps live, in canonical order.
    for idx in "${RUN_STEP_INDEXES[@]}"; do
        if step_is_parallelizable "$idx"; then
            continue
        fi
        if ! run_step "${disp_num[idx]}" "$total_steps" "$idx"; then
            ANY_STEP_FAILED=1
            # In parallel mode --fail-fast only stops the live (sequential) steps;
            # the background batch is already running and is allowed to finish.
            if [ "$FAIL_FAST" -eq 1 ]; then
                break
            fi
        fi
        log ""
    done

    # Wait for the background batch to finish.
    if [ "${#bg_pid[@]}" -gt 0 ]; then
        start_heartbeat &
        wait_heartbeat_pid=$!
        ACTIVE_HEARTBEAT_PID="$wait_heartbeat_pid"
        for i in "${!bg_pid[@]}"; do
            wait "${bg_pid[$i]}" 2>/dev/null || true
        done
        stop_heartbeat "$wait_heartbeat_pid"
        PARALLEL_WORKER_PIDS=()
    fi

    # Replay background steps in canonical order.
    for idx in "${RUN_STEP_INDEXES[@]}"; do
        if ! step_is_parallelizable "$idx"; then
            continue
        fi
        seg="$tmp_root/seg.$idx"
        logseg="$tmp_root/log.$idx"
        rcfile="$tmp_root/rc.$idx"
        rc=$(cat "$rcfile" 2>/dev/null || printf '%s' "$STEP_FAIL")
        [[ "$rc" =~ ^[0-9]+$ ]] || rc="$STEP_FAIL"
        if ! emit_step_segment "${disp_num[idx]}" "$total_steps" "$idx" "$seg" "$logseg" "$rc"; then
            ANY_STEP_FAILED=1
        fi
        log ""
    done

    rm -rf "$tmp_root"
}

# Check for running GUI apps before cask upgrades
get_primary_cask_app_path() {
    local cask="$1"
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew info --cask "$cask" 2>/dev/null | awk '/^\/Applications\/.*\.app$/ {print; exit}'
}

cask_app_missing() {
    local cask="$1"
    local app_path=""

    app_path=$(get_primary_cask_app_path "$cask")
    [ -n "$app_path" ] && [ ! -e "$app_path" ]
}

# Print cask tokens whose on-disk version directory shows that Homebrew was
# interrupted during an upgrade. Homebrew does not report these through
# `brew outdated`, so they must be recovered before normal cask processing.
find_interrupted_casks() {
    local caskroom=""
    local version_dir=""
    local cask_dir=""

    caskroom=$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew --caskroom 2>/dev/null || true)
    [ -d "$caskroom" ] || return 0

    while IFS= read -r version_dir; do
        [ -n "$version_dir" ] || continue
        cask_dir=${version_dir%/*}
        printf '%s\n' "${cask_dir##*/}"
    done < <(find "$caskroom" -mindepth 2 -maxdepth 2 -type d -name '*.upgrading' -print 2>/dev/null)
}

# Remove only Homebrew's exact per-cask scratch directories after a successful
# reinstall. Keeping them would make every future run repeat the same repair.
remove_interrupted_cask_markers() {
    local cask="$1"
    local caskroom=""
    local marker=""

    case "$cask" in
        "" | .* | */*) return 1 ;;
    esac
    caskroom=$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew --caskroom 2>/dev/null || true)
    [ -d "$caskroom/$cask" ] || return 0

    while IFS= read -r -d '' marker; do
        rm -rf "$marker" || return 1
    done < <(find "$caskroom/$cask" -mindepth 1 -maxdepth 1 -type d -name '*.upgrading' -print0 2>/dev/null)
}

repair_cask() {
    local cask="$1"

    log "  → Repairing cask: $cask"
    if run_logged env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew reinstall --cask "$cask"; then
        if ! remove_interrupted_cask_markers "$cask"; then
            log "${YELLOW}  ⚠️  Cask was reinstalled, but its stale .upgrading directory could not be removed: $cask${NC}"
        fi
        return 0
    fi

    if [ "$BREW_FORCE_CASK_REPAIR" -ne 1 ]; then
        log "${YELLOW}  ⚠️  reinstall failed for $cask; forced removal is disabled${NC}"
        log "${YELLOW}     Use --force-cask-repair to enable the risky fallback${NC}"
        return 1
    fi

    log "${YELLOW}  ⚠️  reinstall failed for $cask; trying uninstall --force + install${NC}"
    run_logged env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew uninstall --cask --force "$cask" || true

    if run_logged env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew install --cask "$cask"; then
        if ! remove_interrupted_cask_markers "$cask"; then
            log "${YELLOW}  ⚠️  Cask was reinstalled, but its stale .upgrading directory could not be removed: $cask${NC}"
        fi
        return 0
    fi

    return 1
}

check_running_apps() {
    if ! command -v brew >/dev/null 2>&1; then
        return 0
    fi

    if [ "$#" -eq 0 ]; then
        return 0
    fi

    local running_apps=()
    local cask=""
    local app_path=""
    local app_name=""

    for cask in "$@"; do
        app_path=$(get_primary_cask_app_path "$cask")
        app_name="${app_path##*/}"
        app_name="${app_name%.app}"

        if [ -n "$app_name" ] && pgrep -x "$app_name" >/dev/null 2>&1; then
            running_apps+=("$app_name")
        fi
    done

    if [ ${#running_apps[@]} -gt 0 ]; then
        local app=""
        log ""
        log "${YELLOW}⚠️  Running apps were found and may be upgraded:${NC}"
        for app in "${running_apps[@]}"; do
            log "   → $app"
        done
        log "${YELLOW}   Close them before upgrading to avoid problems.${NC}"
        log ""
    fi
}

brew_update_catalog() {
    if brew help update-if-needed >/dev/null 2>&1; then
        run_logged env HOMEBREW_NO_ENV_HINTS=1 brew update-if-needed
    else
        run_logged env HOMEBREW_NO_ENV_HINTS=1 brew update
    fi
}

brew_formula_installed() {
    local formula="$1"

    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew list --formula "$formula" >/dev/null 2>&1
}

brew_cask_outdated() {
    local args=(--cask --quiet)

    if [ "$BREW_GREEDY_CASKS" -eq 1 ]; then
        args+=(--greedy)
    fi

    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew outdated "${args[@]}"
}

brew_cask_upgrade() {
    local recover_interrupted="$1"
    shift
    local args=(--cask)

    if [ "$BREW_GREEDY_CASKS" -eq 1 ] || [ "$recover_interrupted" -eq 1 ]; then
        args+=(--greedy)
    fi

    run_logged env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_ASK=1 brew upgrade "${args[@]}" "$@"
}

# === Homebrew update ===
update_homebrew() {
    if ! command -v brew >/dev/null 2>&1; then
        if [ "$INSTALL_HOMEBREW" -ne 1 ]; then
            log "${YELLOW}  → Homebrew is not installed; skipping${NC}"
            log "  ${YELLOW}→ Re-run with --install-homebrew to bootstrap it${NC}"
            return "$STEP_SKIP"
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            log "  ${BLUE}[dry-run] would install Homebrew${NC}"
            return "$STEP_SKIP"
        fi

        if ! command -v curl >/dev/null 2>&1; then
            log "${RED}  ⚠️  curl is required to install Homebrew${NC}"
            return "$STEP_FAIL"
        fi

        log "  → Homebrew is not installed; installing it..."
        if ! run_logged env NONINTERACTIVE=1 /bin/bash -c \
            "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
            log "${RED}  ⚠️  Homebrew installation failed${NC}"
            return "$STEP_FAIL"
        fi

        # Make the freshly installed brew usable for the rest of this run.
        setup_path
        eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null || true)"
        if ! command -v brew >/dev/null 2>&1; then
            log "${RED}  ⚠️  Homebrew installed but 'brew' is still not on PATH${NC}"
            return "$STEP_FAIL"
        fi
        log "  ${GREEN}→ Homebrew installed${NC}"
    fi

    local had_error=0
    local had_warn=0
    local line=""
    local cask=""
    local outdated_formulae_raw=""
    local outdated_casks_raw=""
    local pinned_packages_raw=""
    local remaining_casks_raw=""
    local final_casks_raw=""
    local remaining_interrupted_raw=""
    local recover_interrupted=0
    local already_retried=0
    local outdated_formulae=()
    local outdated_casks=()
    local upgradeable_formulae=()
    local upgradeable_casks=()
    local casks_to_upgrade=()
    local merged_casks=()
    local failed_casks=()
    local interrupted_casks=()

    log "  → Updating Homebrew metadata..."
    if [ "$DRY_RUN" -eq 1 ]; then
        log "  ${BLUE}[dry-run] skipping Homebrew catalog refresh${NC}"
    elif ! brew_update_catalog; then
        log "${RED}  ⚠️  Could not update Homebrew indexes${NC}"
        had_error=1
    fi

    while IFS= read -r cask; do
        [ -n "$cask" ] && interrupted_casks+=("$cask")
    done < <(find_interrupted_casks)

    if [ ${#interrupted_casks[@]} -gt 0 ]; then
        for cask in "${interrupted_casks[@]}"; do
            log "${YELLOW}  ⚠️  Interrupted Homebrew cask upgrade found: $cask${NC}"
        done
    fi

    log "  → Checking for outdated packages..."
    outdated_formulae_raw=$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew outdated --formula --quiet 2>/dev/null || true)
    outdated_casks_raw=$(brew_cask_outdated 2>/dev/null || true)
    pinned_packages_raw=$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew list --pinned 2>/dev/null || true)

    while IFS= read -r line; do
        [ -n "$line" ] && outdated_formulae+=("$line")
    done <<<"$outdated_formulae_raw"

    while IFS= read -r line; do
        [ -n "$line" ] && outdated_casks+=("$line")
    done <<<"$outdated_casks_raw"

    if [ ${#outdated_formulae[@]} -gt 0 ]; then
        for line in "${outdated_formulae[@]}"; do
            if printf '%s\n' "$pinned_packages_raw" | grep -Fxq "$line"; then
                log "  ${YELLOW}→ Skipping pinned formula: $line${NC}"
            else
                upgradeable_formulae+=("$line")
            fi
        done
    fi

    if [ ${#outdated_casks[@]} -gt 0 ]; then
        for cask in "${outdated_casks[@]}"; do
            if printf '%s\n' "$pinned_packages_raw" | grep -Fxq "$cask"; then
                log "  ${YELLOW}→ Skipping pinned cask: $cask${NC}"
            else
                upgradeable_casks+=("$cask")
            fi
        done
    fi

    # Put interrupted casks first, then merge the ordinary outdated set without
    # duplicates. One Homebrew process means one sudo timestamp reset and, in
    # the normal recovery path, a single password dialog for the whole batch.
    if [ ${#interrupted_casks[@]} -gt 0 ]; then
        for cask in "${interrupted_casks[@]}"; do
            merged_casks+=("$cask")
        done
    fi
    if [ ${#upgradeable_casks[@]} -gt 0 ]; then
        for cask in "${upgradeable_casks[@]}"; do
            if [ ${#merged_casks[@]} -eq 0 ] || ! printf '%s\n' "${merged_casks[@]}" | grep -Fxq "$cask"; then
                merged_casks+=("$cask")
            fi
        done
    fi
    upgradeable_casks=()
    if [ ${#merged_casks[@]} -gt 0 ]; then
        upgradeable_casks=("${merged_casks[@]}")
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        if [ ${#upgradeable_formulae[@]} -gt 0 ]; then
            log "  ${YELLOW}[dry-run] would upgrade ${#upgradeable_formulae[@]} formula(e):${NC}"
            for line in "${upgradeable_formulae[@]}"; do
                log_detail "$line"
            done
        else
            log "  ${GREEN}→ No unpinned outdated formulae to upgrade${NC}"
        fi
        if [ ${#upgradeable_casks[@]} -gt 0 ]; then
            log "  ${YELLOW}[dry-run] would upgrade ${#upgradeable_casks[@]} cask(s):${NC}"
            for cask in "${upgradeable_casks[@]}"; do
                log_detail "$cask"
            done
        else
            log "  ${GREEN}→ No unpinned outdated apps to upgrade${NC}"
        fi
        return "$STEP_OK"
    fi

    # Bash 3.2 (default on macOS) + `set -u`: empty "${arr[@]}" triggers "unbound variable".
    if [ ${#upgradeable_casks[@]} -gt 0 ]; then
        check_running_apps "${upgradeable_casks[@]}"
        log "  ${YELLOW}→ Unpinned outdated apps found: ${#upgradeable_casks[@]}${NC}"
        for cask in "${upgradeable_casks[@]}"; do
            log_detail "$cask"
        done

        casks_to_upgrade=("${upgradeable_casks[@]}")

        if [ ${#interrupted_casks[@]} -gt 0 ]; then
            recover_interrupted=1
            log "${BLUE}  🔐 One Homebrew password dialog may appear for the combined app batch.${NC}"
            log "${BLUE}     macOS may separately show an App Management notice when replacing apps.${NC}"
            set_password_context "Homebrew will recover ${#interrupted_casks[@]} interrupted app(s) and update ${#casks_to_upgrade[@]} app(s) in one operation. Your password is sent only to sudo and is not stored by update-all-mac."
        else
            set_password_context "Homebrew will update ${#casks_to_upgrade[@]} app(s) in /Applications. Your password is sent only to sudo and is not stored by update-all-mac."
        fi

        if [ ${#casks_to_upgrade[@]} -gt 0 ] && ! brew_cask_upgrade "$recover_interrupted" "${casks_to_upgrade[@]}"; then
            log "${YELLOW}  ⚠️  Some casks did not upgrade. Trying to repair the failed casks...${NC}"

            remaining_casks_raw=$(brew_cask_outdated 2>/dev/null || true)
            remaining_interrupted_raw=$(find_interrupted_casks)

            for cask in "${casks_to_upgrade[@]}"; do
                if printf '%s\n' "$remaining_casks_raw" | grep -Fxq "$cask" \
                    || printf '%s\n' "$remaining_interrupted_raw" | grep -Fxq "$cask" \
                    || cask_app_missing "$cask"; then
                    failed_casks+=("$cask")
                fi
            done

            if [ ${#failed_casks[@]} -gt 0 ]; then
                for cask in "${failed_casks[@]}"; do
                    log "${YELLOW}  🔐 Homebrew is retrying $cask separately; one additional password dialog may appear.${NC}"
                    set_password_context "The combined Homebrew update could not finish $cask. Homebrew is retrying this app separately, so this is an additional recovery request. Your password is sent only to sudo and is not stored by update-all-mac."
                    if ! repair_cask "$cask"; then
                        log "${RED}  ⚠️  Could not repair cask: $cask${NC}"
                        had_error=1
                    fi
                done
            fi
        fi

        # A command can exit successfully while an auto-updating cask remains
        # in its interrupted marker. Retry only those exceptional cases.
        if [ ${#interrupted_casks[@]} -gt 0 ]; then
            remaining_interrupted_raw=$(find_interrupted_casks)
            for cask in "${interrupted_casks[@]}"; do
                already_retried=0
                if [ ${#failed_casks[@]} -gt 0 ] && printf '%s\n' "${failed_casks[@]}" | grep -Fxq "$cask"; then
                    already_retried=1
                fi
                if printf '%s\n' "$remaining_interrupted_raw" | grep -Fxq "$cask" \
                    && [ "$already_retried" -eq 0 ]; then
                    log "${YELLOW}  🔐 Combined recovery left $cask interrupted; one additional password dialog may appear.${NC}"
                    set_password_context "Homebrew left $cask interrupted after the combined update. It is retrying this app separately. Your password is sent only to sudo and is not stored by update-all-mac."
                    if ! repair_cask "$cask"; then
                        log "${RED}  ⚠️  Could not recover interrupted cask: $cask${NC}"
                        had_error=1
                    fi
                fi
            done
        fi

        final_casks_raw=$(brew_cask_outdated 2>/dev/null || true)
        for cask in "${upgradeable_casks[@]}"; do
            if printf '%s\n' "$final_casks_raw" | grep -Fxq "$cask"; then
                log "${RED}  ⚠️  Cask is still outdated after upgrade attempt: $cask${NC}"
                had_error=1
            fi
        done
    else
        log "  ${GREEN}→ No unpinned outdated apps to upgrade${NC}"
    fi

    if [ ${#upgradeable_formulae[@]} -gt 0 ]; then
        log "  ${YELLOW}→ Unpinned outdated formulae found: ${#upgradeable_formulae[@]}${NC}"
        for line in "${upgradeable_formulae[@]}"; do
            log_detail "$line"
        done
        if ! run_logged env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew upgrade --formula "${upgradeable_formulae[@]}"; then
            log "${RED}  ⚠️  Error while upgrading formulae${NC}"
            had_error=1
        fi
    else
        log "  ${GREEN}→ No unpinned outdated formulae to upgrade${NC}"
    fi

    if [ "$had_error" -ne 0 ]; then
        return "$STEP_FAIL"
    fi

    if [ "$had_warn" -ne 0 ]; then
        return "$STEP_WARN"
    fi

    return "$STEP_OK"
}

# True when npm output contains an actual error line (network/registry), as
# opposed to a normal "outdated packages" table. `npm outdated` exits 1 in both
# cases, so the exit code alone cannot tell them apart.
npm_output_has_error() {
    printf '%s\n' "$1" | grep -qiE '^[[:space:]]*npm (error|err!)'
}

# === npm update ===
update_npm() {
    if ! command -v npm >/dev/null 2>&1; then
        log "${YELLOW}  → npm is not installed; skipping${NC}"
        return "$STEP_SKIP"
    fi

    local outdated_output=""
    local outdated_exit=0
    local leftover=""
    local had_warn=0
    local rc=0
    local npm_net=(--fetch-retries=2 --fetch-timeout=60000)

    log "  → Checking for outdated packages..."
    outdated_output=$(npm outdated -g --depth=0 "${npm_net[@]}" 2>&1)
    outdated_exit=$?

    # A failed check (network/registry) must not be mistaken for "updates
    # available" — otherwise a blind `npm update -g` runs against a broken
    # connection (and may hang).
    if npm_output_has_error "$outdated_output" || [ "$outdated_exit" -gt 1 ]; then
        log "${RED}  ⚠️  Could not check global npm packages (network or registry error)${NC}"
        log "$outdated_output"
        return "$STEP_FAIL"
    fi

    if [ "$outdated_exit" -eq 0 ] || [ -z "$outdated_output" ]; then
        log "  ${GREEN}→ Global npm packages are up to date${NC}"
        return "$STEP_OK"
    fi

    log_detail "$outdated_output"

    if [ "$DRY_RUN" -eq 1 ]; then
        log "  ${BLUE}[dry-run] would run: npm update -g${NC}"
        return "$STEP_OK"
    fi

    log "  → Upgrading..."

    run_logged with_timeout "$NET_TIMEOUT" npm update -g "${npm_net[@]}"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 124 ]; then
            log "${RED}  ⚠️  npm update timed out after ${NET_TIMEOUT}s${NC}"
        else
            log "${RED}  ⚠️  npm update failed${NC}"
        fi
        return "$STEP_FAIL"
    fi

    # Verify the upgrade actually cleared the outdated packages (e.g. a global
    # left behind on an older major). Mirrors the Homebrew cask re-check.
    leftover=$(npm outdated -g --depth=0 "${npm_net[@]}" 2>&1)
    if ! npm_output_has_error "$leftover" && [ -n "$leftover" ]; then
        log "${YELLOW}  ⚠️  Some global npm packages are still outdated after upgrade:${NC}"
        log "$leftover"
        had_warn=1
    fi

    if [ "$had_warn" -ne 0 ]; then
        return "$STEP_WARN"
    fi

    return "$STEP_OK"
}

# === Mac App Store update ===
update_mas() {
    if ! command -v mas >/dev/null 2>&1; then
        log "${YELLOW}  → mas is not installed; skipping${NC}"
        log "  ${YELLOW}→ Install it with: brew install mas${NC}"
        return "$STEP_SKIP"
    fi

    local accuracy_arg="--inaccurate"
    local outdated_output=""

    if [ "$MAS_ACCURATE" -eq 1 ]; then
        accuracy_arg="--accurate"
    fi

    log "  → Checking for updates..."
    if ! outdated_output=$(mas outdated "$accuracy_arg" 2>&1); then
        log "${RED}  ⚠️  Could not get the Mac App Store update list${NC}"
        log "  → $outdated_output"
        log "${YELLOW}     mas uses Spotlight; check App Store app indexing if this error repeats${NC}"
        return "$STEP_FAIL"
    fi

    if [ -z "$outdated_output" ]; then
        log "  ${GREEN}→ No Mac App Store updates found${NC}"
        return "$STEP_OK"
    fi

    log_detail "$outdated_output"

    if [ "$DRY_RUN" -eq 1 ]; then
        log "  ${BLUE}[dry-run] would run: mas upgrade${NC}"
        return "$STEP_OK"
    fi

    log "  → Upgrading..."

    if run_logged mas update "$accuracy_arg"; then
        return "$STEP_OK"
    fi

    # Fallback for older mas versions/aliases.
    if run_logged mas upgrade "$accuracy_arg"; then
        return "$STEP_OK"
    fi

    log "${RED}  ⚠️  Could not update Mac App Store apps${NC}"
    return "$STEP_FAIL"
}

# === Oh My Zsh update ===
update_ohmyzsh() {
    local zsh_root="$HOME/.oh-my-zsh"

    if [ ! -d "$zsh_root" ]; then
        log "  ${YELLOW}→ Oh My Zsh is not installed; skipping${NC}"
        return "$STEP_SKIP"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "  ${BLUE}[dry-run] would update Oh My Zsh${NC}"
        return "$STEP_OK"
    fi

    if [ -x "$zsh_root/tools/upgrade.sh" ]; then
        log "  → Updating with bundled upgrade.sh..."
        if ! run_logged env ZSH="$zsh_root" DISABLE_UPDATE_PROMPT=true "$zsh_root/tools/upgrade.sh" -v silent; then
            log "${RED}  ⚠️  Oh My Zsh update failed${NC}"
            return "$STEP_FAIL"
        fi
        return "$STEP_OK"
    fi

    log "  → tools/upgrade.sh not found; using git pull..."
    if ! run_logged git -C "$zsh_root" pull --ff-only; then
        log "${RED}  ⚠️  Oh My Zsh update through git failed${NC}"
        return "$STEP_FAIL"
    fi

    return "$STEP_OK"
}

# === pip check ===
check_pip() {
    local pip_version=""

    if command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
        pip_version=$(python3 -m pip --version | awk '{print $2}')
    elif command -v pip3 >/dev/null 2>&1; then
        pip_version=$(pip3 --version | awk '{print $2}')
    else
        log "${YELLOW}  → pip3 is not installed; skipping${NC}"
        return "$STEP_SKIP"
    fi

    log "  → pip version: $pip_version"
    log "  ${GREEN}→ Update pip together with the Python installation you use${NC}"

    return "$STEP_OK"
}

# === pipx update ===
update_pipx() {
    if ! command -v pipx >/dev/null 2>&1; then
        log "  ${YELLOW}→ pipx is not installed; skipping${NC}"
        return "$STEP_SKIP"
    fi

    local args=(upgrade-all)
    local had_warn=0

    if [ "$PIPX_INCLUDE_INJECTED" -eq 1 ] && pipx upgrade-all --help 2>/dev/null | grep -q -- '--include-injected'; then
        args+=(--include-injected)
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "  ${BLUE}[dry-run] would run: pipx ${args[*]}${NC}"
        return "$STEP_OK"
    fi

    if ! run_logged pipx "${args[@]}"; then
        log "${RED}  ⚠️  pipx package update failed${NC}"
        return 1
    fi

    if pipx upgrade-shared --help >/dev/null 2>&1; then
        log "  → Updating shared pipx libraries..."
        if ! run_logged pipx upgrade-shared; then
            log "${YELLOW}  ⚠️  pipx upgrade-shared completed with warnings${NC}"
            had_warn=1
        fi
    fi

    if [ "$had_warn" -ne 0 ]; then
        return "$STEP_WARN"
    fi

    return "$STEP_OK"
}

# === uv update ===
update_uv() {
    if ! command -v uv >/dev/null 2>&1; then
        log "  ${YELLOW}→ uv is not installed; skipping${NC}"
        return "$STEP_SKIP"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "  ${BLUE}[dry-run] would update uv and its installed tools${NC}"
        return "$STEP_OK"
    fi

    local had_warn=0
    local uv_output=""
    local uv_exit=0
    local brew_outdated_output=""
    local brew_outdated_exit=0

    # If uv is installed through Homebrew, use Homebrew for the binary and
    # still update uv tools separately.
    if command -v brew >/dev/null 2>&1 && brew_formula_installed "uv"; then
        if step_selected_by_id "homebrew"; then
            log "  ${GREEN}→ uv is installed through Homebrew; the binary is upgraded by the Homebrew step${NC}"
        else
            log "  → uv is installed through Homebrew; updating the uv formula..."
            if ! brew_update_catalog; then
                log "${RED}  ⚠️  Could not update Homebrew indexes for uv${NC}"
                return 1
            fi

            brew_outdated_output=$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew outdated --formula --quiet uv 2>&1)
            brew_outdated_exit=$?
            if [ "$brew_outdated_exit" -ne 0 ]; then
                log "${RED}  ⚠️  Could not check the Homebrew uv formula${NC}"
                log "  → $brew_outdated_output"
                return 1
            fi

            if printf '%s\n' "$brew_outdated_output" | grep -Fxq "uv"; then
                if ! run_logged env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew upgrade --formula uv; then
                    log "${RED}  ⚠️  Could not update uv through Homebrew${NC}"
                    return 1
                fi
            else
                log "  ${GREEN}→ Homebrew uv formula is up to date${NC}"
            fi
        fi
    else
        uv_output=$(uv self update 2>&1)
        uv_exit=$?

        if [ "$uv_exit" -eq 0 ]; then
            [ -n "$uv_output" ] && log "$uv_output"
        elif printf '%s\n' "$uv_output" | grep -Eiq 'self[- ]?update.*disabled|package manager|managed by'; then
            log "  ${YELLOW}→ uv self update is unavailable for this installation type${NC}"
            log "  ${YELLOW}→ Update uv with the package manager that installed it${NC}"
            had_warn=1
        else
            log "${RED}  ⚠️  Could not update uv${NC}"
            log "  → $uv_output"
            return 1
        fi
    fi

    if uv tool upgrade --help 2>/dev/null | grep -q -- '--all'; then
        log "  → Updating uv tools..."
        if ! run_logged uv tool upgrade --all; then
            log "${RED}  ⚠️  uv tools update failed${NC}"
            return 1
        fi
    else
        log "${YELLOW}  → This uv version does not support uv tool upgrade --all${NC}"
        had_warn=1
    fi

    if [ "$had_warn" -ne 0 ]; then
        return "$STEP_WARN"
    fi

    return "$STEP_OK"
}

# === Rust (rustup + cargo) update ===
update_rust() {
    if ! command -v rustup >/dev/null 2>&1 && ! command -v cargo >/dev/null 2>&1; then
        log "  ${YELLOW}→ rustup/cargo are not installed; skipping${NC}"
        return "$STEP_SKIP"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "  ${BLUE}[dry-run] would run: rustup update / cargo install-update -a${NC}"
        return "$STEP_OK"
    fi

    local had_warn=0

    if command -v rustup >/dev/null 2>&1; then
        log "  → Updating Rust toolchains..."
        if ! run_logged rustup update; then
            log "${RED}  ⚠️  rustup update failed${NC}"
            return "$STEP_FAIL"
        fi
    fi

    # `cargo install-update` (from the cargo-update crate) upgrades globally
    # installed crates; it is optional, so only run it when present.
    if command -v cargo >/dev/null 2>&1 && command -v cargo-install-update >/dev/null 2>&1; then
        log "  → Updating cargo-installed crates..."
        if ! run_logged cargo install-update -a; then
            log "${YELLOW}  ⚠️  cargo install-update completed with warnings${NC}"
            had_warn=1
        fi
    fi

    if [ "$had_warn" -ne 0 ]; then
        return "$STEP_WARN"
    fi

    return "$STEP_OK"
}

# === mise update ===
update_mise() {
    if ! command -v mise >/dev/null 2>&1; then
        log "  ${YELLOW}→ mise is not installed; skipping${NC}"
        return "$STEP_SKIP"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "  ${BLUE}[dry-run] would run: mise upgrade${NC}"
        return "$STEP_OK"
    fi

    log "  → Upgrading mise-managed tools..."
    if ! run_logged mise upgrade; then
        log "${RED}  ⚠️  mise upgrade failed${NC}"
        return "$STEP_FAIL"
    fi

    return "$STEP_OK"
}

# === asdf update ===
update_asdf() {
    if ! command -v asdf >/dev/null 2>&1; then
        log "  ${YELLOW}→ asdf is not installed; skipping${NC}"
        return "$STEP_SKIP"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "  ${BLUE}[dry-run] would run: asdf plugin update --all${NC}"
        return "$STEP_OK"
    fi

    # Refresh plugin definitions. Bumping installed tool versions is left to the
    # user, since asdf has no safe "upgrade everything to latest" operation.
    log "  → Updating asdf plugins..."
    if ! run_logged asdf plugin update --all; then
        log "${YELLOW}  ⚠️  asdf plugin update completed with warnings${NC}"
        return "$STEP_WARN"
    fi

    return "$STEP_OK"
}

# === gcloud components update ===
update_gcloud() {
    if ! command -v gcloud >/dev/null 2>&1; then
        log "  ${YELLOW}→ gcloud is not installed; skipping${NC}"
        return "$STEP_SKIP"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "  ${BLUE}[dry-run] would run: gcloud components update${NC}"
        return "$STEP_OK"
    fi

    local output=""
    local rc=0

    log "  → Updating gcloud components..."
    output=$(gcloud components update --quiet 2>&1)
    rc=$?
    [ -n "$output" ] && log "$output"

    if [ "$rc" -eq 0 ]; then
        return "$STEP_OK"
    fi

    # Homebrew (and some managed) installs disable the component manager.
    if printf '%s\n' "$output" | grep -qiE 'component manager is disabled|managed by|cannot perform this action'; then
        log "  ${YELLOW}→ gcloud components are managed by your installer; skipping${NC}"
        return "$STEP_SKIP"
    fi

    log "${RED}  ⚠️  gcloud components update failed${NC}"
    return "$STEP_FAIL"
}

# === Safe cache cleanup ===
run_cleanup() {
    local had_warn=0
    local brew_cleanup_ok=0
    local brew_cleanup_help=""
    local npm_cache_help=""

    if [ "$DRY_RUN" -eq 1 ]; then
        if [ "$DEEP_CLEAN" -eq 1 ]; then
            log "  ${BLUE}[dry-run] would run deep cache cleanup${NC}"
        else
            log "  ${BLUE}[dry-run] would run safe cache cleanup${NC}"
        fi
        return "$STEP_OK"
    fi

    if command -v brew >/dev/null 2>&1; then
        brew_cleanup_help=$(brew cleanup --help 2>/dev/null || true)
        if [ "$DEEP_CLEAN" -eq 1 ] && grep -q -- '--prune' <<<"$brew_cleanup_help"; then
            log "  → Purging Homebrew download caches..."
            if run_logged env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew cleanup --prune=all; then brew_cleanup_ok=1; else had_warn=1; fi
        elif grep -q -- '--scrub' <<<"$brew_cleanup_help"; then
            log "  → Removing stale Homebrew downloads and old versions..."
            if run_logged env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew cleanup --scrub; then brew_cleanup_ok=1; else had_warn=1; fi
        else
            log "  → Removing old Homebrew versions..."
            if run_logged env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew cleanup; then brew_cleanup_ok=1; else had_warn=1; fi
        fi
        if [ "$brew_cleanup_ok" -eq 1 ] && [ -n "$LAST_COMMAND_RECLAIMED" ]; then
            log "  ${GREEN}→ Freed approximately $LAST_COMMAND_RECLAIMED${NC}"
        fi
    fi

    if command -v npm >/dev/null 2>&1; then
        npm_cache_help=$(npm cache --help 2>/dev/null || true)
    fi
    if [ -n "$npm_cache_help" ] && grep -q -- 'verify' <<<"$npm_cache_help"; then
        if [ "$DEEP_CLEAN" -eq 1 ]; then
            log "  → Purging the npm cache..."
            run_logged npm cache clean --force || had_warn=1
        else
            log "  → Verifying and compacting the npm cache..."
            run_logged npm cache verify || had_warn=1
        fi
    fi

    if command -v uv >/dev/null 2>&1; then
        if [ "$DEEP_CLEAN" -eq 1 ] && uv cache clean --help >/dev/null 2>&1; then
            log "  → Purging the uv cache..."
            run_logged uv cache clean || had_warn=1
        elif uv cache prune --help >/dev/null 2>&1; then
            log "  → Pruning unused uv cache entries..."
            run_logged uv cache prune || had_warn=1
        fi
    fi

    if [ "$DEEP_CLEAN" -eq 1 ]; then
        if command -v python3 >/dev/null 2>&1 && python3 -m pip cache purge --help >/dev/null 2>&1; then
            log "  → Purging the pip cache..."
            run_logged python3 -m pip cache purge || had_warn=1
        fi

        if command -v pipx >/dev/null 2>&1 && pipx cache purge --help >/dev/null 2>&1; then
            log "  → Purging cached pipx run environments..."
            run_logged pipx cache purge || had_warn=1
        fi
    fi

    if [ "$had_warn" -ne 0 ]; then
        log "${YELLOW}  ⚠️  Some optional cleanup operations did not complete${NC}"
        return "$STEP_WARN"
    fi

    return "$STEP_OK"
}

# === macOS update check ===
check_macos_updates() {
    if ! command -v softwareupdate >/dev/null 2>&1; then
        log "  ${YELLOW}→ softwareupdate was not found; skipping${NC}"
        return "$STEP_SKIP"
    fi

    local output=""
    local rc=0

    log "  → Checking for macOS updates..."
    output=$(softwareupdate -l 2>&1)
    rc=$?

    [ -n "$output" ] && log "$output"

    if [ "$rc" -eq 0 ]; then
        return "$STEP_OK"
    fi

    log "${YELLOW}  ⚠️  softwareupdate completed with warnings${NC}"
    return "$STEP_WARN"
}

# === Print final summary ===
print_summary() {
    local finish_date=""
    local elapsed=0
    local minutes=0
    local seconds=0
    local i=0

    finish_date=$(date '+%Y-%m-%d %H:%M:%S')
    elapsed=$(($(date +%s) - START_EPOCH))
    minutes=$((elapsed / 60))
    seconds=$((elapsed % 60))

    log ""
    log "${GREEN}╔════════════════════════════════════════════════╗${NC}"
    log "${GREEN}║          🎉 UPDATE COMPLETE!            ║${NC}"
    log "${GREEN}╚════════════════════════════════════════════════╝${NC}"
    log ""

    log "${BLUE}📊 Run status:${NC}"
    for i in "${!STEP_NAMES[@]}"; do
        log "   ${STEP_STATUS[$i]} ${STEP_NAMES[$i]}"
    done
    log ""

    log "${BLUE}⏱️  Elapsed time: ${minutes}m ${seconds}s${NC}"
    log "${BLUE}🕓 Finished at: $finish_date${NC}"
    log ""

    if command -v brew >/dev/null 2>&1 && [ "${STEP_SELECTED[0]}" = "1" ]; then
        log "${BLUE}📦 Currently installed apps:${NC}"
        log "   → Homebrew casks: $(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew list --cask 2>/dev/null | wc -l | xargs)"
        log "   → Homebrew formulae: $(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew list --formula 2>/dev/null | wc -l | xargs)"
        if command -v mas >/dev/null 2>&1 && [ "${STEP_SELECTED[2]}" = "1" ]; then
            log "   → MAS apps: $(mas list 2>/dev/null | wc -l | xargs)"
        fi
        log ""
    fi

    log "${BLUE}📝 Logs saved to: $LOG_FILE${NC}"
    log ""

    if [ "$ENABLE_MACOS_STEP" -ne 1 ]; then
        log "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        log "${YELLOW}⚠️  macOS system updates${NC}"
        log "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        log "Want to check for macOS updates?"
        log "Run manually: ${BLUE}softwareupdate -l${NC}"
        log ""
    fi
}

# === MAIN ===
setup_path

if [ -t 1 ]; then
    clear
fi

parse_args "$@"
apply_color_settings
maybe_enable_macos_step
if [ "$SHOW_HELP" -eq 1 ]; then
    usage
    exit 0
fi

if [ "$LIST_STEPS" -eq 1 ]; then
    print_steps
    exit 0
fi

if [ "$DOCTOR" -eq 1 ]; then
    print_doctor
    exit 0
fi
init_step_selection

validate_lock_dir
init_logging
init_step_tracking
install_runtime_traps

if ! acquire_lock; then
    exit 1
fi

cleanup_stale_temp_artifacts

log "${BLUE}╔════════════════════════════════════════════════╗${NC}"
log "${BLUE}║   🔄 UPDATE ALL APPS AND PACKAGES    ║${NC}"
log "${BLUE}╚════════════════════════════════════════════════╝${NC}"
log ""
log "${YELLOW}Started at: $DATE${NC}"
log ""

if [ "$DRY_RUN" -eq 1 ]; then
    log "${YELLOW}🧪 DRY RUN — no changes will be made${NC}"
    log ""
fi

setup_gui_password_prompt
log ""

run_total=${#RUN_STEP_INDEXES[@]}
ANY_STEP_FAILED=0
ANY_STEP_WARN=0

if [ "$PARALLEL" -eq 1 ]; then
    run_steps_parallel "$run_total"
else
    run_steps_sequential "$run_total"
fi

print_summary

if [ "${UPDATE_ALL_NO_PAUSE:-0}" != "1" ] && [ -t 0 ]; then
    log "${GREEN}✨ Finished. Press any key to exit...${NC}"
    read -r -n 1 -s
fi

if [ "$EXIT_ZERO" -eq 1 ]; then
    exit 0
fi

if [ "$STRICT" -eq 1 ]; then
    if [ "$ANY_STEP_FAILED" -ne 0 ] || [ "$ANY_STEP_WARN" -ne 0 ]; then
        exit 1
    fi
else
    if [ "$ANY_STEP_FAILED" -ne 0 ]; then
        exit 1
    fi
fi
