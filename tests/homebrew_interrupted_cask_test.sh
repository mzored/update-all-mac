#!/usr/bin/env bash
set -euo pipefail

# A cask directory ending in .upgrading is evidence that Homebrew was
# interrupted mid-upgrade. The updater must repair it before starting normal
# cask upgrades, and all cask work must happen before the long formula batch so
# any required administrator prompt appears near the start of the run.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p \
    "$tmp_dir/bin" \
    "$tmp_dir/home" \
    "$tmp_dir/caskroom/broken-app/1.0.upgrading/Broken.app"
calls_file="$tmp_dir/calls.log"
run_log="$tmp_dir/run.log"
outdated_count_file="$tmp_dir/outdated-count"

cat >"$tmp_dir/bin/brew" <<'BREW_STUB'
#!/usr/bin/env bash
set -euo pipefail

printf 'brew %s\n' "$*" >>"$CALLS_FILE"

case "$*" in
    "help update-if-needed" | "update-if-needed" | "cleanup" | "cleanup --scrub")
        exit 0
        ;;
    "--caskroom")
        printf '%s\n' "$CASKROOM"
        exit 0
        ;;
    "outdated --formula --quiet")
        printf 'formula-one\n'
        exit 0
        ;;
    "outdated --cask --quiet")
        count=0
        if [ -f "$OUTDATED_COUNT_FILE" ]; then
            count=$(cat "$OUTDATED_COUNT_FILE")
        fi
        count=$((count + 1))
        printf '%s\n' "$count" >"$OUTDATED_COUNT_FILE"
        if [ "$count" -eq 1 ]; then
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
    "reinstall --cask broken-app")
        exit 0
        ;;
    "upgrade --cask regular-app")
        exit 0
        ;;
    "upgrade --formula formula-one")
        exit 0
        ;;
esac

printf 'unexpected brew call: %s\n' "$*" >&2
exit 64
BREW_STUB

chmod +x "$tmp_dir/bin/brew"

CALLS_FILE="$calls_file" \
    CASKROOM="$tmp_dir/caskroom" \
    OUTDATED_COUNT_FILE="$outdated_count_file" \
    PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$run_log" \
    --lock-dir "$tmp_dir/lock" \
    --only homebrew >/dev/null 2>&1

if ! grep -Fxq 'brew reinstall --cask broken-app' "$calls_file"; then
    printf 'Expected the interrupted cask to be repaired.\n' >&2
    cat "$calls_file" >&2
    exit 1
fi

repair_line=$(grep -nFx 'brew reinstall --cask broken-app' "$calls_file" | cut -d: -f1)
cask_line=$(grep -nFx 'brew upgrade --cask regular-app' "$calls_file" | cut -d: -f1)
formula_line=$(grep -nFx 'brew upgrade --formula formula-one' "$calls_file" | cut -d: -f1)

if [ "$repair_line" -ge "$cask_line" ] || [ "$cask_line" -ge "$formula_line" ]; then
    printf 'Expected interrupted repair, then cask upgrade, then formula upgrade.\n' >&2
    cat "$calls_file" >&2
    exit 1
fi

if ! grep -Fq 'Interrupted Homebrew cask upgrade found: broken-app' "$run_log"; then
    printf 'Expected a clear interrupted-cask diagnostic.\n' >&2
    cat "$run_log" >&2
    exit 1
fi

if [ -d "$tmp_dir/caskroom/broken-app/1.0.upgrading" ]; then
    printf 'Successful recovery must remove the stale .upgrading marker.\n' >&2
    exit 1
fi
