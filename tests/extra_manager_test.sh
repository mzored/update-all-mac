#!/usr/bin/env bash
set -euo pipefail

# The extra self-skipping manager steps (rust/mise/asdf/gcloud) must run their
# updater when the tool is present. Here a stubbed rustup prints a marker during
# `rustup update`; the marker must reach the log and the Rust step must succeed.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home"
run_log="$tmp_dir/run.log"
marker='MARKER_RUSTUP_UPDATE_q1w2e3'

cat >"$tmp_dir/bin/rustup" <<'RUSTUP_STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    update)
        printf '%s\n' "$MARKER"
        exit 0
        ;;
    --version)
        printf 'rustup 1.0.0-test\n'
        exit 0
        ;;
esac
exit 0
RUSTUP_STUB

chmod +x "$tmp_dir/bin/rustup"

MARKER="$marker" \
    PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$run_log" \
    --lock-dir "$tmp_dir/lock" \
    --only rust >/dev/null 2>&1

if ! grep -Fq "$marker" "$run_log"; then
    printf 'Expected rustup update output (%s) to be captured in the log.\n' "$marker" >&2
    cat "$run_log" >&2
    exit 1
fi

if ! grep -Fq '✅ Rust completed' "$run_log"; then
    printf 'Expected the Rust step to complete successfully.\n' >&2
    cat "$run_log" >&2
    exit 1
fi
