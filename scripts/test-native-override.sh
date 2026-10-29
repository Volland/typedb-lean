#!/usr/bin/env bash
# Checks the TYPEDB_DRIVER_LIB override of the native driver build.
set -euo pipefail
cd "$(dirname "$0")/.."
lake build typedb_driver_clib >/dev/null
lib=$(ls .lake/build/typedb-driver/*/target/release/libtypedb_driver_clib.a | head -1)

# @tg: verifies:: [[openspec:native-driver#Prebuilt library override#Override skips cargo]] {level: e2e}
out=$(TYPEDB_DRIVER_LIB="$PWD/$lib" lake build typedb_driver_clib -v 2>&1)
if echo "$out" | grep -q "cargo"; then
  echo "FAIL: cargo ran although TYPEDB_DRIVER_LIB was set"; echo "$out"; exit 1
fi
echo "ok    override skips cargo"

# @tg: verifies:: [[openspec:native-driver#Prebuilt library override#Invalid override fails clearly]] {level: e2e}
if out=$(TYPEDB_DRIVER_LIB=/nonexistent/libtypedb.a lake build typedb_driver_clib 2>&1); then
  echo "FAIL: build succeeded with a missing TYPEDB_DRIVER_LIB"; exit 1
fi
if ! echo "$out" | grep -q "TYPEDB_DRIVER_LIB is set to '/nonexistent/libtypedb.a'"; then
  echo "FAIL: error does not name the variable and path"; echo "$out"; exit 1
fi
echo "ok    invalid override fails clearly"
