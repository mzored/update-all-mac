#!/usr/bin/env bash
set -euo pipefail

# A failed interrupted-cask reinstall must not escalate to destructive removal
# unless the user explicitly enables the force-repair gate.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home" "$tmp_dir/caskroom/guarded-app/1.0.upgrading"
calls_file="$tmp_dir/calls.log"

cat >"$tmp_dir/bin/brew" <<'BREW_STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'brew %s\n' "$*" >>"$CALLS_FILE"
case "$*" in
    "help update-if-needed" | "update-if-needed" | "outdated --formula --quiet" | "outdated --cask --quiet" | "list --pinned") exit 0 ;;
    "--caskroom") printf '%s\n' "$CASKROOM" ;;
    "upgrade --cask --greedy guarded-app") exit 1 ;;
    "reinstall --cask guarded-app") exit 1 ;;
    "uninstall --cask --force guarded-app") exit 0 ;;
    "install --cask guarded-app") exit 0 ;;
    *) printf 'unexpected brew call: %s\n' "$*" >&2; exit 64 ;;
esac
BREW_STUB
chmod +x "$tmp_dir/bin/brew"

run_case() {
    local name="$1"
    shift
    : >"$calls_file"
    CALLS_FILE="$calls_file" \
        CASKROOM="$tmp_dir/caskroom" \
        PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
        HOME="$tmp_dir/home" \
        UPDATE_ALL_NO_PAUSE=1 \
        /bin/bash "$repo_root/update-all-mac.command" \
        --no-color \
        --log-file "$tmp_dir/$name.log" \
        --lock-dir "$tmp_dir/$name-lock" \
        --only homebrew "$@" >/dev/null 2>&1
}

if run_case guarded; then
    printf 'A failed guarded repair should make the Homebrew step fail.\n' >&2
    exit 1
fi

if grep -Fq 'brew uninstall --cask --force guarded-app' "$calls_file"; then
    printf 'Forced uninstall ran without --force-cask-repair.\n' >&2
    exit 1
fi

run_case forced --force-cask-repair

for expected in \
    'brew upgrade --cask --greedy guarded-app' \
    'brew reinstall --cask guarded-app' \
    'brew uninstall --cask --force guarded-app' \
    'brew install --cask guarded-app'; do
    if ! grep -Fq "$expected" "$calls_file"; then
        printf 'Forced repair did not run: %s\n' "$expected" >&2
        cat "$calls_file" >&2
        exit 1
    fi
done

if [ -d "$tmp_dir/caskroom/guarded-app/1.0.upgrading" ]; then
    printf 'Successful forced recovery left the .upgrading marker behind.\n' >&2
    exit 1
fi
