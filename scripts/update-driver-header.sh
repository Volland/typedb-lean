#!/usr/bin/env bash
# Regenerates ffi/typedb_driver.h from the pinned typedb-driver source with cbindgen
# (cargo install cbindgen). Run after changing TYPEDB_VERSION, then update the version in
# bench/rust/Cargo.toml and run scripts/gen-macos-stubs.sh on macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(tr -d '[:space:]' < TYPEDB_VERSION)
lake build typedb_driver_clib
src=.lake/build/typedb-driver/$version
(cd "$src/c" && cbindgen --quiet --config cbindgen.toml --crate typedb_driver_clib --output "$OLDPWD/ffi/typedb_driver.h")
echo "wrote ffi/typedb_driver.h for typedb-driver $version"
