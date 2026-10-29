# typedb-lean

A [TypeDB 3](https://typedb.com) client for Lean 4, built on the official C driver.

- **Transactions checked at compile time.** `Tx .read α`, `Tx .write α` and `Tx .schema α` are different types, so an `insert` inside a read transaction does not compile. `Driver.runSync` commits on success and rolls back on any error, and can retry commit conflicts.
- **Async through `Std.Async`.** `Driver.run` returns an `EAsync TypeDBError α` that runs on its own thread; combine runs with `EAsync.concurrently` and `EAsync.concurrentlyAll`.
- **Typed TypeQL.** `typeql!"… {value} …"` escapes every interpolated value, so user data cannot change a query's structure.
- **Fast decoding.** Rows are decoded straight into Lean structures, many rows per native call. Scans and lookups match the official Rust driver (see [Performance](#performance)).
- **A lightweight ORM.** `deriving Entity` and `deriving Relation` give you inserts, reads, updates, deletes, subtypes, relations that play roles, polymorphic reads, schema generation and schema verification.
- **Migrations.** Versioned up and down steps, with their history and checksums stored in the database.

```lean
import TypeDB
open TypeDB

@[typedb "person"]
structure Person where
  email : Key String
  name : String
  age : Option Int64 := none
  deriving Entity

structure Friendship where
  a : Role "friend" (Ref Person)
  b : Role "friend" (Ref Person)
  deriving Relation

def main : IO Unit := do
  let r ← (Driver.withDriver { address := "127.0.0.1:1729" } fun d => do
    d.ensureDatabase "social"
    d.runSync "social" .schema (Schema.defineTx [TypeSpec.of Person, TypeSpec.of Friendship])
    d.runSync "social" .write do
      let ann ← Entity.insert { email := "ann@example.com", name := "Ann" : Person }
      let bob ← Entity.insert { email := "bob@example.com", name := "Bob", age := some 41 : Person }
      discard <| Relation.insert { a := ann, b := bob : Friendship }
    d.runSync "social" .read do
      for row in stream (α := Col "n" String) typeql!"match $p isa person, has name $n;" do
        IO.println row.val
    : EIO TypeDBError Unit).toBaseIO
  if let .error e := r then IO.eprintln e
```

## Installing

Add the package to your `lakefile.lean`:

```lean
require «typedb-lean» from git "https://github.com/Volland/typedb-lean" @ "v0.1.0"
```

The first `lake build` clones `typedb-driver` at the version in `TYPEDB_VERSION` (currently 3.14.0) and builds its C library with cargo, so you need a Rust toolchain. To link a library you built yourself instead, set `TYPEDB_DRIVER_LIB=/path/to/libtypedb_driver_clib.a`.

Supported platforms are Linux x86_64, Linux arm64 and macOS arm64. Lean is pinned to `v4.35.0`.

## Documentation

- [Guide](docs/guide/README.md): getting started, transactions, async, queries, decoding, the ORM, migrations and performance.
- [Example](examples/social/Social.lean): a small social network that uses every feature. Run it with `lake exe social` (it uses `TYPEDB_ADDRESS`, default `127.0.0.1:1729`).
- [API reference](https://volland.github.io/typedb-lean/api/TypeDB.html), built from the docstrings by doc-gen4 (locally: `cd docbuild && lake build TypeDB:docs`).
- [Changelog](CHANGELOG.md) and [releasing](RELEASING.md).
- Design: [ADR 0002](docs/adr/0002-typedb-lean-architecture.md), [decisions](tg.md/decisions.md), [constraints](tg.md/constraints.md), and the OpenSpec specs in [openspec/specs](openspec/specs).

## Testing

```sh
lake test             # unit tests, then integration tests in a typedb/typedb container
lake test -- --unit   # unit tests only, no Docker needed
lake test -- orm:     # only the tests whose names contain "orm:"
TYPEDB_ADDRESS=127.0.0.1:1729 lake test   # use a server you already run
```

The integration tests start one `typedb/typedb:<pinned version>` container on a random port, give every test a fresh database, and remove the container afterwards, also after Ctrl-C.

## Performance

`lake exe bench` runs the same workloads with this library and with the official Rust driver (`bench/rust`, same version) against one container, and writes `bench/report.json`. Results on an Apple M-series laptop with TypeDB 3.14.0 in Docker:

| Workload | typedb-lean | Rust driver |
|---|---|---|
| Scan of 100,000 rows decoded into structures | 155,368 rows/s | 142,061 rows/s |
| Point lookup in its own read transaction, p50 / p99 | 1.05 ms / 1.52 ms | 1.03 ms / 2.39 ms |
| Bulk insert of 10,000 entities in one transaction | 4.75 s | 4.71 s |
| 16 concurrent read transactions of 10,000 rows | 367 ms | 607 ms |

The targets, which the benchmark checks, are a scan at least 80% of the Rust driver's rows/s and a lookup p50 at most 1.1 times the Rust driver's. CI runs smaller sizes with a 10% margin.

## License

Apache-2.0.
