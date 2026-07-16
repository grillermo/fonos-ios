#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v swiftlint >/dev/null 2>&1; then
    echo "swiftlint is required (install with: brew install swiftlint)" >&2
    exit 127
fi

swiftlint lint --strict
git diff --check
