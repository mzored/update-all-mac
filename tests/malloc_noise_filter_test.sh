#!/usr/bin/env bash
set -euo pipefail

# Homebrew's bundled ruby prints benign "MallocStackLogging: can't turn off..."
# lines to stderr during cask work. run_logged() must filter those out of the
# captured output while keeping the command's real output. Here a stubbed npm
# upgrade prints one such noise line plus a unique marker; the marker must reach
# the log and the noise must not.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home" "$tmp_dir/state"
run_log="$tmp_dir/run.log"
marker='MARKER_MALLOC_FILTER_x9y8z7'
noise="ruby(12345) MallocStackLogging: can't turn off malloc stack logging because it was not enabled."

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
        # Benign macOS malloc noise on stderr, real output on stdout.
        printf '%s\n' "$NOISE" >&2
        printf '%s\n' "$MARKER"
        touch "$STATE_DIR/upgraded"
        exit 0
        ;;
esac
exit 0
NPM_STUB

chmod +x "$tmp_dir/bin/npm"

MARKER="$marker" \
    NOISE="$noise" \
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
    printf 'Expected real upgrade output (%s) to be captured in the log.\n' "$marker" >&2
    cat "$run_log" >&2
    exit 1
fi

if grep -Fq 'MallocStackLogging' "$run_log"; then
    printf 'Benign MallocStackLogging noise should have been filtered out of the log.\n' >&2
    cat "$run_log" >&2
    exit 1
fi

if ! grep -Fq '✅ npm completed' "$run_log"; then
    printf 'Expected npm to complete successfully.\n' >&2
    cat "$run_log" >&2
    exit 1
fi
