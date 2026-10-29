# Getting started

## Install

Add the package to your `lakefile.lean`:

```lean
require «typedb-lean» from git "https://github.com/Volland/typedb-lean" @ "v0.1.0"
```

You need a Rust toolchain (`cargo`) and `protoc`, the protobuf compiler (`apt-get install protobuf-compiler` or `brew install protobuf`): the first `lake build` clones `typedb-driver` at the version in `TYPEDB_VERSION` and builds its C library. That takes about a minute; later builds reuse it. To use a library you built yourself instead, set `TYPEDB_DRIVER_LIB` to the path of `libtypedb_driver_clib.a`.

## Run a server

```sh
docker run -d --name typedb -p 1729:1729 typedb/typedb:3.14.0
```

The default credentials are `admin` / `password`.

## Connect and query

```lean
import TypeDB
open TypeDB

def main : IO Unit := do
  let r ← (Driver.withDriver { address := "127.0.0.1:1729" } fun d => do
    d.ensureDatabase "hello"
    d.runSync "hello" .schema (exec typeql!"define attribute name, value string; entity person, owns name;")
    d.runSync "hello" .write (exec typeql!"insert $p isa person, has name {"Ann"};")
    let names ← d.runSync "hello" .read (query (α := Col "n" String) typeql!"match $p isa person, has name $n;")
    IO.println (names.map (·.val))
    : EIO TypeDBError Unit).toBaseIO
  if let .error e := r then IO.eprintln e
```

`Config` also takes `username`, `password`, `tls` (`.disabled`, `.system`, or `.rootCA path`) and `requestTimeoutMs`. Everything returns `EIO TypeDBError α`. Inside `IO`, use `.toBaseIO` and match on the result as above.

## Databases

`createDatabase` (fails if the database exists), `ensureDatabase`, `databaseExists`, `deleteDatabase`, `databases`, plus `schema` and `typeSchema` (the schema as TypeQL text).
