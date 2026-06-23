#!/usr/bin/env bash
set -euo pipefail

# After `npm update -g`, the script re-checks for outdated globals. If something
# is still outdated (e.g. a package left on an older major), the step must end
# as a warning rather than a clean success.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home"
run_log="$tmp_dir/run.log"

cat >"$tmp_dir/bin/npm" <<'NPM_STUB'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    outdated)
        # Always reports an outdated package, even after the upgrade ran.
        printf 'Package  Current  Wanted  Latest  Location            Depended by\n'
        printf 'stuck    1.0.0    2.0.0   2.0.0   node_modules/stuck  global\n'
        exit 1
        ;;
    update)
        exit 0
        ;;
esac
exit 0
NPM_STUB

chmod +x "$tmp_dir/bin/npm"

PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" \
    HOME="$tmp_dir/home" \
    UPDATE_ALL_NO_PAUSE=1 \
    /bin/bash "$repo_root/update-all-mac.command" \
    --no-color \
    --log-file "$run_log" \
    --lock-dir "$tmp_dir/lock" \
    --only npm >/dev/null 2>&1

if ! grep -Fq 'still outdated after upgrade' "$run_log"; then
    printf 'Expected a leftover-outdated warning after the upgrade.\n' >&2
    cat "$run_log" >&2
    exit 1
fi

if ! grep -Fq '⚠️  npm completed with warnings' "$run_log"; then
    printf 'Expected the npm step to end with a warning status.\n' >&2
    cat "$run_log" >&2
    exit 1
fi
