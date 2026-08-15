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
    "upgrade --cask broken-app regular-app")
        printf '%s\n' "${HOMEBREW_UPGRADE_GREEDY_CASKS:-}" >"$GREEDY_CAPTURE"
        rm -rf "$CASKROOM/broken-app/1.0.upgrading"
        exit 0
        ;;
    "upgrade --cask stubborn-app")
        printf '%s\n' "${HOMEBREW_UPGRADE_GREEDY_CASKS:-}" >"$GREEDY_CAPTURE"
        exit 1
        ;;
    "reinstall --cask stubborn-app")
        printf '%s\n' "${UPDATE_ALL_ASKPASS_CONTEXT:-}" >"$REPAIR_CONTEXT_CAPTURE"
        exit 0
        ;;
    "upgrade --formula formula-one")
        exit 0
        ;;
esac

printf 'unexpected brew call: %s\n' "$*" >&2
exit 64
BREW_STUB

cat >"$tmp_dir/bin/rm" <<'RM_STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${*: -1}" in
    */stubborn-app/*.upgrading) exit 1 ;;
esac
exec /bin/rm "$@"
RM_STUB

chmod +x "$tmp_dir/bin/brew" "$tmp_dir/bin/rm"

CALLS_FILE="$calls_file" \
    CASKROOM="$tmp_dir/caskroom" \
    GREEDY_CAPTURE="$tmp_dir/greedy.txt" \
    REPAIR_CONTEXT_CAPTURE="$tmp_dir/unused-context.txt" \
    OUTDATED_COUNT_FILE="$outdated_count_file" \
    PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$run_log" \
    --lock-dir "$tmp_dir/lock" \
    --only homebrew >/dev/null 2>&1

if ! grep -Fxq 'brew upgrade --cask broken-app regular-app' "$calls_file"; then
    printf 'Expected interrupted and ordinary casks in one Homebrew batch.\n' >&2
    cat "$calls_file" >&2
    exit 1
fi

repair_line=$(grep -nFx 'brew upgrade --cask broken-app regular-app' "$calls_file" | cut -d: -f1)
cask_line="$repair_line"
formula_line=$(grep -nFx 'brew upgrade --formula formula-one' "$calls_file" | cut -d: -f1)

if [ "$cask_line" -ge "$formula_line" ]; then
    printf 'Expected the combined cask batch before the formula upgrade.\n' >&2
    cat "$calls_file" >&2
    exit 1
fi

if [ "$(cat "$tmp_dir/greedy.txt")" != 'broken-app' ]; then
    printf 'Only the interrupted token should be greedy in the combined batch.\n' >&2
    cat "$tmp_dir/greedy.txt" >&2
    exit 1
fi

if ! grep -Fq 'Interrupted Homebrew cask upgrade found: broken-app' "$run_log"; then
    printf 'Expected a clear interrupted-cask diagnostic.\n' >&2
    cat "$run_log" >&2
    exit 1
fi

if [ "$(grep -Ec '^brew (upgrade|reinstall|install|uninstall) --cask' "$calls_file")" -ne 1 ]; then
    printf 'Normal interrupted recovery must use one mutating Homebrew cask process.\n' >&2
    cat "$calls_file" >&2
    exit 1
fi

if [ -d "$tmp_dir/caskroom/broken-app/1.0.upgrading" ]; then
    printf 'Successful recovery must remove the stale .upgrading marker.\n' >&2
    exit 1
fi

mkdir -p "$tmp_dir/caskroom/stubborn-app/2.0.upgrading/Stubborn.app"
: >"$calls_file"
if ! CALLS_FILE="$calls_file" \
    CASKROOM="$tmp_dir/caskroom" \
    GREEDY_CAPTURE="$tmp_dir/stubborn-greedy.txt" \
    REPAIR_CONTEXT_CAPTURE="$tmp_dir/stubborn-context.txt" \
    OUTDATED_COUNT_FILE="$outdated_count_file" \
    PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$tmp_dir/stubborn.log" \
    --lock-dir "$tmp_dir/stubborn-lock" \
    --only homebrew >/dev/null 2>&1; then
    printf 'A successful reinstall must not fail only because marker cleanup was denied.\n' >&2
    exit 1
fi

if [ "$(grep -Ec '^brew (upgrade|reinstall|install|uninstall) --cask' "$calls_file")" -ne 2 ]; then
    printf 'Exceptional recovery should use one failed batch and one reinstall batch.\n' >&2
    cat "$calls_file" >&2
    exit 1
fi

notice_line=$(grep -nF 'one additional password dialog may appear' "$tmp_dir/stubborn.log" | head -n1 | cut -d: -f1)
repair_log_line=$(grep -nF 'Repairing cask batch: 1 app(s)' "$tmp_dir/stubborn.log" | head -n1 | cut -d: -f1)
if [ -z "$notice_line" ] || [ -z "$repair_log_line" ] || [ "$notice_line" -ge "$repair_log_line" ]; then
    printf 'Fallback password notice must precede the separate reinstall batch.\n' >&2
    cat "$tmp_dir/stubborn.log" >&2
    exit 1
fi

if ! grep -Fq 'additional recovery request' "$tmp_dir/stubborn-context.txt"; then
    printf 'Fallback askpass context must explain why another password is requested.\n' >&2
    cat "$tmp_dir/stubborn-context.txt" >&2
    exit 1
fi

if ! grep -Fq 'stale .upgrading directory could not be removed: stubborn-app' "$tmp_dir/stubborn.log"; then
    printf 'Expected a precise warning when the stale marker cannot be removed.\n' >&2
    cat "$tmp_dir/stubborn.log" >&2
    exit 1
fi
