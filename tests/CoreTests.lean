import Harness

/-! Integration tests: connections, transactions, async runs and native resources. -/

namespace CoreTests

open TypeDB Harness Std.Async

def personSchema : Query .schema :=
  typeql!"define attribute name, value string; attribute email, value string;
    attribute n, value integer;
    entity person, owns name, owns email @key; entity counter, owns n;"

def setup (c : Ctx) : EIO TypeDBError Unit := c.driver.runSync c.db .schema (exec personSchema)

def countPeople (c : Ctx) : EIO TypeDBError Nat := do
  let n ← c.driver.runSync c.db .read
    (queryOne (α := Col "c" Int64) typeql!"match $p isa person; reduce $c = count;")
  return n.val.toInt.toNat

/-! ## Connection -/

-- @tg: verifies:: [[openspec:connection#Connect with credentials#Successful connection]] {level: integration}
-- @tg: verifies:: [[openspec:native-driver#Pinned driver build#Clean build produces linked library]] {level: e2e}
def connectOk : Test := ⟨"connection: successful connection", fun c => do
  let d ← Driver.connect c.config
  check ((← d.databases).contains c.db) "the test database is listed"
  d.close⟩

-- @tg: verifies:: [[openspec:connection#Connect with credentials#Wrong password]] {level: integration}
def wrongPassword : Test := ⟨"connection: wrong password", fun c => do
  let e ← expectError (Driver.connect { c.config with password := "wrong" })
    (fun | .connection .. | .server .. => true | _ => false) "connecting with a wrong password"
  check (match e with | .connection code _ | .server code _ => !code.isEmpty | _ => false) "error has a code"⟩

-- @tg: verifies:: [[openspec:connection#Connect with credentials#Unreachable server]] {level: integration}
def unreachable : Test := ⟨"connection: unreachable server", fun _ => do
  let start ← IO.monoMsNow
  discard <| expectError (Driver.connect { address := "127.0.0.1:1", requestTimeoutMs := 2000 })
    (fun | .connection .. => true | _ => false) "connecting to a closed port"
  check ((← IO.monoMsNow) - start < 30000) "fails without hanging"⟩

-- @tg: verifies:: [[openspec:connection#Optional TLS#TLS disabled by default]] {level: integration}
def tlsDefault : Test := ⟨"connection: TLS disabled by default", fun c => do
  check (match ({} : Config).tls with | .disabled => true | _ => false) "default is plain"
  (← Driver.connect { address := c.config.address }).close⟩

-- @tg: verifies:: [[openspec:connection#Optional TLS#Missing CA file]] {level: integration}
def missingCA : Test := ⟨"connection: missing CA file", fun c => do
  let e ← expectError (Driver.connect { c.config with tls := .rootCA "/nonexistent/ca.pem" })
    (fun | .connection .. => true | _ => false) "connecting with a missing CA"
  check (Str.contains (toString e) "/nonexistent/ca.pem") "error names the path"⟩

-- @tg: verifies:: [[openspec:connection#Driver options#Prefetch size applies]] {level: integration}
def prefetch : Test := ⟨"connection: prefetch size 1", fun c => do
  setup c
  c.driver.runSync c.db .write do
    for i in [0:25] do exec typeql!"insert $p isa person, has email {s!"p{i}"};"
  let rows ← c.driver.runSync c.db .read (opts := { prefetch := 1, batchSize := 4 })
    (query (α := Col "e" String) typeql!"match $p isa person, has email $e;")
  checkEq rows.size 25 "rows"⟩

-- @tg: verifies:: [[openspec:connection#Database management#Create and list]] {level: integration}
def createList : Test := ⟨"connection: create and list databases", fun c => do
  let name := c.db ++ "_d1"
  c.driver.createDatabase name
  try
    check ((← c.driver.databases).contains name) "listed"
    check (← c.driver.databaseExists name) "exists"
  finally c.driver.deleteDatabase name⟩

-- @tg: verifies:: [[openspec:connection#Database management#Delete]] {level: integration}
def deleteDb : Test := ⟨"connection: delete database", fun c => do
  let name := c.db ++ "_d2"
  c.driver.createDatabase name
  c.driver.deleteDatabase name
  check (!(← c.driver.databaseExists name)) "gone"⟩

-- @tg: verifies:: [[openspec:connection#Database management#Create duplicate]] {level: integration}
def duplicateDb : Test := ⟨"connection: create duplicate database", fun c => do
  setup c
  discard <| expectError (c.driver.createDatabase c.db) (fun | .server .. => true | _ => false) "duplicate"
  check (Str.contains (← c.driver.schema c.db) "person") "existing schema unchanged"⟩

-- @tg: verifies:: [[openspec:connection#Driver is shareable#Concurrent use]] {level: integration}
def shareable : Test := ⟨"connection: one driver, 16 concurrent transactions", fun c => do
  setup c
  let runs := (Array.range 16).map fun i =>
    c.driver.run c.db .write do
      exec typeql!"insert $p isa person, has email {s!"c{i}"};"
      return i
  let results ← (EAsync.concurrentlyAll runs).block
  checkEq results (Array.range 16) "results"
  checkEq (← countPeople c) 16 "inserted"⟩

/-! ## Transactions -/

-- @tg: verifies:: [[openspec:transactions#Transactions compose monadically#Composition]] {level: integration}
def composition : Test := ⟨"transactions: two write functions in one commit", fun c => do
  setup c
  let addA : Tx .write Unit := exec typeql!"insert $p isa person, has email \"a\";"
  let addB : Tx .write Unit := exec typeql!"insert $p isa person, has email \"b\";"
  c.driver.runSync c.db .write do addA; addB
  checkEq (← countPeople c) 2 "both inserted"⟩

-- @tg: verifies:: [[openspec:transactions#Transactions compose monadically#Catch inside a transaction]] {level: integration}
def catchInside : Test := ⟨"transactions: catch a decode error and commit", fun c => do
  setup c
  c.driver.runSync c.db .write do
    exec typeql!"insert $p isa person, has email \"a\", has name \"A\";"
    try
      discard <| query (α := Col "n" Int64) typeql!"match $p isa person, has name $n;"
      Tx.fail (.internal "decoding a string as an integer should fail")
    catch
      | .decode .. => pure ()
      | e => throw e
    exec typeql!"insert $p isa person, has email \"b\";"
  checkEq (← countPeople c) 2 "both writes committed"⟩

-- @tg: verifies:: [[openspec:transactions#Commit on success#Insert is visible after run]] {level: integration}
def commitVisible : Test := ⟨"transactions: commit on success", fun c => do
  setup c
  c.driver.runSync c.db .write (exec typeql!"insert $p isa person, has email \"a\";")
  checkEq (← countPeople c) 1 "visible"⟩

-- @tg: verifies:: [[openspec:transactions#Rollback on failure#Error discards writes]] {level: integration}
def rollbackOnError : Test := ⟨"transactions: error discards writes", fun c => do
  setup c
  let e ← expectError (c.driver.runSync c.db .write do
      exec typeql!"insert $p isa person, has email \"a\";"
      Tx.fail (.internal "boom") : EIO TypeDBError Unit)
    (fun | .internal "boom" => true | _ => false) "failing body"
  check (match e with | .internal _ => true | _ => false) "caller gets the body's error"
  checkEq (← countPeople c) 0 "nothing committed"⟩

-- @tg: verifies:: [[openspec:transactions#Rollback on failure#Handle released on failure]] {level: integration}
def handlesReleased : Test := ⟨"transactions: 1000 failed transactions release their handles", fun c => do
  setup c
  for _ in [0:1000] do
    discard <| (c.driver.runSync c.db .write (do
      exec typeql!"insert $p isa person, has email \"x\";"
      Tx.fail (.internal "boom") : Tx .write Unit)).toBaseIO
  -- A schema transaction needs every write transaction to be closed.
  c.driver.runSync c.db .schema (opts := { timeoutMs := 10000 }) (exec typeql!"define attribute extra, value string;")
  checkEq (← countPeople c) 0 "nothing committed"⟩

-- @tg: verifies:: [[openspec:transactions#Typed errors#Server error code]] {level: integration}
def serverCode : Test := ⟨"transactions: syntax errors carry the server code", fun c => do
  let e ← expectError (c.driver.runSync c.db .read (exec (Query.raw .read "match $x isa;")))
    (fun | .server .. => true | _ => false) "invalid TypeQL"
  match e with
  | .server code msg =>
    check (code.length ≥ 4 && code.toList.all (fun (ch : Char) => ch.isUpper || ch.isDigit)) s!"code '{code}'"
    check (!msg.isEmpty) "message"
  | _ => pure ()⟩

/-- Makes the transaction running `body` lose a conflict: while it is open, another transaction
deletes the counter it updates and commits first. -/
def conflictingUpdate (onAttempt : Nat → IO Unit := fun _ => pure ()) (attempts : IO.Ref Nat) :
    Tx .write Unit := do
  let k ← (attempts.modifyGet fun n => (n + 1, n + 1) : IO Nat)
  exec typeql!"match $c isa counter, has n $v; delete has $v of $c; insert $c has n {(Int64.ofNat k)};"
  (onAttempt k : IO Unit)

def interfere (c : Ctx) : IO Unit := do
  match ← (c.driver.runSync c.db .write
      (exec typeql!"match $c isa counter, has n $v; delete has $v of $c; insert $c has n 100;")).toBaseIO with
  | .ok () => pure ()
  | .error e => throw (IO.userError (toString e))

def setupCounter (c : Ctx) : EIO TypeDBError Unit := do
  setup c
  c.driver.runSync c.db .write (exec typeql!"insert $c isa counter, has n 0;")

-- @tg: verifies:: [[openspec:transactions#Typed errors#Conflict is distinguishable]] {level: integration}
def conflict : Test := ⟨"transactions: a lost commit is a conflict", fun c => do
  setupCounter c
  let attempts ← IO.mkRef 0
  discard <| expectError (c.driver.runSync c.db .write (conflictingUpdate (fun _ => interfere c) attempts))
    TypeDBError.isConflict "the losing commit"⟩

-- @tg: verifies:: [[openspec:transactions#Opt-in conflict retry#Retry recovers from a conflict]] {level: integration}
def retryRecovers : Test := ⟨"transactions: retry recovers from one conflict", fun c => do
  setupCounter c
  let attempts ← IO.mkRef 0
  c.driver.runSync c.db .write (retry := .conflicts 3 (.constant 10))
    (conflictingUpdate (fun k => if k == 1 then interfere c else pure ()) attempts)
  checkEq (← attempts.get) 2 "attempts"
  let n ← c.driver.runSync c.db .read (queryOne (α := Col "n" Int64) typeql!"match $c isa counter, has n $n;")
  checkEq n.val 2 "the successful attempt's write"⟩

-- @tg: verifies:: [[openspec:transactions#Opt-in conflict retry#Non-conflict errors are not retried]] {level: integration}
def noRetryOnOther : Test := ⟨"transactions: other errors are not retried", fun c => do
  let attempts ← IO.mkRef 0
  discard <| expectError (c.driver.runSync c.db .read (retry := .conflicts 5) do
      (attempts.modify (· + 1) : IO Unit)
      exec (Query.raw .read "match $x isa;"))
    (fun | .server .. => true | _ => false) "invalid query"
  checkEq (← attempts.get) 1 "attempts"⟩

-- @tg: verifies:: [[openspec:transactions#Opt-in conflict retry#Retries are bounded]] {level: integration}
def retryBounded : Test := ⟨"transactions: retries are bounded", fun c => do
  setupCounter c
  let attempts ← IO.mkRef 0
  discard <| expectError (c.driver.runSync c.db .write (retry := .conflicts 2 .none)
      (conflictingUpdate (fun _ => interfere c) attempts))
    TypeDBError.isConflict "always conflicting"
  checkEq (← attempts.get) 3 "1 + max retries"⟩

/-! ## Async -/

def slowRead (c : Ctx) (ms : UInt32) : EAsync TypeDBError Nat :=
  c.driver.run c.db .read do
    IO.sleep ms
    return (← queryWith (pure ()) typeql!"match $p isa person;").size

-- @tg: verifies:: [[openspec:async#Async transaction runs#Concurrent transactions overlap]] {level: integration}
def overlap : Test := ⟨"async: concurrent transactions overlap", fun c => do
  setup c
  let start ← IO.monoMsNow
  discard <| (EAsync.concurrently (slowRead c 300) (slowRead c 300)).block
  let ms := (← IO.monoMsNow) - start
  check (ms < 550) s!"took {ms} ms, expected less than the 600 ms sum"⟩

-- @tg: verifies:: [[openspec:async#Async transaction runs#Shared pool is not starved]] {level: integration}
def poolNotStarved : Test := ⟨"async: blocking transactions do not starve the task pool", fun c => do
  setup c
  -- More blocking transactions than the task pool has workers.
  let runs ← (Array.range 32).mapM fun _ => (slowRead c 800).asTask
  let start ← IO.monoMsNow
  let t := Task.spawn (prio := .default) fun _ => (List.range 1000).foldl (· + ·) 0
  discard <| IO.wait t
  let ms := (← IO.monoMsNow) - start
  for r in runs do discard <| ETask.block r
  check (ms < 500) s!"pure task finished after {ms} ms"⟩

-- @tg: verifies:: [[openspec:async#Blocking variant#Same semantics]] {level: integration}
def sameSemantics : Test := ⟨"async: run and runSync fail the same way", fun c => do
  setup c
  let body : Tx .write Unit := do
    exec typeql!"insert $p isa person, has email \"a\";"
    Tx.fail (.internal "boom")
  let e1 ← expectError (c.driver.runSync c.db .write body) (fun _ => true) "runSync"
  let e2 ← expectError (c.driver.run c.db .write body).block (fun _ => true) "run"
  checkEq (toString e1) (toString e2) "errors"
  checkEq (← countPeople c) 0 "neither committed"⟩

-- @tg: verifies:: [[openspec:async#Errors propagate through combinators#Race with failure]] {level: integration}
def combinatorErrors : Test := ⟨"async: errors propagate through concurrently", fun c => do
  setup c
  let bad : EAsync TypeDBError Nat := c.driver.run c.db .read (do Tx.fail (.internal "boom"))
  discard <| expectError (EAsync.concurrently (slowRead c 50) bad).block
    (fun | .internal "boom" => true | _ => false) "concurrently"⟩

/-! ## Native resources -/

def rssKb : IO Nat := do
  let pid ← IO.Process.getPID
  let out ← IO.Process.output { cmd := "ps", args := #["-o", "rss=", "-p", toString pid] }
  return (Str.trim out.stdout).toNat!

-- @tg: verifies:: [[openspec:native-driver#Native resources are released#No leaks across many queries]] {level: integration}
def noLeaks : Test := ⟨"native: memory is stable over 10000 queries", fun c => do
  setup c
  c.driver.runSync c.db .write do
    for i in [0:20] do exec typeql!"insert $p isa person, has email {s!"m{i}"}, has name \"n\";"
  let q := typeql!"match $p isa person, has email $e, has name $n;"
  let (base, after) ← c.driver.runSync c.db .read do
    for _ in [0:100] do discard <| query (α := Col "e" String × Col "n" String) q
    let base ← rssKb
    for _ in [0:9900] do discard <| query (α := Col "e" String × Col "n" String) q
    return (base, ← rssKb)
  check (after * 10 ≤ base * 11) s!"RSS grew from {base} KB to {after} KB"⟩

def all : Array Test :=
  #[connectOk, wrongPassword, unreachable, tlsDefault, missingCA, prefetch, createList, deleteDb,
    duplicateDb, shareable, composition, catchInside, commitVisible, rollbackOnError,
    handlesReleased, serverCode, conflict, retryRecovers, noRetryOnOther, retryBounded, overlap,
    poolNotStarved, sameSemantics, combinatorErrors, noLeaks]

end CoreTests
