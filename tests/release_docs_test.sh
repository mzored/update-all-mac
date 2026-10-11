#!/usr/bin/env bash
set -euo pipefail

readme=${1:-README.md}
repo_root=$(cd "$(dirname "$readme")" && pwd)
reference="$repo_root/docs/reference.md"
troubleshooting="$repo_root/docs/troubleshooting.md"

for doc in "$readme" "$reference" "$troubleshooting" "$repo_root/docs/development.md"; do
    [ -f "$doc" ] || {
        printf 'Missing documentation file: %s\n' "$doc" >&2
        exit 1
    }
done

require_text() {
    local expected=$1
    local file=${2:-$readme}
    if ! grep -Fq -- "$expected" "$file"; then
        printf 'Missing required text in %s: %s\n' "$file" "$expected" >&2
        return 1
    fi
}

reject_text() {
    local forbidden=$1
    if grep -Fq -- "$forbidden" "$readme" "$reference" "$troubleshooting"; then
        printf 'Forbidden documentation text found: %s\n' "$forbidden" >&2
        return 1
    fi
}

require_text 'brew tap mzored/update-all-mac https://github.com/mzored/update-all-mac'
require_text 'brew install update-all-mac'
require_text '(docs/reference.md)'
require_text '(docs/troubleshooting.md)'
require_text '(docs/development.md)'
require_text 'Migrate from the old tap' "$troubleshooting"
require_text 'brew untap mzored/tap' "$troubleshooting"
require_text 'macOS Gatekeeper' "$troubleshooting"
require_text 'Download ZIP' "$troubleshooting"
require_text 'xattr -d com.apple.quarantine update-all-mac.command' "$troubleshooting"
script_version=$(sed -n 's/^# Version: //p' "$repo_root/update-all-mac.command")
[ -n "$script_version" ] || {
    printf 'Missing script version.\n' >&2
    exit 1
}
require_text "Current version: $script_version"
require_text '--verbose'
require_text '--deep-clean'
require_text 'UPDATE_ALL_VERBOSE=1' "$reference"
require_text 'UPDATE_ALL_DEEP_CLEAN=1' "$reference"
require_text "| \`cleanup\` |" "$reference"
require_text 'SUDO_ASKPASS' "$reference"
require_text 'their full output to the log in real time' "$reference"
require_text 'steps keep separate temporary output' "$reference"
reject_text 'brew tap mzored/tap'
reject_text 'brew install mzored/tap/update-all-mac'
reject_text 'curl -fsSL https://raw.githubusercontent.com/MZored/update-all-mac/main/update-all-mac.command | bash'
