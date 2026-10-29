import Std.Async
import TypeDB.Tx

/-!
# Async transactions

`Driver.run` returns a `Std.Async.EAsync TypeDBError α`. The driver's calls block their thread,
so each transaction runs on a thread of its own (`Task.Priority.dedicated`) and never occupies
one of the task pool's workers. Combine transactions with `Std.Async` combinators such as
`EAsync.concurrently`, `EAsync.race` and `EAsync.concurrentlyAll`, and wait for the result with
`EAsync.wait` or `EAsync.block`.
-/

namespace TypeDB

open Std.Async

/-- Runs a blocking TypeDB action on a dedicated thread, as an `EAsync` computation. -/
def blocking {α : Type} (x : EIO TypeDBError α) : EAsync TypeDBError α := do
  let task ← EAsync.lift (BaseIO.toEIO (EIO.asTask x .dedicated))
  EAsync.await (ExceptT.mk task)

namespace Driver

/-- Runs a transaction on a dedicated thread. Same commit, rollback and retry semantics as
`runSync`. -/
-- @tg: implements:: [[openspec:async#Async transaction runs]]
-- @tg: implements:: [[openspec:async#Errors propagate through combinators]]
def run {α : Type} (d : Driver) (db : String) (mode : TxMode) (body : Tx mode α)
    (retry : RetryPolicy := .never) (opts : TxOptions := {}) : EAsync TypeDBError α :=
  blocking (d.runSync db mode body retry opts)

end Driver

end TypeDB
