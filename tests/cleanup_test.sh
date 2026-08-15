#!/usr/bin/env bash
set -euo pipefail

# Cleanup has two explicit safety levels. Default mode may only run tools'
# conservative garbage collectors; --deep-clean may purge reinstall caches but
# must never remove project-selected Rust, mise, or asdf tool versions.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home"

make_stub() {
    local name="$1"
    cat >"$tmp_dir/bin/$name" <<'GENERIC_STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "$*" >>"$CALLS_FILE"
case "$*" in
    "cleanup --help") printf '%s\n' '--scrub --prune=all' ;;
    "cleanup --scrub" | "cleanup --prune=all") printf '%s\n' '==> This operation has freed approximately 1.9GB of disk space.' ;;
    "cache --help") printf '%s\n' 'verify clean prune purge' ;;
    "cache prune --help" | "cache clean --help" | "cache purge --help" | "-m pip cache purge --help") exit 0 ;;
esac
exit 0
GENERIC_STUB
    chmod +x "$tmp_dir/bin/$name"
}

for command_name in brew npm uv python3 pipx rustup mise asdf; do
    make_stub "$command_name"
done

run_cleanup() {
    local name="$1"
    shift
    local calls_file="$tmp_dir/$name-calls.log"
    local run_log="$tmp_dir/$name-run.log"
    local stdout_file="$tmp_dir/$name-stdout.log"
    : >"$calls_file"

    CALLS_FILE="$calls_file" \
        PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
        HOME="$tmp_dir/home" \
        UPDATE_ALL_NO_PAUSE=1 \
        /bin/bash "$repo_root/update-all-mac.command" \
        --no-color \
        --log-file "$run_log" \
        --lock-dir "$tmp_dir/$name-lock" \
        --only cleanup "$@" >"$stdout_file" 2>&1
}

run_cleanup safe

for expected in \
    'brew cleanup --scrub' \
    'npm cache verify' \
    'uv cache prune'; do
    if ! grep -Fxq "$expected" "$tmp_dir/safe-calls.log"; then
        printf 'Safe cleanup did not run: %s\n' "$expected" >&2
        cat "$tmp_dir/safe-calls.log" >&2
        exit 1
    fi
done

if ! grep -Fq 'Freed approximately 1.9GB' "$tmp_dir/safe-stdout.log"; then
    printf 'Cleanup summary did not report reclaimed disk space.\n' >&2
    cat "$tmp_dir/safe-stdout.log" >&2
    exit 1
fi

if grep -Eq 'cache (clean|purge)|pip cache purge|^(rustup|mise|asdf) ' "$tmp_dir/safe-calls.log"; then
    printf 'Safe cleanup invoked an aggressive command.\n' >&2
    cat "$tmp_dir/safe-calls.log" >&2
    exit 1
fi

run_cleanup deep --deep-clean

for expected in \
    'brew cleanup --prune=all' \
    'npm cache clean --force' \
    'uv cache clean' \
    'python3 -m pip cache purge' \
    'pipx cache purge'; do
    if ! grep -Fxq "$expected" "$tmp_dir/deep-calls.log"; then
        printf 'Deep cleanup did not run: %s\n' "$expected" >&2
        cat "$tmp_dir/deep-calls.log" >&2
        exit 1
    fi
done

if grep -Eq '^(rustup|mise|asdf) ' "$tmp_dir/deep-calls.log"; then
    printf 'Deep cleanup must not remove project-selected tool versions.\n' >&2
    cat "$tmp_dir/deep-calls.log" >&2
    exit 1
fi

run_cleanup preview --dry-run --deep-clean

if grep -Eq '^brew cleanup --prune=all$|^npm cache clean --force$|^uv cache clean$|^python3 -m pip cache purge$|^pipx cache purge$' "$tmp_dir/preview-calls.log"; then
    printf 'Dry-run cleanup executed a mutating command.\n' >&2
    cat "$tmp_dir/preview-calls.log" >&2
    exit 1
fi

if ! grep -Fq '[dry-run] would run deep cache cleanup' "$tmp_dir/preview-run.log"; then
    printf 'Dry-run cleanup did not explain the planned deep cleanup.\n' >&2
    cat "$tmp_dir/preview-run.log" >&2
    exit 1
fi
