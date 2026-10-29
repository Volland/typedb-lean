# Transactions and errors

## Modes

A transaction body has type `Tx m α`, where `m` is `.read`, `.write` or `.schema`. The modes are ordered `read ≤ write ≤ schema`: a schema transaction may also write data, and a write transaction may read.

Every query carries the weakest mode that may run it, and every operation asks for `[TxMode.Allows m need]`. So this does not compile:

```lean
def broken : Tx .read Unit :=
  exec typeql!"match $p isa person; insert $p has name \"x\";"
-- failed to synthesize instance of type class TxMode.read.Allows TxMode.write
```

Helpers of a weaker mode lift into stronger bodies automatically. A `Tx .read α` can be used inside a `Tx .write` body. To write helpers that work in any sufficient mode, take the mode as a parameter:

```lean
def countPeople {m : TxMode} [TxMode.Allows m .read] : Tx m Nat := do
  let n ← queryOne (α := Col "c" Int64) typeql!"match $p isa person; reduce $c = count;"
  return n.val.toInt.toNat
```

## Running a transaction

```lean
d.runSync "db" .write body          -- EIO TypeDBError α, on this thread
d.run "db" .write body              -- EAsync TypeDBError α, on its own thread (see Async)
```

Both open the transaction and run `body`. If `body` succeeds, they commit (write and schema mode) or close (read mode) the transaction. If `body` fails, they close it without committing and return the error. `TxOptions` sets the transaction timeout, the prefetch size and the batch size:

```lean
d.runSync "db" .read (opts := { timeoutMs := 10000, prefetch := 1024 }) body
```

Bodies are ordinary `do` blocks. They can call `IO` (an `IO` error becomes `TypeDBError.io`), raise errors with `Tx.fail`, and catch them with `try … catch`:

```lean
d.runSync "db" .write do
  exec typeql!"insert $p isa person, has name \"a\";"
  try
    discard <| query (α := Col "n" Int64) typeql!"match $p has name $n;"
  catch
    | .decode col expected got => IO.println s!"{col}: expected {expected}, got {got}"
    | e => throw e
```

## Errors

`TypeDBError` has one constructor per kind of failure:

| Constructor | Meaning |
|---|---|
| `connection code msg` | unreachable server, bad credentials, TLS problems |
| `server code msg` | the server rejected a request; `code` is TypeDB's code, e.g. `TQL03` |
| `conflict msg` | the commit lost against a concurrent transaction |
| `decode column expected got` | a column or document did not have the expected shape |
| `schemaMismatch issues` | `Schema.verify!` found differences |
| `migration version msg` | a migration step failed or was rejected |
| `io msg` / `internal msg` | an `IO` error in a body / a misuse of the library |

## Retrying conflicts

TypeDB detects conflicting writes when a transaction commits. A retry policy re-runs the whole body when, and only when, the commit loses a conflict:

```lean
d.runSync "db" .write (retry := .conflicts 5 (.exponential 20)) transfer
```

The body runs at most `1 + 5` times. Other errors are returned at once. Because the body runs again, any `IO` it performs runs again too.
