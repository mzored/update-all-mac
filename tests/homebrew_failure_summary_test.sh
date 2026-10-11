#!/usr/bin/env bash
set -euo pipefail

# Failure diagnostics must survive a long command tail, and the final banner
# must describe the result independently of the requested exit-code policy.
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
    'help update-if-needed'|'update-if-needed'|'list --pinned'|'list --cask'|'list --formula') exit 0 ;;
    'outdated --cask --quiet')
        if [ "$CASE" = recovered ] && [ ! -f "$STATE/upgraded" ]; then printf 'valid-app\n'; fi ;;
    'info --cask valid-app') printf 'Verified fixture cask information\n'; exit 0 ;;
    'upgrade --cask valid-app') touch "$STATE/upgraded"; printf 'Error: batch reported failure\n' >&2; exit 1 ;;
    '--caskroom') printf '%s\n' "$CASKROOM" ;;
    'outdated --formula --quiet') [ "$CASE" != failed ] || printf 'node@22\n' ;;
    'upgrade --formula node@22')
        printf 'Error: brew link could not complete for node@22\n' >&2
        i=0
        while [ "$i" -lt 30 ]; do printf 'Successfully processed dependency %s\n' "$i"; i=$((i + 1)); done
        exit 1 ;;
    *) exit 64 ;;
esac
STUB
cat >"$tmp_dir/bin/npm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$STATE/calls"
case "${1:-}" in
    outdated) printf 'stuck 1.0.0 2.0.0 2.0.0\n'; exit 1 ;;
    update) exit 0 ;;
    *) exit 64 ;;
esac
STUB
chmod +x "$tmp_dir/bin/brew" "$tmp_dir/bin/npm"
# Include every setup_path directory so fixtures retain precedence.
export PATH="$tmp_dir/bin:/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/homebrew/sbin:/opt/homebrew/bin"
[ "$(command -v brew)" = "$tmp_dir/bin/brew" ] || exit 1
[ "$(command -v npm)" = "$tmp_dir/bin/npm" ] || exit 1
failures=0
fail() { printf '%s: %s\n' "$name" "$1" >&2; failures=$((failures + 1)); }
for name in success failed failed-zero warning warning-strict warning-zero recovered recovered-strict recovered-zero; do
    state="$tmp_dir/$name"; mkdir -p "$state"
    args=(); manager=homebrew; scenario=success; expected_rc=0
    case "$name" in
        failed*) scenario=failed; expected_rc=1 ;;
        warning*) manager=npm ;;
        recovered*) scenario=recovered ;;
    esac
    case "$name" in
        failed-zero|warning-zero|recovered-zero) args=(--strict --exit-zero); expected_rc=0 ;;
        warning-strict|recovered-strict) args=(--strict); expected_rc=1 ;;
    esac
    rc=0
    CASE="$scenario" STATE="$state" CASKROOM="$tmp_dir/caskroom" HOME="$tmp_dir/home" UPDATE_ALL_NO_PAUSE=1 \
        /bin/bash "$script" --only "$manager" --no-color --log-file "$state/run.log" \
        --lock-dir "$state/lock" ${args[@]+"${args[@]}"} >"$state/stdout" 2>&1 || rc=$?
    [ -s "$state/calls" ] || { printf 'Fixture manager was not invoked.\n' >&2; exit 1; }
    [ "$rc" -eq "$expected_rc" ] || fail "expected exit $expected_rc, got $rc"
    case "$name" in
        success) grep -Fq 'UPDATE COMPLETE!' "$state/stdout" || fail 'clean success must retain success banner' ;;
        failed*)
            grep -Fq 'Error: brew link could not complete for node@22' "$state/stdout" || fail 'compact output lost an early actionable error'
            grep -Fq 'Homebrew failed' "$state/stdout" || fail 'failure must reach step summary'
            if grep -Fq 'UPDATE COMPLETE!' "$state/stdout"; then fail 'failed run must not display success banner'; fi ;;
        recovered*)
            grep -Fxq 'upgrade --cask valid-app' "$state/calls" || fail 'recovered scenario must attempt native cask upgrade'
            grep -Fxq 'info --cask valid-app' "$state/calls" || fail 'recovered app must be verified with cask information'
            [ "$(grep -Fc 'outdated --cask --quiet' "$state/calls")" -ge 2 ] || fail 'recovered app must have a successful postquery'
            if grep -E '^(reinstall|uninstall|install) ' "$state/calls" >/dev/null; then fail 'verified recovered app must not undergo speculative repair'; fi
            grep -Fq 'Homebrew completed with warnings' "$state/stdout" || fail 'recovered operation must preserve its warning'
            if grep -Fq 'UPDATE COMPLETE!' "$state/stdout"; then fail 'recovered operation must not show clean success'; fi ;;
        warning*)
            grep -Fq 'npm completed with warnings' "$state/stdout" || fail 'warning must reach step summary'
            if grep -Fq 'UPDATE COMPLETE!' "$state/stdout"; then fail 'warning run must not display clean success banner'; fi ;;
    esac
done
[ "$failures" -eq 0 ]
