#!/usr/bin/env bash
set -euo pipefail

# Interactive macOS runs should give Homebrew a native GUI askpass helper so a
# late sudo request cannot be missed. Existing user configuration wins, and a
# generated helper must be removed when the updater exits.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home" "$tmp_dir/caskroom"

cat >"$tmp_dir/bin/brew" <<'BREW_STUB'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    "help update-if-needed" | "update-if-needed" | "cleanup" | "cleanup --scrub")
        exit 0
        ;;
    "--caskroom")
        printf '%s\n' "$CASKROOM"
        exit 0
        ;;
    "outdated --formula --quiet")
        exit 0
        ;;
    "outdated --cask --quiet")
        if [ ! -f "$STATE_DIR/outdated-seen" ]; then
            touch "$STATE_DIR/outdated-seen"
            printf 'regular-app\n'
        fi
        exit 0
        ;;
    "list --pinned")
        exit 0
        ;;
    "info --cask regular-app")
        exit 0
        ;;
    "upgrade --cask regular-app")
        printf '%s\n' "${SUDO_ASKPASS:-}" >"$ASKPASS_CAPTURE"
        { stat -f '%Lp' "$(dirname "$SUDO_ASKPASS")"; stat -f '%Lp' "$SUDO_ASKPASS"; } | paste -sd ' ' - >"$ASKPASS_MODE_CAPTURE"
        [ -n "${SUDO_ASKPASS:-}" ] && [ -x "$SUDO_ASKPASS" ]
        exit 0
        ;;
    "list --cask" | "list --formula")
        exit 0
        ;;
esac

printf 'unexpected brew call: %s\n' "$*" >&2
exit 64
BREW_STUB

chmod +x "$tmp_dir/bin/brew"

run_interactive_case() {
    local name="$1"
    local configured_askpass="${2:-}"
    local state_dir="$tmp_dir/$name-state"
    local capture="$tmp_dir/$name-askpass.txt"
    local mode_capture="$tmp_dir/$name-askpass-mode.txt"
    mkdir -p "$state_dir"

    if [ -n "$configured_askpass" ]; then
        script -q /dev/null env \
            SUDO_ASKPASS="$configured_askpass" \
            ASKPASS_CAPTURE="$capture" \
            ASKPASS_MODE_CAPTURE="$mode_capture" \
            CASKROOM="$tmp_dir/caskroom" \
            STATE_DIR="$state_dir" \
            PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
            HOME="$tmp_dir/home" \
            UPDATE_ALL_NO_PAUSE=1 \
            /bin/bash "$repo_root/update-all-mac.command" \
            --no-color \
            --log-file "$tmp_dir/$name.log" \
            --lock-dir "$tmp_dir/$name-lock" \
            --only homebrew >/dev/null
    else
        script -q /dev/null env \
            ASKPASS_CAPTURE="$capture" \
            ASKPASS_MODE_CAPTURE="$mode_capture" \
            CASKROOM="$tmp_dir/caskroom" \
            STATE_DIR="$state_dir" \
            PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
            HOME="$tmp_dir/home" \
            UPDATE_ALL_NO_PAUSE=1 \
            /bin/bash "$repo_root/update-all-mac.command" \
            --no-color \
            --log-file "$tmp_dir/$name.log" \
            --lock-dir "$tmp_dir/$name-lock" \
            --only homebrew >/dev/null
    fi
}

run_interactive_case generated
generated_askpass=$(cat "$tmp_dir/generated-askpass.txt")

if [ -z "$generated_askpass" ]; then
    printf 'Expected an interactive run to configure SUDO_ASKPASS.\n' >&2
    exit 1
fi

if [ "$(cat "$tmp_dir/generated-askpass-mode.txt")" != '700 700' ]; then
    printf 'Generated askpass directory and helper must both be mode 0700.\n' >&2
    cat "$tmp_dir/generated-askpass-mode.txt" >&2
    exit 1
fi

if [ -e "$generated_askpass" ]; then
    printf 'Generated askpass helper was not removed after exit: %s\n' "$generated_askpass" >&2
    exit 1
fi

existing_askpass="$tmp_dir/existing-askpass"
printf '#!/bin/bash\nexit 0\n' >"$existing_askpass"
chmod +x "$existing_askpass"
run_interactive_case existing "$existing_askpass"

if [ "$(cat "$tmp_dir/existing-askpass.txt")" != "$existing_askpass" ]; then
    printf 'Existing SUDO_ASKPASS must be preserved.\n' >&2
    exit 1
fi
