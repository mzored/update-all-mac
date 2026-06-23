#!/usr/bin/env bash
set -euo pipefail

# A network/registry failure during `npm outdated` (which still exits 1, like a
# normal "packages are outdated" result) must be reported as a failure and must
# NOT trigger a blind `npm update -g`.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home"
calls_file="$tmp_dir/calls.log"
run_log="$tmp_dir/run.log"

cat >"$tmp_dir/bin/npm" <<'NPM_STUB'
#!/usr/bin/env bash
set -euo pipefail

printf 'npm %s\n' "$*" >>"$CALLS_FILE"

case "${1:-}" in
    outdated)
        printf 'npm error code ECONNRESET\n'
        printf 'npm error syscall read\n'
        printf 'npm error network Invalid response body while trying to fetch\n'
        exit 1
        ;;
    update)
        printf 'should not run\n'
        exit 0
        ;;
esac
exit 0
NPM_STUB

chmod +x "$tmp_dir/bin/npm"

run_rc=0
CALLS_FILE="$calls_file" \
    PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$run_log" \
    --lock-dir "$tmp_dir/lock" \
    --only npm >/dev/null 2>&1 || run_rc=$?

if [ "$run_rc" -eq 0 ]; then
    printf 'Expected a non-zero exit when the npm check fails on a network error.\n' >&2
    exit 1
fi

if grep -Eq '^npm update' "$calls_file"; then
    printf 'npm update must NOT run after a failed outdated check.\n' >&2
    printf 'Observed calls:\n' >&2
    cat "$calls_file" >&2
    exit 1
fi

if ! grep -Fq 'Could not check global npm packages' "$run_log"; then
    printf 'Expected a network-error message in the log.\n' >&2
    cat "$run_log" >&2
    exit 1
fi
