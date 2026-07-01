#!/usr/bin/env bash
set -euo pipefail

# --doctor must report detected tools and their versions and exit 0 WITHOUT
# acquiring the lock or opening the log file (it runs before init_logging).

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home"
run_log="$tmp_dir/run.log"

cat >"$tmp_dir/bin/brew" <<'BREW_STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--version" ]; then
    printf 'Homebrew 4.0.0-test\n'
fi
exit 0
BREW_STUB

chmod +x "$tmp_dir/bin/brew"

out=$(
    PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
        HOME="$tmp_dir/home" \
        UPDATE_ALL_NO_PAUSE=1 \
        /bin/bash "$repo_root/update-all-mac.command" \
        --no-color \
        --log-file "$run_log" \
        --lock-dir "$tmp_dir/lock" \
        --doctor
)

if ! printf '%s\n' "$out" | grep -Fq 'Detected tools:'; then
    printf 'Expected doctor output to list detected tools.\n' >&2
    printf '%s\n' "$out" >&2
    exit 1
fi

if ! printf '%s\n' "$out" | grep -Fq 'Homebrew 4.0.0-test'; then
    printf 'Expected doctor to show the detected Homebrew version.\n' >&2
    printf '%s\n' "$out" >&2
    exit 1
fi

if [ -e "$run_log" ]; then
    printf 'Doctor must not create the log file (runs before logging).\n' >&2
    exit 1
fi

if [ -e "$tmp_dir/lock" ]; then
    printf 'Doctor must not acquire the run lock.\n' >&2
    exit 1
fi
