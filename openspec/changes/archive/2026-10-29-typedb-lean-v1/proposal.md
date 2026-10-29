## Why

Lean 4 has no TypeDB client. Programs that want a typed knowledge graph from Lean must shell out or hand-write FFI. TypeDB 3.x ships an official C driver, and Lean 4.35 ships `Std.Async` and `Std.Time`. Together they make a fast, functional, typed client practical now: no JSON detours on the hot path, transactions that cannot be misused, and Lean structures mapped to TypeDB types.

## What Changes

- New Lean package `typedb-lean` (root namespace `TypeDB`, Apache-2.0, Lean `v4.35.0`) targeting TypeDB 3.x only.
- Native layer: the TypeDB C driver is built from a pinned `typedb-driver` tag through Lake and cargo, and an environment variable overrides it with a prebuilt library. A C shim converts between Lean objects and driver types and adds a batched row-decoding path.
- Connection API: address, credentials, optional TLS, driver options, and database management (create, delete, exists, list).
- Transaction monad `Tx (mode) α` indexed by Read ≤ Write ≤ Schema. Queries that need a stronger mode do not typecheck. `Driver.run` opens the transaction, commits on success, closes or rolls back on failure, and retries conflicts only when asked.
- Async: transactions run as `Std.Async` `EAsync TypeDBError` computations on dedicated threads, with a blocking `runSync` variant.
- Queries: the `typeql!` interpolation macro escapes spliced values through `ToTypeQL`, and splicing raw text requires an explicit marker.
- Decoding: a row decoder applicative, the `FromConcept` class, and `deriving FromRow`. Fetch documents decode through `Lean.FromJson`. Results come back as strict arrays or as streams scoped to the transaction.
- Precise value types: Int64, Float, Bool, String, `Decimal`, `Std.Time` dates and datetimes, and `Duration`.
- Lightweight ORM: `deriving Entity` / `deriving Relation` generate insert, get, update and delete statements, decoders and a schema `define`. It supports keys, optional and multi-valued attributes, subtyping via `extends`, polymorphic decoding into sum types, relations as role players, and `Ref` by key or IID. `verifySchema` checks the mapping against the live database.
- Versioned migrations with up and down steps. Each step runs atomically with its history record. A checksum drift check rejects edited applied steps.
- Benchmarks against the native Rust driver, with throughput and latency targets.
- Docs: guide, API docs, design records in `tg.md/` and ADRs, plus the runnable `examples/social` application.
- Integration tests against a real TypeDB container, started and cleaned up by the test runner. CI runs on Linux x86_64, Linux arm64 and macOS arm64.

## Capabilities

### New Capabilities

- `native-driver`: building and linking the pinned TypeDB C driver, the override, and supported platforms.
- `connection`: connecting to a server with credentials and TLS, and managing databases.
- `transactions`: the mode-indexed transaction monad, commit and rollback semantics, conflict retry, and the typed error model.
- `async`: running transactions concurrently as `Std.Async` computations, and the blocking variant.
- `query`: the TypeQL interpolation macro, escaping of values, and raw splicing.
- `decoding`: decoding concept rows and fetch documents into Lean values, value type mapping, and strict and streaming result consumption.
- `orm`: deriving mappings for entities and relations, generated CRUD, references, subtyping, polymorphism, schema generation and verification.
- `migrations`: versioned up and down schema migrations with history and checksum checks.
- `performance`: benchmark workloads and throughput and latency targets relative to the Rust driver.

### Modified Capabilities

None. This is the first change in the project.

## Impact

- New code: `TypeDB/` Lean sources, `ffi/typedb_lean.c`, `lakefile.lean`, `bench/` (Lean plus a companion Rust program), `examples/social/`, `tests/`, `docs/guide/`, `.github/workflows/`.
- New external dependencies: the `typedb-driver` source at a pinned 3.x tag, a Rust toolchain at build time, Docker for integration tests, and the `typedb/typedb` image at the matching version.
- Docs graph: there are no lat.md sections yet beyond `tg.md/code-ontology`. This change adds `tg.md/architecture.md` (Concept), `tg.md/decisions.md` (Decision), `tg.md/constraints.md` (Constraint) and `tg.md/tests.md` (Scenario). `tg.md/architecture.md` lists all nine capabilities in its `openspec:` frontmatter.
- Binding constraints, recorded as `Constraint` sections: the TypeDB 3 C API blocks the calling thread and is pull-based; C iterators are valid only while their transaction is open; the driver has no server-side parameter binding; TypeDB uses optimistic concurrency, so commits can conflict; GitHub macOS runners have no Docker.
- Requirements added: all of them are new and cited as `[[openspec:<capability>#<Requirement>]]`, for example `[[openspec:transactions#Mode-indexed transactions]]`, `[[openspec:decoding#Batched row decoding]]` and `[[openspec:performance#Scan throughput target]]`.
