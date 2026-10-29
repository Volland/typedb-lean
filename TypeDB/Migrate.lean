import TypeDB.Schema
import TypeDB.Async

/-!
# Migrations

A migration is a numbered step with an `up` and a `down`, each a schema-transaction body. Schema
transactions can also read and write data, so a step can change the schema and backfill data
atomically.

`Driver.migrate` applies, in version order, every step newer than the database's latest applied
one. Each step runs in its own schema transaction together with the insertion of its history
record, so a failed step leaves no trace and the steps before it stay applied. The history lives
in the database itself, as `typedb-lean-migration` entities.

Every step has a checksum of its name and `fingerprint`. Migrating fails before running anything
if an applied step's checksum no longer matches the list, which catches edits to steps that have
already run. Lean functions cannot be hashed, so steps written as code must say what identifies
them in `fingerprint`; steps built from TypeQL text (`Migration.tql`, `Migration.define`) use the
text itself.

`Driver.rollback` runs `down` steps in reverse version order, each with the removal of its
history record. A step whose `down` is `.irreversible` stops the rollback.
-/

namespace TypeDB

/-- How a migration is undone. -/
inductive Down where
  | step (body : Tx .schema Unit)
  /-- The step cannot be undone, e.g. because it drops data. -/
  | irreversible

