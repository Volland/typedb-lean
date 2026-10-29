---
type: Constraint
---
# Constraints

External facts about the TypeDB driver, the server and the Lean toolchain that the design must respect. Each names what it binds.

## Blocking pull API

The C driver's promises block the thread that resolves them, and its iterators block on every `next`.

- constrains:: [[decisions#Async on dedicated threads]] {strength: must, source: "typedb-driver C API"}
- constrains:: [[decisions#Thin bindings and a batched hot path]] {strength: must, source: "typedb-driver C API"}

## Iterator lifetime

Row and document iterators are valid only while their transaction is open; this also binds the requirement `openspec:decoding#Scoped streaming`.

- constrains:: [[decisions#Scoped streaming]] {strength: must, source: "typedb-driver C API"}

## No parameter binding

The driver takes queries as text only, so values must be spliced into the query on the client; this binds `openspec:query#Injection-safe escaping`.

- constrains:: [[decisions#Typed interpolation]] {strength: must, source: "typedb-driver C API"}

## Optimistic concurrency

TypeDB detects conflicts at commit: a write transaction can lose to a concurrent one with an isolation conflict (`STC2`).

- constrains:: [[decisions#Typed errors and opt-in retry]] {strength: must, source: "TypeDB storage"}

## Thread-local last error

C driver failures return null or false and leave the error in thread-local state, so it must be read on the calling thread right after the call.

- constrains:: [[decisions#Thin bindings and a batched hot path]] {strength: must, source: "typedb-driver C API"}

## No Docker on macOS CI

GitHub's macOS runners cannot run Linux containers, so integration tests run on the Linux runners only.

- constrains:: [[decisions#Lean testcontainer harness]] {strength: must, source: "GitHub Actions"}

## Lean FFI ownership

Lean externs receive owned or borrowed objects, and native handles must be external objects with finalizers.

- constrains:: [[decisions#Thin bindings and a batched hot path]] {strength: must, source: "Lean FFI"}

## Lean toolchain

Lean 4.35 ships `Std.Async` and `Std.Time` (zoned type `Std.Time.DateTime`) but no decimal type, and rejects attributes on structure fields.

- constrains:: [[decisions#Async on dedicated threads]] {strength: must, source: "Lean 4.35"}
- constrains:: [[decisions#Precise value types]] {strength: must, source: "Lean 4.35"}
- constrains:: [[decisions#Lean-first ORM]] {strength: must, source: "Lean 4.35", note: "field markers instead of field attributes"}

## Upstream per-transaction retention

typedb-driver 3.14.0 keeps about 600 bytes per opened transaction, in its Rust and C APIs alike (measured over 40,000 transactions). So `openspec:native-driver#Native resources are released` covers only this library's own allocations.

- constrains:: [[decisions#Thin bindings and a batched hot path]] {strength: must, source: "measurement, typedb-driver 3.14.0", note: "leak tests measure queries, not transactions"}


## macOS SDK stubs

Lean's bundled `ld64.lld` cannot read the `.tbd` stubs of recent macOS SDKs, whose `arm64e.x1` targets it does not know.

- constrains:: [[decisions#Framework stubs for macOS]] {strength: must, source: "Lean 4.35 on macOS 27"}

## Driver conventions

The driver brackets its own error codes, the server rejects unknown type labels (`INF2`), IANA datetimes arrive without offsets, and the C API's default prefetch is small.

- constrains:: [[decisions#Typed errors and opt-in retry]] {strength: must, source: "typedb-driver 3.14 and server 3.14"}
- constrains:: [[decisions#Precise value types]] {strength: must, source: "typedb-driver 3.14"}
- constrains:: [[decisions#Thin bindings and a batched hot path]] {strength: should, source: "typedb-driver 3.14", note: "default prefetch 512"}

## Protobuf compiler at build time

The driver's protocol crate compiles TypeDB's protobuf definitions while cargo builds it, so building needs `protoc` (or `PROTOC`); a clean Linux machine has none.

- constrains:: [[decisions#Pinned source build]] {strength: must, source: "typedb-protocol 3.14.0 build script", note: "the lakefile checks for protoc before running cargo; CI installs it"}

## German site law

The website is published from Germany, so it needs an Impressum (§ 5 DDG, § 18 Abs. 2 MStV) and a privacy policy (Art. 13 DSGVO), and fonts or scripts loaded from third parties send visitor IP addresses abroad (LG München I, 3 O 17493/20).

- constrains:: [[decisions#Self-hosted site assets and legal pages]] {strength: must, source: "DDG, MStV, DSGVO, TDDDG"}
