#!/bin/bash

# Full macOS app and package updater
# Run by double-clicking in Finder or from Terminal
# Author: MZored
# Date: 2026-04-30
# Version: 3.1.1

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
DATE=$(date '+%Y-%m-%d %H:%M:%S')
START_EPOCH=$(date +%s)
LOCK_DIR="${UPDATE_ALL_LOCK_DIR:-/tmp/update-all-mac.lock}"

STEP_IDS=("homebrew" "npm" "mas" "ohmyzsh" "pip" "pipx" "uv")
STEP_NAMES=("Homebrew" "npm" "Mac App Store" "Oh My Zsh" "pip" "pipx" "uv")
STEP_FUNCS=("update_homebrew" "update_npm" "update_mas" "update_ohmyzsh" "check_pip" "update_pipx" "update_uv")
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
  --log-file <path>      Override log file path
  --lock-dir <path>      Override lock directory path
  --list-steps           Print available step IDs and exit
  -h, --help             Show this help and exit

Step IDs:
$(print_steps | sed 's/^/  /')
EOF
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
            --list-steps)
                LIST_STEPS=1
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

# Logging helper
log() {
    local message="$1"
    printf '%s\n' "$message"
    printf '%s\n' "$message" | sed -E $'s/\x1B\\[[0-9;]*[mK]//g' >>"$LOG_FILE"
}

init_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '\n==== [%s] Update run started ====\n' "$DATE" >>"$LOG_FILE"
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

acquire_lock() {
    local pid_file="$LOCK_DIR/pid"
    local pid=""

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$pid_file" 2>/dev/null || true
        trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
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
            trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
            return 0
        fi
    fi

    log "${RED}⚠️  Another run appears to be active (${LOCK_DIR}).${NC}"
    log "${YELLOW}   Wait for the previous run to finish, then try again.${NC}"
    return 1
}