/-- One versioned migration step. -/
-- @tg: implements:: [[openspec:migrations#Versioned migrations]]
structure Migration where
  version : Nat
  name : String
  up : Tx .schema Unit
  down : Down
  /-- What identifies the step's content for the checksum: its TypeQL, or a description that
  changes whenever the step's code does. -/
  fingerprint : String

namespace Migration

/-- A step from TypeQL text, with an optional TypeQL `down`. -/
def tql (version : Nat) (name : String) (up : String) (down : Option String := none) : Migration where
  version
  name
  up := exec (Query.raw .schema up)
  down := match down with
    | some d => .step (exec (Query.raw .schema d))
    | none => .irreversible
  fingerprint := up ++ "\n--down--\n" ++ down.getD ""

/-- A step that defines the mapped types; `down` undefines nothing and is irreversible unless
given. -/
def define (version : Nat) (name : String) (specs : List TypeSpec) (down : Down := .irreversible) :
    Migration where
  version
  name
  up := Schema.defineTx specs
  down
  fingerprint := match Schema.defineText specs with | .ok t => t | .error e => e

/-- A step from a TypeQL file, read now so that its checksum covers the file's content. -/
-- @tg: implements:: [[openspec:migrations#Schema helpers]]
def ofFile (version : Nat) (name : String) (path : System.FilePath) (down : Down := .irreversible) :
    IO Migration := do
  let text ← IO.FS.readFile path
  return { version, name, up := exec (Query.raw .schema text), down, fingerprint := text }

def checksum (m : Migration) : String :=
  let h := hash (m.name ++ "\n" ++ m.fingerprint)
  Str.padLeft (String.ofList (Nat.toDigits 16 h.toNat)) 16 '0'

end Migration

/-- A row of the migration history. -/
structure AppliedMigration where
  version : Nat
  name : String
  checksum : String
  appliedAt : Std.Time.PlainDateTime

instance : FromRow AppliedMigration :=
  ⟨AppliedMigration.mk <$> col "v" <*> col "n" <*> col "c" <*> col "t"⟩

/-- What `migrate` or `rollback` did: the steps run, in order. -/
structure MigrationReport where
  steps : Array (Nat × String) := #[]
  deriving Repr, Inhabited

namespace Migrations

def historyType : String := "typedb-lean-migration"

def historySchema : Query .schema := ⟨"define
  attribute typedb-lean-version, value integer;
  attribute typedb-lean-name, value string;
  attribute typedb-lean-checksum, value string;
  attribute typedb-lean-applied-at, value datetime;
  entity typedb-lean-migration, owns typedb-lean-version @key, owns typedb-lean-name,
    owns typedb-lean-checksum, owns typedb-lean-applied-at;"⟩

def historyQuery : Query .read := ⟨"match $m isa typedb-lean-migration, has typedb-lean-version $v,
  has typedb-lean-name $n, has typedb-lean-checksum $c, has typedb-lean-applied-at $t;"⟩

/-- Checks that versions are unique and strictly increasing. -/
def validate (ms : List Migration) : Except TypeDBError Unit := do
  let mut prev : Option Nat := none
  for m in ms do
    if let some p := prev then
      if m.version == p then throw (.migration m.version "duplicate version")
      if m.version < p then throw (.migration m.version s!"listed after version {p}")
    prev := some m.version

private def now : IO Std.Time.PlainDateTime := do
  let (s, n) := Time.splitTimestamp (← Std.Time.Timestamp.now)
  return Time.plainDateTimeOf s n

private def wrap {α : Type} (version : Nat) (x : EIO TypeDBError α) : EIO TypeDBError α :=
  tryCatch x fun e => match e with
    | .migration .. => throw e
    | e => throw (.migration version (toString e))

/-- The applied history, oldest first. -/
def history (d : Driver) (db : String) : EIO TypeDBError (Array AppliedMigration) := do
  d.runSync db .schema (exec historySchema)
  let rows ← d.runSync db .read (query (α := AppliedMigration) historyQuery)
  return rows.qsort (·.version < ·.version)

end Migrations

namespace Driver

open Migrations

/-- Applies every step newer than the latest applied one, each in its own schema transaction. -/
-- @tg: implements:: [[openspec:migrations#Migrate applies pending steps]]
-- @tg: implements:: [[openspec:migrations#Atomic steps]]
-- @tg: implements:: [[openspec:migrations#Checksum drift detection]]
-- @tg: implements:: [[openspec:migrations#Migration history]]
def migrateSync (d : Driver) (db : String) (ms : List Migration) : EIO TypeDBError MigrationReport := do
  match validate ms with
  | .error e => throw e
  | .ok () => pure ()
  let applied ← history d db
  for a in applied do
    match ms.find? (·.version == a.version) with
    | none => throw (.migration a.version s!"applied step '{a.name}' is missing from the migration list")
    | some m =>
      if m.checksum != a.checksum then
        throw (.migration a.version s!"step '{m.name}' changed after it was applied (checksum {a.checksum}, now {m.checksum})")
  let latest := applied.foldl (fun acc a => max acc a.version) 0
  let mut report : MigrationReport := {}
  for m in ms do
    if m.version ≤ latest && !applied.isEmpty then continue
    let at_ ← now
    wrap m.version <| d.runSync db .schema do
      m.up
      exec (Query.raw .write s!"insert $m isa {historyType}, has typedb-lean-version {m.version},
        has typedb-lean-name {render m.name}, has typedb-lean-checksum {render m.checksum},
        has typedb-lean-applied-at {render at_};")
    report := { steps := report.steps.push (m.version, m.name) }
  return report

/-- Runs the `down` steps of every applied step newer than `to`, newest first. -/
-- @tg: implements:: [[openspec:migrations#Rollback]]
def rollbackSync (d : Driver) (db : String) (ms : List Migration) (to : Nat) :
    EIO TypeDBError MigrationReport := do
  let applied ← history d db
  let mut report : MigrationReport := {}
  for a in applied.reverse do
    if a.version ≤ to then continue
    let some m := ms.find? (·.version == a.version)
      | throw (.migration a.version s!"applied step '{a.name}' is missing from the migration list")
    match m.down with
    | .irreversible => throw (.migration m.version s!"step '{m.name}' is irreversible")
    | .step body =>
      wrap m.version <| d.runSync db .schema do
        body
        exec (Query.raw .write s!"match $m isa {historyType}, has typedb-lean-version {m.version}; delete $m;")
      report := { steps := report.steps.push (m.version, m.name) }
  return report

def migrate (d : Driver) (db : String) (ms : List Migration) : Std.Async.EAsync TypeDBError MigrationReport :=
  blocking (d.migrateSync db ms)

def rollback (d : Driver) (db : String) (ms : List Migration) (to : Nat) :
    Std.Async.EAsync TypeDBError MigrationReport :=
  blocking (d.rollbackSync db ms to)

end Driver

end TypeDB
