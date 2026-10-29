import Lean.Data.Json
import Std.Data.HashMap
import TypeDB.Tx
import TypeDB.Decode

/-!
# Running queries

All functions run inside a transaction body and need `[Allows m need]`: the transaction's mode
`m` must be at least the query's `need`.

* `exec` runs a query for its effect.
* `query` decodes every row into an `Array`; `query1?` and `queryOne` take the first row.
* `queryFold`, `queryFoldM` and `for x in stream q do …` decode rows one batch at a time, in
  memory that does not grow with the answer. Result streams never leave the transaction: they
  are released when the loop ends, breaks or throws.
* `fetch` decodes the JSON documents of a `fetch` query with `Lean.FromJson`.
-/

namespace TypeDB

open Lean (Json FromJson)

variable {m need : TxMode} {α β : Type}

/-- UTC offsets of IANA zones need the zone's rules; they are loaded once per zone. -/
initialize zoneRules : IO.Ref (Std.HashMap String Std.Time.TimeZone.ZoneRules) ← IO.mkRef {}

private def offsetIn (zone : String) (seconds : Int64) (nanos : UInt32) : IO Int32 := do
  let rules ← match (← zoneRules.get)[zone]? with
    | some r => pure r
    | none => do
      let r ← Std.Time.Database.defaultGetZoneRules zone
      zoneRules.modify (·.insert zone r)
      pure r
  let tz := rules.timezoneAt (Time.timestampOf seconds nanos)
  return Int32.ofInt tz.offset.second.val

private def resolveValue : Value → IO Value
  | .datetimeTz s n zone _ false => return .datetimeTz s n zone (← offsetIn zone s n) false
  | v => pure v

private def resolveConcept : Concept → IO Concept
  | .attribute l v => return .attribute l (← resolveValue v)
  | .value v => return .value (← resolveValue v)
  | c => pure c

/-- Fills in the UTC offset of IANA-zoned datetimes in the columns that asked for it. -/
private def resolveZones (flags : ByteArray) (rows : Array (Array (Option Concept))) :
    IO (Array (Array (Option Concept))) := do
  let cols := (List.range flags.size).filter (fun j => flags[j]! &&& wantZone != 0)
  if cols.isEmpty then return rows
  rows.mapM fun row => do
    let mut row := row
    for j in cols do
      if let some (some c) := row[j]? then
        row := row.set! j (some (← resolveConcept c))
    return row

namespace Tx

