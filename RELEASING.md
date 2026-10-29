# Releasing

typedb-lean is a Lean package, distributed as source: users `require` it from GitHub at a version tag, and [Reservoir](https://reservoir.lean-lang.org) indexes the tags (`versionTags := .startsWith "v"` in the lakefile). A release is a tag `vX.Y.Z` on `main` plus a GitHub release with the changelog section as notes.

## What runs where

| Workflow | Trigger | Does |
|---|---|---|
| `ci.yaml` | push to `main`, pull requests | build, unit and integration tests on Linux x86_64 and arm64, build and unit tests on macOS arm64, benchmark smoke on Linux x86_64 |
| `release.yaml` | tag `v*` | checks the tag against the lakefile and changelog, runs the full tests and the benchmark, publishes the GitHub release with `bench/report.json` |
| `docs.yaml` | push to `main`, tags | builds the API docs with doc-gen4 and publishes them with the website (`site/`) to GitHub Pages |

## Cutting a release

1. Make sure CI is green on `main`.
2. Move the entries under `## [Unreleased]` in `CHANGELOG.md` into a new `## [X.Y.Z] - YYYY-MM-DD` section, add its compare link at the bottom, and set `version := v!"X.Y.Z"` in `lakefile.lean`. Update the `@ "vX.Y.Z"` in `README.md` and `docs/guide/01-getting-started.md`.
3. Check that they agree: `scripts/check-versions.sh vX.Y.Z`.
4. Commit, then tag and push:

   ```sh
   git tag -a vX.Y.Z -m "typedb-lean vX.Y.Z"
   git push origin main vX.Y.Z
   ```

5. `release.yaml` verifies the tag and publishes the release. If a draft release for the tag already exists, it publishes that draft and keeps its notes; otherwise it creates the release with the changelog section as notes.

## Bumping TypeDB

1. Write the new version in `TYPEDB_VERSION` and in `bench/rust/Cargo.toml` (`typedb-driver = "=X.Y.Z"`).
2. Regenerate the header: `scripts/update-driver-header.sh` (needs `cargo install cbindgen`).
3. On macOS, regenerate the framework stubs: `scripts/gen-macos-stubs.sh`.
4. Run `lake test` and `lake exe bench`; the unit tests check that every pin agrees.

## Bumping Lean

Change `lean-toolchain` and `docbuild/lean-toolchain`, set the matching doc-gen4 `rev` in `docbuild/lakefile.toml`, and run the tests: the `#guard_msgs` checks in `tests/CompileChecks.lean` pin compiler messages, and the shim mirrors Lean's object layout (see the header comment of `ffi/typedb_lean.c`).
