#!/usr/bin/env bash
# Checks that the release version agrees everywhere: the lakefile, the changelog's newest
# release and, when given, the tag being released (check-versions.sh v0.1.0).
set -euo pipefail
cd "$(dirname "$0")/.."
lake=$(sed -n 's/.*version := v!"\([^"]*\)".*/\1/p' lakefile.lean | head -1)
log=$(sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' CHANGELOG.md | head -1)
[ "$lake" = "$log" ] || { echo "lakefile version $lake != CHANGELOG version $log" >&2; exit 1; }
if [ $# -gt 0 ]; then
  [ "$1" = "v$lake" ] || { echo "tag $1 != v$lake" >&2; exit 1; }
fi
grep -q "^\[$lake\]: " CHANGELOG.md || { echo "CHANGELOG has no link for [$lake]" >&2; exit 1; }
echo "version $lake"
