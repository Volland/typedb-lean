# Changelog

All notable changes to typedb-lean. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-29

First release: a TypeDB 3 client for Lean 4 over the official C driver (typedb-driver 3.14.0), for Lean `v4.35.0`.

### Added

- Native layer: the C driver built from the pinned `typedb-driver` tag by Lake and cargo, or a prebuilt library through `TYPEDB_DRIVER_LIB`; a C shim that decodes many rows per native call.
- Connections with credentials and optional TLS; database create, delete, list and schema.
- `Tx .read/.write/.schema`: transaction bodies whose mode is checked at compile time; `Driver.runSync` commits on success and rolls back on error; typed `TypeDBError`; opt-in retry of commit conflicts.
- `Driver.run`: transactions as `Std.Async.EAsync` computations on dedicated threads.
- `typeql!`: TypeQL with escaped, typed interpolation and an inferred transaction mode; `Raw` for verbatim text.
- Row decoders, `deriving FromRow`, exact value types (`Decimal`, `Duration`, `DatetimeTZ`, `Std.Time` dates), strict, folded and streamed results, and `fetch` through `Lean.FromJson`.
- A lightweight ORM: `deriving Entity`, `Relation` and `Polymorphic`; references by key or IID; subtypes through `extends`; relations playing roles; multi-valued attributes; schema generation and verification.
- Versioned up/down migrations with history and checksum drift detection stored in the database.
- Benchmarks against the official Rust driver (`lake exe bench`), the `social` example, a guide and API docs.

### Known limitations

- typedb-driver 3.14.0 retains about 600 bytes per opened transaction (upstream, also in its Rust API).
- Windows is not supported. On GitHub's macOS runners only the unit tests run, because they cannot run Linux containers.

[Unreleased]: https://github.com/Volland/typedb-lean/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Volland/typedb-lean/releases/tag/v0.1.0