/-- The raw answer of a query. Prefer the decoding functions. -/
-- @tg: implements:: [[openspec:query#Query answers]]
def answer [TxMode.Allows m need] (q : Query need) : Tx m Native.RawAnswer := do
  Tx.native (Native.txQuery (← ctx).handle q.text)

private def rowsOf [TxMode.Allows m need] (q : Query need) : Tx m (Option Native.RowsHandle) := do
  match ← answer q with
  | .ok => pure none
  | .rows it => pure (some it)
  | .docs it =>
    Tx.native (Native.docsClose it)
    fail (.decode "" "concept rows" "documents (use `fetch` for fetch queries)")

/-- Folds `f` over the decoded rows, one native batch at a time. `f` returns `none` to stop. -/
def foldRowsM [TxMode.Allows m need] (d : RowDecoder α) (q : Query need) (init : β)
    (f : β → α → Tx m (ForInStep β)) : Tx m β := do
  let some it ← rowsOf q | pure init
  let (cols, flags) := d.plan
  let k := (← ctx).options.batchSize.max 1
  let mut acc := init
  try
    repeat
      let batch ← Tx.native (Native.rowsNextBatch it cols flags (USize.ofNat k))
      let batch ← liftM (n := Tx m) (resolveZones flags batch)
      let mut stop := false
      for row in batch do
        match d.run row 0 with
        | .error e => throw e
        | .ok a =>
          match ← f acc a with
          | .yield b => acc := b
          | .done b => acc := b; stop := true; break
      if stop || batch.size < k then break
    return acc
  finally
    Tx.native (Native.rowsClose it)

/-- Runs a query for its effect, draining any rows it answers. -/
def exec [TxMode.Allows m need] (q : Query need) : Tx m Unit := do
  match ← answer q with
  | .ok => pure ()
  | .rows it =>
    try
      repeat
        let batch ← Tx.native (Native.rowsNextBatch it #[] .empty 1024)
        if batch.size < 1024 then break
    finally Tx.native (Native.rowsClose it)
  | .docs it =>
    try
      repeat
        if (← Tx.native (Native.docsNext it)).isNone then break
    finally Tx.native (Native.docsClose it)

/-- Every row, decoded with `d`, in answer order. -/
-- @tg: implements:: [[openspec:decoding#Strict results]]
def queryWith [TxMode.Allows m need] (d : RowDecoder α) (q : Query need) : Tx m (Array α) :=
  foldRowsM d q #[] fun acc a => pure (.yield (acc.push a))

/-- Every row, decoded with `FromRow α`, in answer order. -/
def query [TxMode.Allows m need] [FromRow α] (q : Query need) : Tx m (Array α) :=
  queryWith FromRow.decoder q

/-- The first row, if any. -/
def query1? [TxMode.Allows m need] [FromRow α] (q : Query need) : Tx m (Option α) :=
  foldRowsM FromRow.decoder q none fun _ a => pure (.done (some a))

/-- The first row; fails if the answer is empty. -/
def queryOne [TxMode.Allows m need] [FromRow α] (q : Query need) : Tx m α := do
  match ← query1? (α := α) q with
  | some a => pure a
  | none => fail (.decode "" "at least one row" "no rows")

/-- Folds over the rows in constant memory. -/
-- @tg: implements:: [[openspec:decoding#Scoped streaming]]
def queryFold [TxMode.Allows m need] [FromRow α] (q : Query need) (init : β) (f : β → α → β) : Tx m β :=
  foldRowsM FromRow.decoder q init fun b a => pure (.yield (f b a))

def queryFoldM [TxMode.Allows m need] [FromRow α] (q : Query need) (init : β) (f : β → α → Tx m β) :
    Tx m β :=
  foldRowsM FromRow.decoder q init fun b a => return .yield (← f b a)

/-- Rows decoded one native call per value (the unbatched path), for comparison with `query`. -/
def queryPerValue [TxMode.Allows m need] (d : RowDecoder α) (q : Query need) : Tx m (Array α) := do
  let some it ← rowsOf q | pure #[]
  try
    let mut out := #[]
    repeat
      let some row ← Tx.native (Native.rowsNext it) | break
      let mut cs := #[]
      for (name, flags) in d.columns do
        cs := cs.push (← Tx.native (Native.rowGet row name flags))
      let resolved ← liftM (n := Tx m) (resolveZones ⟨d.columns.map (·.2)⟩ #[cs])
      match d.run resolved[0]! 0 with
      | .ok a => out := out.push a
      | .error e => throw e
    return out
  finally Tx.native (Native.rowsClose it)

/-- The JSON documents of a `fetch` query. -/
def fetchJson [TxMode.Allows m need] (q : Query need) : Tx m (Array Json) := do
  match ← answer q with
  | .docs it =>
    try
      let mut out := #[]
      repeat
        let some s ← Tx.native (Native.docsNext it) | break
        match Json.parse s with
        | .ok j => out := out.push j
        | .error e => fail (.decode "" "JSON document" e)
      return out
    finally Tx.native (Native.docsClose it)
  | .rows it =>
    Tx.native (Native.rowsClose it)
    fail (.decode "" "documents" "concept rows (use `query` for match queries)")
  | .ok => pure #[]

/-- The documents of a `fetch` query, decoded with `FromJson`. -/
-- @tg: implements:: [[openspec:decoding#Document decoding]]
def fetch [TxMode.Allows m need] [FromJson α] (q : Query need) : Tx m (Array α) := do
  (← fetchJson q).mapM fun j => match FromJson.fromJson? j with
    | .ok a => pure a
    | .error e => fail (.decode "" "document matching the target type" s!"{e} in {j.compress}")

/-- A query whose rows are decoded lazily by a `for` loop inside the transaction. -/
structure RowStream (need : TxMode) (α : Type) where
  query : Query need
  decoder : RowDecoder α

def stream [FromRow α] (q : Query need) : RowStream need α := ⟨q, FromRow.decoder⟩
def streamWith (d : RowDecoder α) (q : Query need) : RowStream need α := ⟨q, d⟩

instance [TxMode.Allows m need] : ForIn (Tx m) (RowStream need α) α where
  forIn s init f := foldRowsM s.decoder s.query init fun b a => f a b

end Tx

export Tx (exec query query1? queryOne queryWith queryFold queryFoldM fetch fetchJson stream streamWith)

end TypeDB
