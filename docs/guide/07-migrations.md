# Migrations

```lean
def migrations : List Migration := [
  Migration.define 1 "schema" schema,                     -- the ORM schema
  Migration.tql 2 "nicknames"
    "define attribute nickname, value string; person owns nickname;"
    (down := some "undefine owns nickname from person; nickname;"),
  { version := 3, name := "backfill nicknames", fingerprint := "nickname := name, v1"
    up := exec typeql!"match $p isa person, has name $n; not \{ $p has nickname $k; }; insert $p has nickname == $n;"
    down := .step (exec typeql!"match $p isa person, has nickname $k; delete has $k of $p;") }
]

let report ← d.migrateSync "social" migrations      -- the steps it ran
let report ← d.rollbackSync "social" migrations (to := 1)
let history ← Migrations.history d "social"
```

- Versions must be unique and increasing. `migrate` applies, in order, every step newer than the latest applied one.
- Each step runs in its own schema transaction together with its history record (`typedb-lean-migration` entities in the same database). If a step fails, neither its changes nor its record are committed, the steps before it stay applied, and the error names its version.
- Every step has a checksum of its name and `fingerprint`. If an applied step's checksum differs from the list's, `migrate` stops before running anything. Steps from TypeQL (`Migration.tql`, `Migration.define`, `Migration.ofFile`) use their text as the fingerprint. Lean code cannot be hashed, so steps written as code must give a `fingerprint` that changes whenever the code does.
- `rollback` runs `down` steps newest first, each with the removal of its record. `.irreversible` stops the rollback before that step.
- Schema transactions can read and write data, so one step can change the schema and backfill data atomically.
