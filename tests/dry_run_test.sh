#!/usr/bin/env bash
set -euo pipefail

# --dry-run must detect what would change and preview it, but never run a
# state-changing command. The stubbed npm records a sentinel file if `npm
# update` is ever invoked; in dry-run that file must not exist, the preview line
# must appear, and the step must still report success.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home" "$tmp_dir/state"
run_log="$tmp_dir/run.log"
sentinel="$tmp_dir/state/upgrade_ran"

cat >"$tmp_dir/bin/npm" <<'NPM_STUB'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    outdated)
        printf 'Package  Current  Wanted  Latest  Location           Depended by\n'
        printf 'demo     1.0.0    2.0.0   2.0.0   node_modules/demo  global\n'
        exit 1 # outdated packages present
        ;;
    update)
        touch "$SENTINEL" # proves a mutating command ran
        exit 0
        ;;
esac
exit 0
NPM_STUB

chmod +x "$tmp_dir/bin/npm"

SENTINEL="$sentinel" \
    PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --dry-run \
    --no-color \
    --log-file "$run_log" \
    --lock-dir "$tmp_dir/lock" \
    --only npm >/dev/null 2>&1

if [ -e "$sentinel" ]; then
    printf 'Dry-run must not run mutating commands (npm update ran).\n' >&2
    cat "$run_log" >&2
    exit 1
fi

if ! grep -Fq '[dry-run] would run: npm update -g' "$run_log"; then
    printf 'Expected a dry-run preview line for npm.\n' >&2
    cat "$run_log" >&2
    exit 1
fi

if ! grep -Fq '✅ npm completed' "$run_log"; then
    printf 'Expected npm to report success in dry-run.\n' >&2
    cat "$run_log" >&2
    exit 1
fi
