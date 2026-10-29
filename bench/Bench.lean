import Harness

/-!
# Benchmarks against the Rust driver

    lake exe bench          # full sizes, enforces the targets
    lake exe bench --ci     # reduced sizes, targets relaxed by an extra 10%

Starts a `typedb/typedb` container (or uses `TYPEDB_ADDRESS`), loads `scan` people, then runs
the same four workloads with this library and with the official Rust driver
(`bench/rust`, same pinned version) and writes `bench/report.json`:

* point lookup by key, one read transaction each: p50 and p99 latency;
* a scan decoded into structures: rows per second;
* bulk insert of `bulk` entities in one write transaction;
* 16 concurrent read transactions, each scanning up to 10 000 rows.
-/

open TypeDB Harness Std.Async

namespace Bench

structure Person where
  e : String
  n : String
  a : Int64
  deriving FromRow

structure Sizes where
  scan : Nat
  lookups : Nat
  bulk : Nat

structure Result where
  scanRows : Nat
  scanRowsPerS : Float
  lookupP50Us : Float
  lookupP99Us : Float
  bulkInsertMs : Float
  concurrentReadsMs : Float

def Result.json (impl : String) (r : Result) : Lean.Json :=
  open Lean in
  Json.mkObj [("impl", impl), ("scan_rows", r.scanRows), ("scan_rows_per_s", toJson r.scanRowsPerS),
    ("lookup_p50_us", toJson r.lookupP50Us), ("lookup_p99_us", toJson r.lookupP99Us),
    ("bulk_insert_ms", toJson r.bulkInsertMs), ("concurrent_reads_ms", toJson r.concurrentReadsMs)]

def Result.ofJson (j : Lean.Json) : Except String Result := do
  let num (k : String) : Except String Float := do
    let v ← j.getObjVal? k
    match v with
    | .num n => pure n.toFloat
    | _ => throw s!"{k} is not a number"
  return { scanRows := (← num "scan_rows").toUInt64.toNat, scanRowsPerS := ← num "scan_rows_per_s",
           lookupP50Us := ← num "lookup_p50_us", lookupP99Us := ← num "lookup_p99_us",
           bulkInsertMs := ← num "bulk_insert_ms", concurrentReadsMs := ← num "concurrent_reads_ms" }

def schema : Query .schema :=
  typeql!"define attribute email, value string; attribute name, value string;
    attribute age, value integer; entity person, owns email @key, owns name, owns age;"

def scanQuery (limit : Nat) : Query .read :=
  typeql!"match $p isa person, has email $e, has name $n, has age $a; limit {limit};"

/-- Loads `n` people, 100 per query. -/
def load (d : Driver) (db : String) (n : Nat) : EIO TypeDBError Unit := do
  d.runSync db .schema (exec schema)
  for chunk in [0:(n + 9999) / 10000] do
    d.runSync db .write do
      for q in [0:100] do
        let base := chunk * 10000 + q * 100
        if base ≥ n then break
        let parts := (List.range (min 100 (n - base))).map fun i =>
          let k := base + i
          s!"$p{i} isa person, has email \"p{k}\", has name \"name {k}\", has age {k};"
        exec (Query.raw .write ("insert " ++ " ".intercalate parts))

def nowUs : IO Float := return (← IO.monoNanosNow).toFloat / 1000

def percentile (sorted : Array Float) (p : Float) : Float :=
  sorted[((sorted.size.toFloat - 1) * p).round.toUInt64.toNat]!

def runLean (d : Driver) (db : String) (s : Sizes) : EIO TypeDBError Result := do
  let t0 ← nowUs
  let rows ← d.runSync db .read (opts := { batchSize := 512 }) (query (α := Person) (scanQuery s.scan))
  let scanUs := (← nowUs) - t0
  let mut lat := #[]
  for i in [0:s.lookups] do
    let t ← nowUs
    let found ← d.runSync db .read (query (α := Person)
      typeql!"match $p isa person, has email {s!"p{i % s.scan}"}, has email $e, has name $n, has age $a;")
    unless found.size == 1 do throw (.internal "lookup did not find exactly one person")
    lat := lat.push ((← nowUs) - t)
  lat := lat.qsort (· < ·)
  let bulkDb := db ++ "_lean_bulk"
  if ← d.databaseExists bulkDb then d.deleteDatabase bulkDb
  d.createDatabase bulkDb
  d.runSync bulkDb .schema (exec schema)
  let t1 ← nowUs
  d.runSync bulkDb .write do
    for i in [0:s.bulk] do
      exec typeql!"insert $p isa person, has email {s!"b{i}"}, has name {s!"n{i}"}, has age {i};"
  let bulkUs := (← nowUs) - t1
  d.deleteDatabase bulkDb
  let t2 ← nowUs
  discard <| (EAsync.concurrentlyAll ((Array.range 16).map fun _ =>
    d.run db .read (opts := { batchSize := 512 }) (query (α := Person) (scanQuery (min s.scan 10000))))).block
  let concUs := (← nowUs) - t2
  return { scanRows := rows.size, scanRowsPerS := rows.size.toFloat / (scanUs / 1e6),
           lookupP50Us := percentile lat 0.5, lookupP99Us := percentile lat 0.99,
           bulkInsertMs := bulkUs / 1000, concurrentReadsMs := concUs / 1000 }

