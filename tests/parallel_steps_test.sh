#!/usr/bin/env bash
set -euo pipefail

# In --parallel mode the npm, pipx, and Mac App Store steps run concurrently and
# are replayed in canonical order with their statuses preserved.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home"
run_log="$tmp_dir/run.log"

cat >"$tmp_dir/bin/npm" <<'NPM_STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    outdated) exit 0 ;; # nothing outdated -> up to date
esac
exit 0
NPM_STUB

cat >"$tmp_dir/bin/pipx" <<'PIPX_STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    "upgrade-all --help") exit 0 ;;    # no --include-injected advertised
    "upgrade-all") exit 0 ;;
    "upgrade-shared --help") exit 1 ;; # shared upgrade unsupported
esac
exit 0
PIPX_STUB

cat >"$tmp_dir/bin/mas" <<'MAS_STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    outdated) exit 0 ;; # no Mac App Store updates
esac
exit 0
MAS_STUB

chmod +x "$tmp_dir/bin/npm" "$tmp_dir/bin/pipx" "$tmp_dir/bin/mas"

run_rc=0
PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$run_log" \
    --lock-dir "$tmp_dir/lock" \
    --parallel \
    --only npm,pipx,mas >/dev/null 2>&1 || run_rc=$?

if [ "$run_rc" -ne 0 ]; then
    printf 'Parallel run of all-successful steps should exit 0 (got %s).\n' "$run_rc" >&2
    cat "$run_log" >&2
    exit 1
fi

for needle in \
    '📦 1/3 npm' \
    '📦 2/3 Mac App Store' \
    '📦 3/3 pipx' \
    '✅ npm completed' \
    '✅ Mac App Store completed' \
    '✅ pipx completed'; do
    if ! grep -Fq "$needle" "$run_log"; then
        printf 'Missing expected log line: %s\n' "$needle" >&2
        cat "$run_log" >&2
        exit 1
    fi
done

# Canonical order: npm before Mac App Store before pipx.
npm_line=$(grep -n '📦 1/3 npm' "$run_log" | head -1 | cut -d: -f1)
mas_line=$(grep -n '📦 2/3 Mac App Store' "$run_log" | head -1 | cut -d: -f1)
pipx_line=$(grep -n '📦 3/3 pipx' "$run_log" | head -1 | cut -d: -f1)
if [ "$npm_line" -ge "$mas_line" ] || [ "$mas_line" -ge "$pipx_line" ]; then
    printf 'Parallel step blocks are out of canonical order in the log.\n' >&2
    cat "$run_log" >&2
    exit 1
fi
