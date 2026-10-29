## Context

The repository is empty apart from the OpenSpec, ADR and tg scaffolding (see proposal.md, Why). The design is shaped by facts about the TypeDB 3 C driver and the Lean 4.35 toolchain. They are recorded below as constraints, so each decision can name the constraint that motivates it.

### Constraints

- **C1 Blocking pull API.** The TypeDB 3 C driver (`typedb-driver/c`, a Rust core exposed through cbindgen) returns promises that block the calling thread when resolved, and iterators that block on each `next`. It binds: async (D4), FFI (D8). Source: typedb-driver C API.
- **C2 Iterator lifetime.** Row and document iterators are valid only while their transaction is open. It binds: streaming (D7), [[openspec:decoding#Scoped streaming]]. Source: typedb-driver C API.
- **C3 No parameter binding.** The driver accepts queries as text only, with no bound parameters, so values must be spliced in on the client. It binds: query DSL (D5), [[openspec:query#Injection-safe escaping]]. Source: typedb-driver C API.
- **C4 Optimistic concurrency.** Concurrent write transactions can fail at commit with a conflict. It binds: errors and retry (D9). Source: TypeDB docs.
- **C5 Thread-local last error.** C driver failures return null or false and leave the error in thread-local state, read with `check_error` and `get_last_error`. It binds: the shim must read the error on the same thread that made the call (D8). Source: typedb-driver C API.
- **C6 No Docker on macOS CI.** GitHub macOS runners cannot run Linux containers. It binds: CI matrix (D14), [[openspec:native-driver#Supported platforms]]. Source: GitHub Actions.
- **C7 Lean FFI ownership.** Lean `@[extern]` functions receive owned or borrowed (`@&`) `lean_object*`, and native handles must be wrapped as external objects with finalizers. It binds: D8, [[openspec:native-driver#Native resources are released]]. Source: Lean FFI docs.
- **C8 Toolchain.** Lean `v4.35.0` ships `Std.Async` (`EAsync ε`, `ETask ε`, `concurrently`, `race`) and `Std.Time` (whose zoned type is `Std.Time.DateTime`), but no decimal type. It binds: D4, D12. Source: the Lean toolchain.
- **C9 Upstream per-transaction retention.** `typedb-driver` 3.14.0 keeps about 600 bytes per transaction it has opened, in the Rust driver as much as in the C driver (measured over 40,000 transactions). It binds: [[openspec:native-driver#Native resources are released]], which therefore covers only what this library allocates. Source: measurement against typedb-driver 3.14.0.
- **C10 Lean's linker and macOS SDK stubs.** Lean's bundled `ld64.lld` cannot read the `.tbd` stubs of recent macOS SDKs (their `arm64e.x1` targets are unknown to it). It binds: D2, D16. Source: Lean 4.35 toolchain on macOS 27.
- **C11 No attributes on structure fields.** Lean 4.35 rejects attributes on structure fields ("Attributes cannot be added to fields"). It binds: D10. Source: the Lean toolchain.
- **C12 Driver conventions.** The driver formats its own error codes in brackets (`[CXN02]`) and the server's without; the server rejects a query naming an unknown type label (`INF2`) rather than answering with no rows; an IANA-zoned datetime-tz arrives as UTC seconds plus a zone name, without an offset; the C API's default query options use a small prefetch. It binds: D5, D9, D10, D12, D8. Source: the 3.14 driver and server.

## Goals / Non-Goals

**Goals:**
- A typed, functional client whose hot read path does not go through JSON and whose per-row cost is dominated by the server, not the FFI.
- Misuse that cannot be expressed: no write in a read transaction, no iterator outliving its transaction, no unescaped value in a query.
- A lightweight ORM that covers TypeDB's distinctive modelling (subtyping, n-ary relations, relations as players) without hiding TypeQL.

**Non-Goals:**
- TypeDB 2.x support, or TypeQL rules (removed in 3.x).
- A full TypeQL AST or compile-time TypeQL parsing (deferred; typed interpolation leaves room for it).
- Schema-first code generation from `.tql` files.
- Windows support.
- A connection pool: one driver multiplexes concurrent transactions.
- Struct value types.

## Decisions

### D1 Target TypeDB 3.x only
Support only TypeDB 3.x servers and the 3.x C API (`transaction_query` returning `QueryAnswer` with concept rows or documents).
- Rejected: supporting 2.x as well. Its concept API is entirely different and the sibling server checkout is 3.7.2.
- motivated_by: C1 (the shape of the 3.x API)

### D2 Pinned source build of the C driver through Lake
A Lake target fetches `typedb-driver` at one pinned 3.x tag, builds the C crate with `cargo build --release`, and links the static library with `ffi/typedb_lean.c`. Setting `TYPEDB_DRIVER_LIB` skips the cargo build. The pin is also used to choose the `typedb/typedb` Docker image for tests.
- Rejected: downloading prebuilt archives (depends on which platforms TypeDB publishes artifacts for, including Linux arm64); requiring a system install (poor onboarding).
- Risk: the C crate may build only through Bazel. The spike task (1.1) checks this; if it is Bazel-only, we vendor a minimal `Cargo.toml` and a cbindgen config pinned to the same tag.
- motivated_by: [[openspec:native-driver#Pinned driver build]], C7

### D3 Mode-indexed `Tx` monad with a Transactor
`inductive TxMode | read | write | schema` with a `LE` instance. `Tx (m : TxMode) α` is an irreducible definition of `ReaderT TxCtx (EIO TypeDBError) α`: irreducible so that `Tx .read α` and `Tx .write α` do not unify, and a `ReaderT` over `EIO` so that the compiler turns loops over it into plain loops (a structure wrapper compiled every `for` iteration into a closure application and grew the stack by about 190 bytes per iteration). `EIO TypeDBError` gives one error channel; `IO` errors inside a body become `TypeDBError.io`. Operations take an instance `[TxMode.Allows m need]`, resolved at compile time. `MonadTypeDB m n` is `MonadLiftT (Tx m) n`, for user stacks. `Driver.runSync db mode body` acts as the Transactor: it opens the transaction, runs the body, commits on success (write and schema), and closes on any error using `tryFinally`.
- Rejected: a free monad interpreted later (it allocates per step, against the performance goal); typeclasses only (mode indexing becomes awkward and error messages get worse).
- Inspired by hasql's `Session` and Doobie's `ConnectionIO` with `Transactor`.

### D4 Async through Std.Async on dedicated threads
`Driver.run : … → EAsync TypeDBError α`. The body runs inside `IO.asTask (prio := .dedicated)`, so the blocking C calls never occupy pool workers. `Driver.runSync : … → EIO TypeDBError α` runs on the calling thread. Inside a transaction, the body stays sequential.
- Rejected: plain `IO (Task (Except …))` (does not compose with Std combinators); a project-specific async monad (fragments the ecosystem).
- motivated_by: C1, C8

### D5 `typeql!` typed interpolation
A term elaborator over interpolated strings. Each `{e}` elaborates to `ToTypeQL.render e`. Instances exist for String (escaped: `\\`, `"`, control characters as `\n`, `\t`, `\uXXXX`), the integer types, Float (with finite checks), Bool, Decimal, the Std.Time types, Duration, IID and `Ref`. `Raw` is the only way to splice text verbatim. A missing instance is a compile-time error.
- Rejected: embedding TypeQL as Lean syntax (the TypeQL 3 grammar would have to be mirrored); builder combinators (verbose and unlike TypeQL docs).
- motivated_by: C3

### D6 Rows-first decoding
`RowDecoder α` is an applicative over a compiled `Plan` (column names and kind bytes) plus a pure assembly function from a row of `Value`s. The `FromConcept` class gives each value type a kind and an extractor. `deriving FromRow` maps fields to variables of the same name, and `Option` fields become optional columns. Fetch documents decode through `Lean.FromJson`.
- Rejected: JSON only (a parse per result, and IIDs and types are lost); raw concepts only (pushes the mapping onto users).
- Inspired by hasql's `Decoders.Row`.

### D7 Strict results plus scoped streaming
`query : Query need α → Tx m (Array α)` collects every batch into one array. `queryFold` and a `ForIn` instance on `stream q` pull batches inside the body. The iterator handle type is not exported. The `ForIn` implementation releases the iterator on normal completion, on `break` and on exceptions.
- Rejected: a lazy stream that escapes the transaction (breaks the bracket guarantee).
- motivated_by: C2

### D8 Thin bindings plus a batched hot path
Each C function used gets a thin 1:1 binding (an `@[extern]` with an external class and a finalizer that calls the matching `*_drop`). Every shim wrapper calls `check_error` immediately after the C call on the same thread and returns the error as an `EIO NativeError` failure. The hot path `tdb_rows_next_batch(iter, cols, flags, k)` pulls up to `k` rows and, for each planned column, builds the `Concept` (with only the label or IID the flags ask for) directly, returning `Array (Array (Option Concept))` in one call. Two measured choices close the gap to the Rust driver: transactions default to a prefetch of 512 answers (the C API's default is small enough to make scans wait on the network), and closing a transaction is handed to one background thread instead of waiting in `transaction_drop_sync` (the Rust driver's `drop` does not wait either); deleting a database and closing the driver wait for pending closes.
- Rejected: thin bindings only (about 3N crossings and N concept allocations per N-column row); thin first and batched later (the target in [[openspec:performance#Scan throughput target]] makes it necessary).
- motivated_by: C1, C5, C7, [[openspec:decoding#Batched row decoding]]

### D9 Typed errors and opt-in conflict retry
`inductive TypeDBError | connection (code msg) | server (code msg) | conflict (msg) | decode (column expected got) | schemaMismatch (issues) | migration (version msg) | internal (msg)`. The code is parsed from the driver's `[XXX99]` prefix, and conflicts are recognised by their error code family. `run (retry := .conflicts n (backoff := .exp base))` re-runs the whole body only on `.conflict`. The default is `.none`.
- Rejected: never retrying (every user rewrites the loop); `IO.userError` strings (no way to match on kinds).
- motivated_by: C4

### D10 Lean-first ORM through deriving handlers
`deriving Entity` and `deriving Relation` read `@[typedb "label"]` on the structure and the field type markers `Key τ`, `Role "r" τ` and `Attr "l" τ` (reducible abbreviations, so a `Key String` is a `String`; Lean does not accept attributes on fields), and generate a `Mapped` instance (label, kind, parent, field specs, encoder, decoder), a `Keyed` instance and `S.field.<name>` handles for `Entity.update`. Generated code types each field through its projection, so it never prints field types. A structure that `extends` a mapped parent emits `sub parent`. Reads fetch `$x has $a` rows and `$x links ($role: $p)` rows and group them by IID, so multi-valued attributes cost no extra queries. `deriving Polymorphic` dispatches on each instance's type label, which the driver returns with every instance.
- Rejected: schema-first codegen (more complex, harder to customise); decode-only mapping (barely an ORM).
- Inspired by Ecto schemas and Rust's `sqlx::FromRow`.

### D11 `Ref` as key or IID
`inductive Ref (α) | key (k : KeyOf α) | iid (i : IID)`, where `KeyOf α` is the type of α's key field (or `Empty` when α has no key, so `.key` cannot be built). The generated match for a key is `$x isa label, has keyattr {k}`, and for an IID it is `$x iid {i}`. Insert returns `.iid` from the inserted row.
- Rejected: key only (forces synthetic keys on relations); IID only (no reference without a prior query).

### D12 Precise value types
Values map as follows: integer to Int64 (with range-checked Int and Nat), double to Float (rendered exactly from its bits), Decimal as `{ integer : Int64, fractional : UInt64 }` in units of 10⁻¹⁹ (the C driver's representation), date to `Std.Time.PlainDate`, datetime to `PlainDateTime`, datetime-tz to `DatetimeTZ` (UTC instant, UTC offset, and an IANA zone or fixed offset) with conversions to and from `Std.Time.DateTime`, and duration as `{ months : UInt32, days : UInt32, nanos : UInt64 }`. The offset of an IANA-zoned value is resolved from the zone's rules (cached per zone) when it is decoded, so the value can be printed back as local time without IO.
- Rejected: Int, Float and ISO strings (lossy and slower); raw C structs (unpleasant to use).
- motivated_by: C8

### D13 Versioned up and down migrations stored in the database
`structure Migration where version : Nat; name : String; up : Tx .schema Unit; down : Down`, where `Down` is either `.step (Tx .schema Unit)` or `.irreversible`. The first `migrate` defines the history type `typedb-lean-migration` (owning version as key, name, checksum and applied-at). Each step runs in one schema transaction that also inserts its history entity, or deletes it on rollback. The checksum is a hash of the step's name plus its `fingerprint : String`. Steps built with `Migration.tql`, `Migration.define` or `Migration.ofFile` use their TypeQL text. Lean closures cannot be hashed, so `fingerprint` is a required field for steps written as code: forgetting it is a compile error rather than a warning.
- Rejected: forward-only migrations (the user chose reversibility); `.tql` files only (no data migrations written in Lean).

### D14 Lean testcontainer harness
The `lake test` driver starts one `typedb/typedb:<pin>` container with `docker run -d --rm -p 127.0.0.1::1729`, reads the host port from `docker port`, polls until it can connect (60 s timeout), and gives each test a fresh database `t_<test>_<rand>`. It stops the container in a `finally` block and through a signal handler. If `TYPEDB_ADDRESS` is set, Docker is skipped. CI runs on `ubuntu-latest` (full suite plus bench smoke), `ubuntu-24.04-arm` (full suite) and `macos-14` (build plus unit tests).
- Rejected: docker-compose (breaks if you forget to start it, and depends on the Compose version); a container per test (slow).
- motivated_by: C6

### D16 Framework stubs for macOS links
The Rust static library needs CoreFoundation and Security. On macOS the build links against minimal TAPI v4 stubs in `ffi/macos/` listing only the 21 symbols the driver uses, the way Lean ships its own `libSystem.tbd`; `scripts/gen-macos-stubs.sh` regenerates them after a driver bump.
- Rejected: linking the SDK's frameworks (Lean's linker cannot read their stubs); requiring an older SDK.
- motivated_by: C10

### D15 Benchmarks against the Rust driver
`bench/` holds a Lean `lake exe bench` and a Cargo program `bench/rust`, which uses the `typedb-driver` crate at the same pin. Both run the four workloads against the same container and write JSON. A comparison script enforces the targets in [[openspec:performance#Scan throughput target]] and [[openspec:performance#Query latency target]].

## Risks / Trade-offs

- [The C crate may not build with plain cargo] → Spike task 1.1. If it fails, vendor a minimal manifest and pin it.
- [Thread-local errors combined with dedicated threads (C5)] → Every shim wrapper reads the error immediately on the calling thread. Errors are never read later from Lean code.
- [Finalizers run on arbitrary threads] → The Transactor closes transactions deterministically. Finalizers are only a backstop for leaked concepts and answers, which the C driver allows to be dropped from any thread. This is verified in the spike.
- [Retry re-runs side effects in the body] → Documented, and retry is opt-in only.
- [Migration checksums for code steps depend on user fingerprints] → Steps built from TypeQL are fingerprinted automatically, and `fingerprint` is a required field for code steps.
- [Upstream per-transaction memory (C9)] → Documented; the leak test measures this library's own allocations over many queries.
- [Std.Async API churn between Lean releases] → Lean is pinned to v4.35.0, and the adapter lives in one module (`TypeDB.Async`).
- [Performance targets are noisy on shared CI] → CI enforces targets with an extra 10% margin, and full targets are checked on a dedicated machine before release.
- [Polymorphic decoding needs one query per concrete type, or a label column] → The generated query uses `label($x)` in a single pipeline and dispatches on the label in Lean.

## Migration Plan

Not applicable: this is a new library. Releases are tagged `v*` and published to Reservoir once the CI matrix is green.

## Resolved Questions

- The pinned version is 3.14.0, for both the `typedb-driver` tag and the `typedb/typedb` image. The spike showed that `typedb-driver/c` builds with plain cargo (34 s on macOS arm64), so no vendored manifest is needed.
