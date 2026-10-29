---
type: Decision
status: accepted
date: 2026-10-29
---
# Decisions

The design choices of typedb-lean v1, each with the alternatives rejected and the constraints behind it. ADR `adr:0002` (`docs/adr/0002-typedb-lean-architecture.md`) summarises them.

## TypeDB 3 only

The library targets TypeDB 3.x servers and the 3.x C API, where a query answers concept rows or documents; 2.x and its rules are out of scope.

- motivated_by:: [[constraints#Blocking pull API]] {weight: secondary}
- part_of:: [[capabilities#native-driver]]

Rejected: also supporting 2.x, whose concept API is entirely different.

## Pinned source build

Lake clones `typedb-driver` at the tag in `TYPEDB_VERSION`, builds its C crate with cargo and links it with the shim; `TYPEDB_DRIVER_LIB` swaps in a prebuilt library.

- part_of:: [[capabilities#native-driver]]

Rejected: downloading prebuilt archives (their platforms are not guaranteed) and requiring a system install (poor onboarding). The same version picks the `typedb/typedb` image the tests start.

## Mode-indexed transaction monad

`Tx m α` is an irreducible `ReaderT TxCtx (EIO TypeDBError) α`; operations need `[TxMode.Allows m need]` with read ≤ write ≤ schema; `Driver.runSync` commits on success and closes on failure.

- part_of:: [[capabilities#transactions]]

Irreducible keeps `Tx .read` and `Tx .write` apart; `ReaderT` over `EIO` lets the compiler turn loops into plain loops. A structure wrapper cost a stack frame per loop iteration. Rejected: a free monad (allocates per step) and typeclasses only (weak mode indexing). Modelled on hasql's `Session` and Doobie's `Transactor`.

## Async on dedicated threads

`Driver.run` returns a `Std.Async.EAsync TypeDBError α` whose body runs on a dedicated thread, so blocking driver calls never occupy the task pool.

- motivated_by:: [[constraints#Blocking pull API]] {weight: primary}
- motivated_by:: [[constraints#Lean toolchain]] {weight: secondary}
- part_of:: [[capabilities#async]]

Rejected: plain `Task` results (no Std combinators) and a library-specific async monad.

## Typed interpolation

`typeql!"…{e}…"` renders each value with `ToTypeQL`, escaping strings; only `Raw` splices text verbatim, and the transaction mode is inferred from the literal keywords.

- motivated_by:: [[constraints#No parameter binding]] {weight: primary}
- part_of:: [[capabilities#query]]

Rejected: embedding TypeQL as Lean syntax (the grammar would have to be mirrored) and builder combinators (verbose).

## Rows-first decoding

`RowDecoder` is an applicative over named columns with a plan of columns and flags; `deriving FromRow` maps fields to variables; fetch documents use `Lean.FromJson`.

- part_of:: [[capabilities#decoding]]

Rejected: JSON only (a parse per result, IIDs lost) and raw concepts only. Modelled on hasql's row decoders.

## Scoped streaming

Strict `query` arrays, `queryFold` and `for` loops over `stream q` pull rows in batches inside the transaction; the iterator is released on completion, `break` or error.

- motivated_by:: [[constraints#Iterator lifetime]] {weight: primary}
- part_of:: [[capabilities#decoding]]

Rejected: a lazy stream that outlives its transaction.

## Thin bindings and a batched hot path

Every C function gets a thin binding; `tdb_rows_next_batch` decodes the planned columns of many rows in one native call. Prefetch defaults to 512 and closes run on a background thread.

- motivated_by:: [[constraints#Blocking pull API]] {weight: primary}
- motivated_by:: [[constraints#Thread-local last error]] {weight: primary}
- motivated_by:: [[constraints#Lean FFI ownership]] {weight: primary}
- motivated_by:: [[constraints#Driver conventions]] {weight: secondary}
- part_of:: [[capabilities#decoding]]
- part_of:: [[capabilities#performance]]

The prefetch and the closer thread closed the measured gap to the Rust driver: the C API's default prefetch made scans wait on the network, and `transaction_drop_sync` waits where Rust's `drop` does not.

## Typed errors and opt-in retry

`TypeDBError` separates connection, server, conflict, decode, schema and migration errors; `retry := .conflicts n backoff` re-runs a body only on commit conflicts.

- motivated_by:: [[constraints#Optimistic concurrency]] {weight: primary}
- motivated_by:: [[constraints#Driver conventions]] {weight: secondary}
- part_of:: [[capabilities#transactions]]

Rejected: never retrying (every user rewrites the loop) and string errors.

## Lean-first ORM

`deriving Entity` and `deriving Relation` read `@[typedb "label"]` and the field markers `Key`, `Role` and `Attr`, and generate the mapping, a `Keyed` instance and field handles.

- motivated_by:: [[constraints#Lean toolchain]] {weight: primary, note: "no attributes on fields"}
- part_of:: [[capabilities#orm]]

Subtypes come from `extends`, relations can play roles, `Ref` is a key or an IID, and `deriving Polymorphic` dispatches on instance labels. Rejected: schema-first codegen and decode-only mapping.

## Precise value types

Decimal and Duration are exact library types, dates use `Std.Time`, and datetime-tz is `DatetimeTZ` (instant, offset, zone) convertible to `Std.Time.DateTime`.

- motivated_by:: [[constraints#Lean toolchain]] {weight: primary}
- motivated_by:: [[constraints#Driver conventions]] {weight: secondary, note: "IANA offsets are resolved on decode"}
- part_of:: [[capabilities#decoding]]

Rejected: Int, Float and ISO strings (lossy) and raw C structs.

## Versioned reversible migrations

Each step has a version, a name, `up`, `down` (or `.irreversible`) and a fingerprint; it runs in one schema transaction with its history record, and checksum drift stops `migrate`.

- part_of:: [[capabilities#migrations]]

Rejected: forward-only steps and TypeQL files only.

## Lean testcontainer harness

`lake test` starts one `typedb/typedb` container on a random port, gives every test a fresh database and removes the container on exit or signal; `TYPEDB_ADDRESS` skips Docker.

- motivated_by:: [[constraints#No Docker on macOS CI]] {weight: primary}

Rejected: docker-compose and a container per test.

## Benchmarks against the Rust driver

`lake exe bench` and `bench/rust` run the same workloads on one server and enforce scan ≥ 80% of Rust's rows/s and lookup p50 ≤ 1.1 × Rust's.

- part_of:: [[capabilities#performance]]

## Framework stubs for macOS

On macOS the build links CoreFoundation and Security through minimal TAPI stubs in `ffi/macos/`, regenerated by `scripts/gen-macos-stubs.sh`.

- motivated_by:: [[constraints#macOS SDK stubs]] {weight: primary}
- part_of:: [[capabilities#native-driver]]

## Static website on GitHub Pages

`site/` is plain HTML, CSS and JavaScript with no build step; `docs.yaml` publishes it with the doc-gen4 API reference under `api/`. It holds the home page, docs, examples, benchmarks, a mini book and a blog.

- motivated_by:: [[decisions#Benchmarks against the Rust driver]] {weight: secondary, note: "the benchmarks page reports its results"}

Shared header, footer, code highlighting, tabs and copy buttons come from `site/assets/site.js`; the logo is `site/assets/logo.svg`, three entities joined by a relation diamond holding a λ. Lean snippets on the site that are not copied from the guide or the example are compile-checked against the library before publishing. Rejected: a static site generator, which would add a toolchain to CI for a handful of pages.

## Releases from version tags

A release is a tag `vX.Y.Z` on `main`. `release.yaml` checks it against the lakefile and changelog, runs the tests and the benchmark, and publishes the GitHub release.

- motivated_by:: [[decisions#Pinned source build]] {weight: secondary, note: "Lean packages ship as source; Lake users and Reservoir consume the tag"}
- part_of:: [[capabilities#native-driver]]

`scripts/check-versions.sh` keeps the lakefile version, the newest changelog entry and the tag in agreement. A prepared draft release keeps its notes when the tag publishes it. Rejected: publishing build artifacts, since Lake builds from source and the driver from its pinned tag.
