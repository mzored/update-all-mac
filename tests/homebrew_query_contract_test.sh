#!/usr/bin/env bash
set -euo pipefail

# Homebrew package queries must never turn diagnostics or malformed records
# into package arguments, and failed recovery queries must stop mutation.
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=${UPDATER_TEST_SCRIPT:-$repo_root/update-all-mac.command}
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/home" "$tmp_dir/caskroom"
cat >"$tmp_dir/bin/brew" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$STATE/calls"
case "$*" in
    'help update-if-needed'|'update-if-needed') exit 0 ;;
    '--caskroom')
        if [ "$CASE" = caskroom-error ]; then printf 'Error: unavailable caskroom\n' >&2; exit 7; fi
        printf '%s\n' "$CASKROOM" ;;
    'outdated --formula --quiet')
        case "$CASE" in
            valid) printf 'node@22\nuser/tap/tool\npinned-tool\n' ;;
            malformed-formula) printf 'node@22\nWarning: not a package record\n' ;;
        esac
        printf 'Warning: formula query diagnostic\n' >&2 ;;
    'outdated --cask --quiet')
        count=0
        [ ! -f "$STATE/count" ] || count=$(cat "$STATE/count")
        count=$((count + 1)); printf '%s\n' "$count" >"$STATE/count"
        case "$CASE" in
            valid) [ "$count" -ne 1 ] || printf 'valid-app\n' ;;
            malformed-cask) printf 'valid-app\n--bad-option\n' ;;
            recovery-error|postcheck-error|force-query-error)
                if [ "$count" -eq 1 ]; then printf 'valid-app\n'
                elif [ "$CASE" = force-query-error ] && [ "$count" -eq 2 ]; then printf 'valid-app\n'
                else printf 'Error: recovery query unavailable\n' >&2; exit 8; fi ;;
        esac
        printf 'Warning: cask query diagnostic\n' >&2 ;;
    'list --pinned')
        case "$CASE" in valid) printf 'pinned-tool\n' ;; malformed-pinned) printf 'invalid token\n' ;; esac
        printf 'Warning: pin query diagnostic\n' >&2 ;;
    'list --cask'|'list --formula'|'info --cask valid-app') exit 0 ;;
    upgrade\ --formula*) exit 0 ;;
    upgrade\ --cask*)
        case "$CASE" in recovery-error|force-query-error) exit 9 ;; esac ;;
    reinstall\ --cask*) exit 9 ;;
    uninstall\ --cask*|install\ --cask*) exit 0 ;;
    *) printf 'Unexpected brew command: %s\n' "$*" >&2; exit 64 ;;
esac
STUB
chmod +x "$tmp_dir/bin/brew"
# Include every setup_path directory so none can be prepended ahead of fixtures.
export PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin"
[ "$(command -v brew)" = "$tmp_dir/bin/brew" ] || exit 1
failures=0
fail() { printf '%s: %s\n' "$name" "$1" >&2; failures=$((failures + 1)); }
for name in valid empty malformed-formula malformed-cask malformed-pinned caskroom-error recovery-error postcheck-error force-query-error; do
    state="$tmp_dir/$name"; mkdir -p "$state"
    rc=0
    CASE="$name" STATE="$state" CASKROOM="$tmp_dir/caskroom" HOME="$tmp_dir/home" \
        PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin" UPDATE_ALL_NO_PAUSE=1 \
        /bin/bash "$script" --only homebrew --no-color --force-cask-repair \
        --log-file "$state/run.log" --lock-dir "$state/lock" >"$state/stdout" 2>&1 || rc=$?
    [ -s "$state/calls" ] || { printf 'Fixture brew was not invoked.\n' >&2; exit 1; }
    case "$name" in
        valid)
            [ "$rc" -eq 0 ] || fail 'valid qualified package tokens must succeed'
            grep -Fxq 'upgrade --formula node@22 user/tap/tool' "$state/calls" || fail 'only unpinned stdout formula tokens may be upgraded'
            grep -Fxq 'upgrade --cask valid-app' "$state/calls" || fail 'only stdout cask tokens may be upgraded'
            if grep -E '^(upgrade|reinstall|install|uninstall).*Warning:' "$state/calls" >/dev/null; then fail 'stderr diagnostics entered package arguments'; fi
            for marker in 'formula query diagnostic' 'cask query diagnostic' 'pin query diagnostic'; do
                grep -Fq "$marker" "$state/run.log" || fail 'stderr diagnostics must remain in the canonical log'
            done ;;
        empty)
            [ "$rc" -eq 0 ] || fail 'empty stdout with stderr warnings must succeed'
            if grep -E '^(upgrade|reinstall|install|uninstall) ' "$state/calls" >/dev/null; then fail 'empty stdout must not mutate packages'; fi ;;
        malformed-*|caskroom-error)
            [ "$rc" -ne 0 ] || fail 'invalid or unavailable discovery must fail'
            if grep -E '^(upgrade|reinstall|install|uninstall) ' "$state/calls" >/dev/null; then fail 'invalid discovery must fail before package mutation'; fi ;;
        *)
            [ "$rc" -ne 0 ] || fail 'unavailable recovery/postcheck must remain a failure'
            if grep -E '^(uninstall|install|reinstall) ' "$state/calls" >/dev/null; then
                # The force-query case deliberately reaches one failed reinstall
                # before its next query fails. Destructive fallback is forbidden.
                if [ "$name" != force-query-error ] || grep -E '^(uninstall|install) ' "$state/calls" >/dev/null; then fail 'failed query must not trigger further repair mutation'; fi
            fi ;;
    esac
done
[ "$failures" -eq 0 ]
