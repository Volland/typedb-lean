import TypeDB
import Std.Async.Signal

/-!
# Test harness

`lake test` starts one `typedb/typedb:<pinned version>` container on a random local port, waits
until the server answers, and gives every integration test a fresh database. The container is
removed when the run ends, also on Ctrl-C or SIGTERM; containers left behind by a killed run
(label `typedb-lean-test`) are removed by the next one. Set `TYPEDB_ADDRESS` to run against an
existing server instead.
-/

namespace Harness

open TypeDB

/-- The pinned TypeDB version, from `TYPEDB_VERSION` at the repository root. -/
def typedbVersion : String := Str.trim (include_str "../TYPEDB_VERSION")

structure Ctx where
  driver : Driver
  db : String
  config : Config

/-- An integration test: runs against a fresh database. -/
structure Test where
  name : String
  run : Ctx → EIO TypeDBError Unit

/-- A test that needs no server. -/
structure UnitTest where
  name : String
  run : IO Unit

/-! ## Assertions -/

def check (cond : Bool) (msg : String) : EIO TypeDBError Unit :=
  unless cond do throw (.internal s!"assertion failed: {msg}")

def checkEq {α : Type} [BEq α] [Repr α] (actual expected : α) (what : String := "value") :
    EIO TypeDBError Unit :=
  unless actual == expected do
    throw (.internal s!"{what}: expected {repr expected}, got {repr actual}")

/-- Runs `x` and checks that it fails with an error satisfying `p`. -/
def expectError {α : Type} (x : EIO TypeDBError α) (p : TypeDBError → Bool) (what : String) :
    EIO TypeDBError TypeDBError := do
  match ← (x.toBaseIO : BaseIO (Except TypeDBError α)) with
  | .ok _ => throw (.internal s!"expected {what} to fail")
  | .error e =>
    unless p e do throw (.internal s!"{what} failed with the wrong error: {e}")
    return e

def unitCheck (cond : Bool) (msg : String) : IO Unit :=
  unless cond do throw (IO.userError s!"assertion failed: {msg}")

def unitEq {α : Type} [BEq α] [Repr α] (actual expected : α) (what : String := "value") : IO Unit :=
  unless actual == expected do
    throw (IO.userError s!"{what}: expected {repr expected}, got {repr actual}")

/-! ## Server -/

private def docker (args : Array String) : IO String := do
  let out ← IO.Process.output { cmd := "docker", args }
  unless out.exitCode == 0 do
    throw (IO.userError s!"docker {" ".intercalate args.toList} failed: {out.stderr}")
  return Str.trim out.stdout

def removeStale : IO Unit := do
  let ids ← docker #["ps", "-aq", "--filter", "label=typedb-lean-test"]
  for id in ids.splitOn "\n" do
    unless id.isEmpty do discard <| IO.Process.output { cmd := "docker", args := #["rm", "-f", id] }

/-- Starts the container and returns its id and address. -/
def startContainer : IO (String × String) := do
  removeStale
  let id ← docker #["run", "-d", "--rm", "--label", "typedb-lean-test", "-p", "127.0.0.1::1729",
    s!"typedb/typedb:{typedbVersion}"]
  let port ← docker #["port", id, "1729/tcp"]
  return (id, (port.splitOn "\n").head!)

def stopContainer (id : String) : IO Unit :=
  discard <| IO.Process.output { cmd := "docker", args := #["rm", "-f", id] }

/-- Connects, retrying until the server answers or `timeoutMs` passes. -/
def waitReady (config : Config) (timeoutMs : Nat := 90000) : IO Driver := do
  let start ← IO.monoMsNow
  repeat
    match ← (do let d ← Driver.connect config; discard d.databases; pure d : EIO TypeDBError Driver).toBaseIO with
    | .ok d => return d
    | .error e =>
      if (← IO.monoMsNow) - start > timeoutMs then
        throw (IO.userError s!"TypeDB at {config.address} did not become ready: {e}")
      IO.sleep 500
  unreachable!

/-! ## Runner -/

private def fresh (name : String) : IO String := do
  let n ← IO.rand 0 0xFFFFFF
  let safe := String.ofList (name.toList.map fun c => if c.isAlphanum then c.toLower else '_')
  return s!"t_{safe}_{n}"

def runIntegration (config : Config) (d : Driver) (tests : Array Test) : IO (Nat × Array String) := do
  let mut failed := #[]
  for t in tests do
    let db ← fresh t.name
    let start ← IO.monoMsNow
    let r ← (do
      d.createDatabase db
      try t.run { driver := d, db, config }
      finally discard <| ((d.deleteDatabase db).toBaseIO : BaseIO _)
      : EIO TypeDBError Unit).toBaseIO
    let ms := (← IO.monoMsNow) - start
    match r with
    | .ok () => IO.println s!"  ok    {t.name} ({ms} ms)"
    | .error e =>
      IO.println s!"  FAIL  {t.name}: {e}"
      failed := failed.push t.name
  return (tests.size, failed)

def runUnit (tests : Array UnitTest) : IO (Array String) := do
  let mut failed := #[]
  for t in tests do
    match ← t.run.toBaseIO with
    | .ok () => IO.println s!"  ok    {t.name}"
    | .error e =>
      IO.println s!"  FAIL  {t.name}: {e}"
      failed := failed.push t.name
  return failed

/-- Runs the unit tests, then the integration tests against a container (or `TYPEDB_ADDRESS`).
`lake test -- <substring>…` runs only tests whose name contains one of them, and
`lake test -- --unit` only the unit tests. -/
def main (args : List String) (units : Array UnitTest) (integration : Array Test) : IO UInt32 := do
  let unitOnly := args.contains "--unit"
  let args := args.filter (· != "--unit")
  let keep (n : String) := args.isEmpty || args.any (Str.contains n ·)
  IO.println "unit tests"
  let unitFailed ← runUnit (units.filter (keep ·.name))
  let integration := if unitOnly then #[] else integration.filter (keep ·.name)
  if integration.isEmpty then return if unitFailed.isEmpty then 0 else 1
  let (container, address) ← match ← IO.getEnv "TYPEDB_ADDRESS" with
    | some a => pure (none, a)
    | none => do
      IO.println s!"starting typedb/typedb:{typedbVersion}"
      let (id, a) ← startContainer
      pure (some id, a)
  if let some id := container then
    for sig in [Std.Async.Signal.sigint, .sigterm] do
      let w ← Std.Async.Signal.Waiter.mk sig false
      let t ← w.wait
      discard <| IO.mapTask (t := t) fun _ => (do
        stopContainer id
        IO.Process.exit 130 : IO Unit)
  try
    let config : Config := { address }
    let d ← waitReady config
    IO.println s!"integration tests against {address}"
    let (n, failed) ← runIntegration config d integration
    let allFailed := unitFailed ++ failed
    IO.println s!"\n{units.size + n - allFailed.size} passed, {allFailed.size} failed"
    for f in allFailed do IO.println s!"  failed: {f}"
    return if allFailed.isEmpty then 0 else 1
  finally
    if let some id := container then stopContainer id

end Harness