# Run a step and track its status
run_step() {
    local step_num="$1"
    local total_steps="$2"
    local step_idx="$3"
    local step_func="${STEP_FUNCS[$step_idx]}"
    local step_name="${STEP_NAMES[$step_idx]}"

    log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "${BLUE}📦 $step_num/$total_steps $step_name${NC}"
    log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    "$step_func"
    local rc=$?

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

repair_cask() {
    local cask="$1"

    log "  → Repairing cask: $cask"
    if HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew reinstall --cask "$cask"; then
        return 0
    fi

    if [ "$BREW_FORCE_CASK_REPAIR" -ne 1 ]; then
        log "${YELLOW}  ⚠️  reinstall failed for $cask; forced removal is disabled${NC}"
        log "${YELLOW}     Use --force-cask-repair to enable the risky fallback${NC}"
        return 1
    fi

    log "${YELLOW}  ⚠️  reinstall failed for $cask; trying uninstall --force + install${NC}"
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew uninstall --cask --force "$cask" >/dev/null 2>&1 || true

    if HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew install --cask "$cask"; then
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
        HOMEBREW_NO_ENV_HINTS=1 brew update-if-needed
    else
        HOMEBREW_NO_ENV_HINTS=1 brew update
    fi
}

brew_cask_outdated() {
    local args=(--cask --quiet)

    if [ "$BREW_GREEDY_CASKS" -eq 1 ]; then
        args+=(--greedy)
    fi

    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew outdated "${args[@]}"
}

brew_cask_upgrade() {
    local args=(--cask)

    if [ "$BREW_GREEDY_CASKS" -eq 1 ]; then
        args+=(--greedy)
    fi

    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew upgrade "${args[@]}" "$@"
}

# === Homebrew update ===
update_homebrew() {
    if ! command -v brew >/dev/null 2>&1; then
        log "${YELLOW}  → Homebrew is not installed; skipping${NC}"
        return "$STEP_SKIP"
    fi

    local had_error=0
    local had_warn=0
    local line=""
    local cask=""
    local outdated_formulae_raw=""
    local outdated_casks_raw=""
    local remaining_casks_raw=""
    local final_casks_raw=""
    local app_path=""
    local outdated_formulae=()
    local outdated_casks=()
    local casks_to_upgrade=()
    local pre_repair_casks=()
    local failed_casks=()

    log "  → Updating Homebrew metadata..."
    if ! brew_update_catalog; then
        log "${RED}  ⚠️  Could not update Homebrew indexes${NC}"
        had_error=1
    fi

    log "  → Checking for outdated packages..."
    outdated_formulae_raw=$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew outdated --formula --quiet 2>/dev/null || true)
    outdated_casks_raw=$(brew_cask_outdated 2>/dev/null || true)

    while IFS= read -r line; do
        [ -n "$line" ] && outdated_formulae+=("$line")
    done <<<"$outdated_formulae_raw"

    while IFS= read -r line; do
        [ -n "$line" ] && outdated_casks+=("$line")
    done <<<"$outdated_casks_raw"

    if [ ${#outdated_formulae[@]} -gt 0 ]; then
        log "  ${YELLOW}→ Outdated formulae found: ${#outdated_formulae[@]}${NC}"
        if ! HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew upgrade --formula "${outdated_formulae[@]}"; then
            log "${RED}  ⚠️  Error while upgrading formulae${NC}"
            had_error=1
        fi
    else
        log "  ${GREEN}→ All formulae are up to date${NC}"
    fi

    # Bash 3.2 (default on macOS) + `set -u`: empty "${arr[@]}" triggers "unbound variable".
    if [ ${#outdated_casks[@]} -gt 0 ]; then
        check_running_apps "${outdated_casks[@]}"
        log "  ${YELLOW}→ Outdated apps found: ${#outdated_casks[@]}${NC}"

        for cask in "${outdated_casks[@]}"; do
            app_path=$(get_primary_cask_app_path "$cask")
            if [ -n "$app_path" ] && [ ! -e "$app_path" ]; then
                pre_repair_casks+=("$cask")
            else
                casks_to_upgrade+=("$cask")
            fi
        done

        if [ ${#pre_repair_casks[@]} -gt 0 ]; then
            log "${YELLOW}  ⚠️  Some casks have a missing .app in /Applications. Repairing before upgrade...${NC}"
            for cask in "${pre_repair_casks[@]}"; do
                if ! repair_cask "$cask"; then
                    log "${RED}  ⚠️  Could not repair cask: $cask${NC}"
                    had_error=1
                fi
            done
        fi

        if [ ${#casks_to_upgrade[@]} -gt 0 ] && ! brew_cask_upgrade "${casks_to_upgrade[@]}"; then
            log "${YELLOW}  ⚠️  Some casks did not upgrade. Trying to repair the failed casks...${NC}"

            remaining_casks_raw=$(brew_cask_outdated 2>/dev/null || true)

            for cask in "${casks_to_upgrade[@]}"; do
                if printf '%s\n' "$remaining_casks_raw" | grep -Fxq "$cask" || cask_app_missing "$cask"; then
                    failed_casks+=("$cask")
                fi
            done

            if [ ${#failed_casks[@]} -gt 0 ]; then
                for cask in "${failed_casks[@]}"; do
                    if ! repair_cask "$cask"; then
                        log "${RED}  ⚠️  Could not repair cask: $cask${NC}"
                        had_error=1
                    fi
                done
            fi
        fi

        final_casks_raw=$(brew_cask_outdated 2>/dev/null || true)
        for cask in "${outdated_casks[@]}"; do
            if printf '%s\n' "$final_casks_raw" | grep -Fxq "$cask"; then
                log "${RED}  ⚠️  Cask is still outdated after upgrade attempt: $cask${NC}"
                had_error=1
            fi
        done
    else
        log "  ${GREEN}→ All apps are up to date${NC}"
    fi

    log "  → Cleaning cache..."
    if ! HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew cleanup; then
        log "${YELLOW}  ⚠️  Homebrew cleanup completed with warnings${NC}"
        had_warn=1
    fi

    if [ "$had_error" -ne 0 ]; then
        return "$STEP_FAIL"
    fi

    if [ "$had_warn" -ne 0 ]; then
        return "$STEP_WARN"
    fi

    return "$STEP_OK"
}

# === npm update ===
update_npm() {
    if ! command -v npm >/dev/null 2>&1; then
        log "${YELLOW}  → npm is not installed; skipping${NC}"
        return "$STEP_SKIP"
    fi

    local outdated_output=""
    local outdated_exit=0

    log "  → Checking for outdated packages..."
    outdated_output=$(npm outdated -g --depth=0 2>&1)
    outdated_exit=$?

    if [ "$outdated_exit" -gt 1 ]; then
        log "${RED}  ⚠️  Could not check global npm packages${NC}"
        log "  → $outdated_output"
        return 1
    fi

    if [ "$outdated_exit" -eq 0 ] || [ -z "$outdated_output" ]; then
        log "  ${GREEN}→ Global npm packages are up to date${NC}"
        return 0
    fi

    log "$outdated_output"
    log "  → Upgrading..."

    if ! npm update -g; then
        log "${RED}  ⚠️  npm update failed${NC}"
        return 1
    fi

    return 0
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
        return 1
    fi

    if [ -z "$outdated_output" ]; then
        log "  ${GREEN}→ No Mac App Store updates found${NC}"
        return 0
    fi

    log "$outdated_output"
    log "  → Upgrading..."

    if mas update "$accuracy_arg"; then
        return 0
    fi

    # Fallback for older mas versions/aliases.
    if mas upgrade "$accuracy_arg"; then
        return 0
    fi

    log "${RED}  ⚠️  Could not update Mac App Store apps${NC}"
    return 1
}

# === Oh My Zsh update ===
update_ohmyzsh() {
    local zsh_root="$HOME/.oh-my-zsh"

    if [ ! -d "$zsh_root" ]; then
        log "  ${YELLOW}→ Oh My Zsh is not installed; skipping${NC}"
        return "$STEP_SKIP"
    fi

    if [ -x "$zsh_root/tools/upgrade.sh" ]; then
        log "  → Updating with bundled upgrade.sh..."
        if ! ZSH="$zsh_root" DISABLE_UPDATE_PROMPT=true "$zsh_root/tools/upgrade.sh" -v silent; then
            log "${RED}  ⚠️  Oh My Zsh update failed${NC}"
            return 1
        fi
        return 0
    fi

    log "  → tools/upgrade.sh not found; using git pull..."
    if ! (cd "$zsh_root" && git pull --ff-only --quiet); then
        log "${RED}  ⚠️  Oh My Zsh update through git failed${NC}"
        return 1
    fi

    return 0
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

    return 0
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

    if ! pipx "${args[@]}"; then
        log "${RED}  ⚠️  pipx package update failed${NC}"
        return 1
    fi

    if pipx upgrade-shared --help >/dev/null 2>&1; then
        log "  → Updating shared pipx libraries..."
        if ! pipx upgrade-shared; then
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

    local had_warn=0
    local uv_output=""
    local uv_exit=0
    local brew_outdated_output=""
    local brew_outdated_exit=0

    # If uv is installed through Homebrew, use Homebrew for the binary and
    # still update uv tools separately.
    if command -v brew >/dev/null 2>&1 && brew list --formula 2>/dev/null | grep -Fxq "uv"; then
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
                if ! HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew upgrade --formula uv; then
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
        if ! uv tool upgrade --all; then
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
init_step_selection

validate_lock_dir
init_logging
init_step_tracking

if ! acquire_lock; then
    exit 1
fi

log "${BLUE}╔════════════════════════════════════════════════╗${NC}"
log "${BLUE}║   🔄 UPDATE ALL APPS AND PACKAGES    ║${NC}"
log "${BLUE}╚════════════════════════════════════════════════╝${NC}"
log ""
log "${YELLOW}Started at: $DATE${NC}"
log ""

run_total=${#RUN_STEP_INDEXES[@]}
ANY_STEP_FAILED=0
ANY_STEP_WARN=0
step_num=1
for step_idx in "${RUN_STEP_INDEXES[@]}"; do
    if ! run_step "$step_num" "$run_total" "$step_idx"; then
        ANY_STEP_FAILED=1
        if [ "$FAIL_FAST" -eq 1 ]; then
            break
        fi
    fi
    log ""
    step_num=$((step_num + 1))
done

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
