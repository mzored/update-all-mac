#!/usr/bin/env bash
set -euo pipefail

readme=${1:-README.md}

require_text() {
    local expected=$1
    if ! grep -Fq -- "$expected" "$readme"; then
        printf 'Missing required README text: %s\n' "$expected" >&2
        return 1
    fi
}

reject_text() {
    local forbidden=$1
    if grep -Fq -- "$forbidden" "$readme"; then
        printf 'Forbidden README text found: %s\n' "$forbidden" >&2
        return 1
    fi
}

require_text 'brew install mzored/tap/update-all-mac'
require_text 'macOS Gatekeeper'
require_text 'Download ZIP'
require_text 'xattr -d com.apple.quarantine update-all-mac.command'
reject_text 'curl -fsSL https://raw.githubusercontent.com/MZored/update-all-mac/main/update-all-mac.command | bash'
