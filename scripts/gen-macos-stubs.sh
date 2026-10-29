#!/usr/bin/env bash
# Regenerates ffi/macos/*.tbd: TAPI v4 stubs for the macOS frameworks the Rust driver links.
#
# Lean's bundled ld64.lld cannot read the .tbd files of recent macOS SDKs (their `arm64e.x1`
# targets are unknown to it), so the build links against these minimal stubs instead, the same
# way Lean ships its own libSystem.tbd. Run after bumping the driver: it links once without
# frameworks, collects the undefined symbols and sorts them into the two frameworks.
set -euo pipefail
cd "$(dirname "$0")/.."
syms=$(TYPEDB_STUBS_DISABLED=1 lake build tests 2>&1 | grep -o "undefined symbol: [A-Za-z_0-9]*" | awk '{print $3}' | sort -u || true)
emit() { # name install-name prefix-regex
  local list
  list=$(printf '%s\n' $syms | grep -E "$3" | sed 's/^/_/' | paste -sd, - | sed 's/,/, /g')
  cat > "ffi/macos/$1.tbd" <<TBD
--- !tapi-tbd
tbd-version:     4
targets:         [ x86_64-macos, arm64-macos ]
install-name:    '$2'
current-version: 1
exports:
  - targets:     [ x86_64-macos, arm64-macos ]
    symbols:     [ $list ]
...
TBD
}
emit CoreFoundation /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation '^(CF|kCF)'
emit Security /System/Library/Frameworks/Security.framework/Versions/A/Security '^(Sec|kSec)'
echo "wrote ffi/macos/CoreFoundation.tbd and ffi/macos/Security.tbd"
