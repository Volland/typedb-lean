import TypeDB.Driver
import TypeDB.TypeQL

/-!
# Transactions

`Tx m α` is a transaction body of mode `m` that returns `α`. Bodies compose with `do` notation,
raise and catch `TypeDBError`, and run `IO` (whose errors become `TypeDBError.io`).

`Tx` is an irreducible definition, not an abbreviation, so that `Tx .read α` and `Tx .write α`
are different types: a body that writes cannot be passed where a read body is expected. Operations take an
`[Allows m need]` instance, so a read-mode body cannot call one that needs a write.

`Driver.runSync` is the transactor: it opens the transaction, runs the body, commits a write or
schema transaction when the body succeeds, and closes the transaction without committing when
the body fails. A retry policy can re-run the whole body when the commit loses a conflict.
-/

namespace TypeDB

/-- What a transaction body runs against. -/
structure TxCtx where
  driver : Driver
  handle : Native.TxHandle
  database : String
  mode : TxMode
  options : TxOptions

/-- A transaction body of mode `m` returning `α`: a reader over the transaction's context.
It is irreducible, so `Tx .read α` and `Tx .write α` stay different types, while the compiler
still sees a `ReaderT` over `EIO` and turns loops over it into plain loops. -/
-- @tg: implements:: [[openspec:transactions#Mode-indexed transactions]]
-- @tg: implements:: [[openspec:transactions#Transactions compose monadically]]
def Tx (_m : TxMode) (α : Type) : Type := ReaderT TxCtx (EIO TypeDBError) α

namespace Tx

variable {m n : TxMode} {α β : Type}

@[always_inline, inline] def mk (f : TxCtx → EIO TypeDBError α) : Tx m α := f
@[always_inline, inline] def run (x : Tx m α) : TxCtx → EIO TypeDBError α := x

instance : Monad (Tx m) := inferInstanceAs (Monad (ReaderT TxCtx (EIO TypeDBError)))
instance : MonadExceptOf TypeDBError (Tx m) :=
  inferInstanceAs (MonadExceptOf TypeDBError (ReaderT TxCtx (EIO TypeDBError)))
instance : MonadFinally (Tx m) := inferInstanceAs (MonadFinally (ReaderT TxCtx (EIO TypeDBError)))
instance : MonadLift (EIO TypeDBError) (Tx m) :=
  inferInstanceAs (MonadLift (EIO TypeDBError) (ReaderT TxCtx (EIO TypeDBError)))
instance : MonadLift IO (Tx m) := ⟨fun x => mk fun _ => liftM (n := EIO TypeDBError) x⟩
instance : MonadLift BaseIO (Tx m) := ⟨fun x => mk fun _ => liftM x⟩

/-- Runs a body of a weaker mode inside a stronger transaction. -/
@[inline] def widen [TxMode.Allows m n] (x : Tx n α) : Tx m α := mk x.run

instance : MonadLift (Tx .read) (Tx .write) := ⟨widen⟩
instance : MonadLift (Tx .read) (Tx .schema) := ⟨widen⟩
instance : MonadLift (Tx .write) (Tx .schema) := ⟨widen⟩

instance : Inhabited (Tx m α) := ⟨mk fun _ => throw (.internal "uninhabited transaction body")⟩

/-- The transaction's context. -/
@[inline] def ctx : Tx m TxCtx := mk pure

/-- Runs a native call, classifying its error. -/
@[inline] def native (x : Native.NIO α) : Tx m α := liftM (TypeDB.native x)

/-- Raises a typed error. -/
@[inline] def fail (e : TypeDBError) : Tx m α := throw e

/-- Rolls back the writes made so far without ending the transaction. -/
def rollback [TxMode.Allows m .write] : Tx m Unit := do
  Tx.native (Native.txRollback (← ctx).handle)

end Tx

attribute [irreducible] Tx

/-- Transactions that may implement `Tx m` operations, for user monad stacks such as
`ReaderT Env (Tx .write)`. Any monad with a `MonadLiftT (Tx m)` instance qualifies. -/
abbrev MonadTypeDB (m : TxMode) (n : Type → Type) := MonadLiftT (Tx m) n

/-- Backoff between retries. -/
inductive Backoff where
  | none
  | constant (ms : Nat)
  /-- `base · 2^attempt` milliseconds, capped at `maxMs`. -/
  | exponential (baseMs : Nat) (maxMs : Nat := 5000)
  deriving Repr, Inhabited

/-- When `run` re-runs a transaction body. -/
inductive RetryPolicy where
  | never
  /-- Re-run on commit conflicts, at most `retries` times. Other errors are never retried. -/
  | conflicts (retries : Nat) (backoff : Backoff := .exponential 20)
  deriving Repr, Inhabited

namespace RetryPolicy

def delayMs : Backoff → Nat → Nat
  | .none, _ => 0
  | .constant ms, _ => ms
  | .exponential b cap, attempt => min cap (b * 2 ^ attempt)

end RetryPolicy

namespace Driver

variable {α : Type}

/-- Opens one transaction, runs `body`, and commits (write and schema mode) or closes (read
mode). If the body fails, the transaction is closed without committing and the error is
returned. -/
def runOnce (d : Driver) (db : String) (mode : TxMode) (body : Tx mode α) (opts : TxOptions := {}) :
    EIO TypeDBError α := do
  let h ← native <| Native.txOpen d.handle db mode.code (Int64.ofNat opts.timeoutMs) (Int64.ofNat opts.prefetch)
  let ctx : TxCtx := { driver := d, handle := h, database := db, mode, options := opts }
  try
    let a ← body.run ctx
    if mode != .read then native (Native.txCommit h)
    return a
  finally
    discard <| ((native (Native.txClose h)).toBaseIO : BaseIO _)

/-- Runs a transaction on the calling thread, retrying the whole body on commit conflicts if
`retry` says so. -/
-- @tg: implements:: [[openspec:transactions#Commit on success]]
-- @tg: implements:: [[openspec:transactions#Rollback on failure]]
-- @tg: implements:: [[openspec:transactions#Opt-in conflict retry]]
-- @tg: implements:: [[openspec:async#Blocking variant]]
def runSync (d : Driver) (db : String) (mode : TxMode) (body : Tx mode α)
    (retry : RetryPolicy := .never) (opts : TxOptions := {}) : EIO TypeDBError α :=
  match retry with
  | .never => d.runOnce db mode body opts
  | .conflicts n backoff => go backoff 0 n
where
  /-- `fuel` is the number of retries left. -/
  go (backoff : Backoff) (attempt : Nat) : Nat → EIO TypeDBError α
    | 0 => d.runOnce db mode body opts
    | fuel + 1 => do
      match ← ((d.runOnce db mode body opts).toBaseIO : BaseIO (Except TypeDBError α)) with
      | .ok a => pure a
      | .error e =>
        unless e.isConflict do throw e
        let ms := RetryPolicy.delayMs backoff attempt
        if ms > 0 then IO.sleep (UInt32.ofNat ms)
        go backoff (attempt + 1) fuel

end Driver

end TypeDB