def runRust (address db : String) (s : Sizes) : IO Result := do
  let build ← IO.Process.output { cmd := "cargo", args := #["build", "--release", "--quiet"], cwd := "bench/rust" }
  unless build.exitCode == 0 do throw (IO.userError s!"building bench/rust failed:\n{build.stderr}")
  let rustArgs := #[address, db, toString s.scan, toString s.lookups, toString s.bulk]
  let out ← IO.Process.output { cmd := "bench/rust/target/release/typedb-lean-bench-rust", args := rustArgs }
  unless out.exitCode == 0 do throw (IO.userError s!"bench/rust failed:\n{out.stderr}")
  match Lean.Json.parse out.stdout >>= Result.ofJson with
  | .ok r => pure r
  | .error e => throw (IO.userError s!"cannot read the Rust results: {e}\n{out.stdout}")

/-- The targets of the performance spec, relaxed by `margin` (0.1 in CI). -/
-- @tg: implements:: [[openspec:performance#Scan throughput target]]
-- @tg: implements:: [[openspec:performance#Query latency target]]
-- @tg: implements:: [[openspec:performance#CI benchmark smoke]]
-- @tg: verifies:: [[openspec:performance#Scan throughput target#Scan meets target]] {level: e2e}
-- @tg: verifies:: [[openspec:performance#Query latency target#Lookup meets target]] {level: e2e}
-- @tg: verifies:: [[openspec:performance#CI benchmark smoke#Regression fails CI]] {level: e2e}
def checkTargets (lean rust : Result) (margin : Float) : Array String := Id.run do
  let mut failures := #[]
  let scanRatio := lean.scanRowsPerS / rust.scanRowsPerS
  if scanRatio < 0.8 - margin then
    failures := failures.push s!"scan reaches {scanRatio * 100}% of Rust's rows/s, target {(0.8 - margin) * 100}%"
  let latRatio := lean.lookupP50Us / rust.lookupP50Us
  if latRatio > 1.1 + margin then
    failures := failures.push s!"lookup p50 is {latRatio}× Rust's, target at most {1.1 + margin}×"
  return failures

def row (label : String) (l r : Float) (unit : String) : String :=
  s!"  {label}: lean {l.round} {unit}, rust {r.round} {unit} (ratio {(l / r * 100).round / 100})"

-- @tg: implements:: [[openspec:performance#Benchmark suite]]
-- @tg: verifies:: [[openspec:performance#Benchmark suite#Report produced]] {level: e2e}
def profile (d : Driver) (db : String) (n : Nat) : EIO TypeDBError Unit := do
  let q := scanQuery n
  let time (label : String) (x : Tx .read Unit) : EIO TypeDBError Unit := do
    let t ← nowUs
    d.runSync db .read (opts := { batchSize := 512 }) x
    IO.println s!"  {label}: {((← nowUs) - t) / 1000} ms"
  let ignore : RowDecoder Unit := ⟨#[("e", 0), ("n", 0), ("a", 0)], fun _ _ => .ok ()⟩
  for _ in [0:2] do
    time "drain rows, no columns" (exec q)
    time "fetch 3 columns, no decode" (discard <| queryWith ignore q)
    time "fetch and decode" (discard <| query (α := Person) q)
    time "rows only, per-value path" (discard <| Tx.queryPerValue (pure ()) q)

def main (args : List String) : IO UInt32 := do
  let ci := args.contains "--ci"
  let sizes : Sizes := if ci then ⟨20000, 300, 2000⟩ else ⟨100000, 1000, 10000⟩
  let (container, address) ← match ← IO.getEnv "TYPEDB_ADDRESS" with
    | some a => pure (none, a)
    | none => do let (id, a) ← startContainer; pure (some id, a)
  try
    let d ← waitReady { address }
    let db := "bench"
    let r ← (do
      if ← d.databaseExists db then d.deleteDatabase db
      d.createDatabase db
      IO.println s!"loading {sizes.scan} people"
      load d db sizes.scan
      -- Warm both clients' connections and the server's caches before measuring.
      discard <| runLean d db { sizes with lookups := 20, bulk := 10 }
      if args.contains "--profile" then profile d db sizes.scan
      runLean d db sizes : EIO TypeDBError Result).toBaseIO
    let lean ← match r with
      | .ok l => pure l
      | .error e => throw (IO.userError (toString e))
    discard <| runRust address db { sizes with lookups := 20, bulk := 10 }
    let rust ← runRust address db sizes
    IO.FS.writeFile "bench/report.json"
      (Lean.Json.mkObj [("sizes", Lean.Json.mkObj [("scan", sizes.scan), ("lookups", sizes.lookups),
        ("bulk", sizes.bulk)]), ("lean", lean.json "lean"), ("rust", rust.json "rust")]).pretty
    IO.println (row "scan" lean.scanRowsPerS rust.scanRowsPerS "rows/s")
    IO.println (row "lookup p50" lean.lookupP50Us rust.lookupP50Us "µs")
    IO.println (row "lookup p99" lean.lookupP99Us rust.lookupP99Us "µs")
    IO.println (row "bulk insert" lean.bulkInsertMs rust.bulkInsertMs "ms")
    IO.println (row "16 concurrent reads" lean.concurrentReadsMs rust.concurrentReadsMs "ms")
    let failures := checkTargets lean rust (if ci then 0.1 else 0)
    for f in failures do IO.eprintln s!"target missed: {f}"
    IO.println "wrote bench/report.json"
    return if failures.isEmpty then 0 else 1
  finally
    if let some id := container then stopContainer id

end Bench

def main (args : List String) : IO UInt32 := Bench.main args
