# Async

`Driver.run` returns a `Std.Async.EAsync TypeDBError α`. The driver blocks the thread it runs on, so every transaction gets a thread of its own (`Task.Priority.dedicated`), and the task pool stays free for other work. Combine runs with the standard combinators:

```lean
open Std.Async

def report (d : Driver) : EAsync TypeDBError (Array (Ref Person × Person) × Nat) :=
  EAsync.concurrently
    (d.run "social" .read (Entity.all (α := Person)))
    (d.run "social" .read (Entity.count (α := Post)))

-- wait for it from EIO:
let (people, posts) ← (report d).block
```

`EAsync.concurrentlyAll` runs an array of transactions at once, and `EAsync.race` returns the first result. If any combined transaction fails, the whole computation fails with that transaction's `TypeDBError`.

One driver can be shared by any number of concurrent transactions; it multiplexes them over its connection. Inside one transaction, the body runs sequentially.

`Driver.migrate` and `Driver.rollback` are async as well; `migrateSync` and `rollbackSync` block.
