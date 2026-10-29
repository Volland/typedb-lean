---
type: Concept
openspec: [native-driver, connection, transactions, async, query, decoding, orm, migrations, performance]
---
# Architecture

typedb-lean is a TypeDB 3 client for Lean 4 in layers: a C shim over the official C driver, a mode-indexed transaction monad, typed TypeQL, batched decoding, and an ORM with migrations on top.

## Native layer

`ffi/typedb_lean.c` converts between Lean objects and the C driver's types; `TypeDB/Native.lean` declares its functions. Handles are external objects released by finalizers or explicit closes.

- part_of:: [[capabilities#native-driver]]

The lakefile builds the driver from the tag in `TYPEDB_VERSION` with cargo. Every shim function reads the driver's thread-local error right after its call. Transaction closes go to one background thread, like the Rust driver's non-blocking `drop`.

## Connection

`TypeDB.Driver` opens one connection per server, shared by every transaction and thread, and manages databases. There is no pool: the driver multiplexes transactions.

- part_of:: [[capabilities#connection]]

## Transactions

`Tx m α` is a transaction body of mode `m`. `Driver.runSync` opens, runs, commits or closes; `Driver.run` does the same on a dedicated thread as a `Std.Async.EAsync` computation.

- part_of:: [[capabilities#transactions]]
- part_of:: [[capabilities#async]]

Operations require `[TxMode.Allows m need]`, so a body cannot run a query that needs a stronger transaction. Errors are `TypeDBError` values, and commit conflicts can be retried by policy.

## Queries and decoding

`typeql!` builds queries with escaped values and an inferred mode. `RowDecoder` reads named columns; its plan tells the native batch call which concepts and parts to fetch.

- part_of:: [[capabilities#query]]
- part_of:: [[capabilities#decoding]]

Results are strict arrays, folds or `for` loops over a stream that cannot leave its transaction. Fetch documents decode through `Lean.FromJson`.

## ORM and migrations

`deriving Entity` and `deriving Relation` map structures to TypeDB types; `Schema` generates and verifies their schema; `Migration` steps evolve it with history kept in the database.

- part_of:: [[capabilities#orm]]
- part_of:: [[capabilities#migrations]]

## Benchmarks

`lake exe bench` runs the same workloads with this library and with the official Rust driver against one server and checks the performance targets.

- part_of:: [[capabilities#performance]]
