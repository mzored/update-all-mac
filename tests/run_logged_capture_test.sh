#!/usr/bin/env bash
set -euo pipefail

# run_logged() must mirror an external command's real output into the log file,
# so a failed/odd upgrade can be diagnosed afterwards. Here the npm upgrade
# prints a unique marker that must end up in the log.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home" "$tmp_dir/state"
run_log="$tmp_dir/run.log"
marker='MARKER_RUN_LOGGED_a1b2c3'

cat >"$tmp_dir/bin/npm" <<'NPM_STUB'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    outdated)
        if [ -f "$STATE_DIR/upgraded" ]; then
            exit 0 # post-upgrade re-check: now up to date
        fi
        printf 'Package  Current  Wanted  Latest  Location           Depended by\n'
        printf 'demo     1.0.0    2.0.0   2.0.0   node_modules/demo  global\n'
        exit 1 # outdated packages present
        ;;
    update)
        printf '%s\n' "$MARKER"
        touch "$STATE_DIR/upgraded"
        exit 0
        ;;
esac
exit 0
NPM_STUB

chmod +x "$tmp_dir/bin/npm"

MARKER="$marker" \
    STATE_DIR="$tmp_dir/state" \
    PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$run_log" \
    --lock-dir "$tmp_dir/lock" \
    --only npm >/dev/null 2>&1

if ! grep -Fq "$marker" "$run_log"; then
    printf 'Expected upgrade output (%s) to be captured in the log.\n' "$marker" >&2
    cat "$run_log" >&2
    exit 1
fi

if ! grep -Fq '✅ npm completed' "$run_log"; then
    printf 'Expected npm to complete successfully.\n' >&2
    cat "$run_log" >&2
    exit 1
fi
