import Harness
import Model

/-! Integration tests: the ORM and migrations. -/

namespace OrmTests

open TypeDB Harness Model

def setup (c : Ctx) : EIO TypeDBError Unit :=
  c.driver.runSync c.db .schema (Schema.defineTx schema)

def ann : Person := { email := "ann@x", name := "Ann", age := some 30, tags := #["a", "b", "c"] }
def bob : Employee := { email := "bob@x", name := "Bob", company := "Acme", salary := (Decimal.ofString? "1234.5").get! }

/-! ## ORM -/

-- @tg: verifies:: [[openspec:orm#Entity mapping#Insert and get by key]] {level: integration}
def insertGet : Test := ⟨"orm: insert and get by key", fun c => do
  setup c
  discard <| c.driver.runSync c.db .write (Entity.insert ann)
  let got ← c.driver.runSync c.db .read (Entity.get? (Ref.key (α := Person) "ann@x"))
  checkEq (got.map fun p => { p with tags := p.tags.qsort (· < ·) }) (some ann) "fetched"⟩

-- @tg: verifies:: [[openspec:orm#Entity mapping#Missing key returns none]] {level: integration}
def missingKey : Test := ⟨"orm: missing key returns none", fun c => do
  setup c
  let got ← c.driver.runSync c.db .read (Entity.get? (Ref.key (α := Person) "nobody@x"))
  check got.isNone "none"⟩

-- @tg: verifies:: [[openspec:orm#Multi-valued attributes#Tags round trip]] {level: integration}
def tags : Test := ⟨"orm: multi-valued attribute round trip", fun c => do
  setup c
  let r ← c.driver.runSync c.db .write (Entity.insert ann)
  let some p ← c.driver.runSync c.db .read (Entity.get? r) | check false "found"
  checkEq (p.tags.qsort (· < ·)) #["a", "b", "c"] "tags"⟩

-- @tg: verifies:: [[openspec:orm#Relation mapping#Insert relation between entities]] {level: integration}
def relation : Test := ⟨"orm: relation between entities", fun c => do
  setup c
  let (a, b, f) ← c.driver.runSync c.db .write do
    let a ← Entity.insert ann
    let b ← Entity.insert bob
    let f ← Relation.insert { a := Ref.key "ann@x", b := Ref.key "bob@x", since := 2020 : Friendship }
    return (a, b, f)
  let some fr ← c.driver.runSync c.db .read (Relation.get? f) | check false "found"
  checkEq fr.since 2020 "attribute"
  let players := #[fr.a.iid?, fr.b.iid?]
  check (players.contains a.iid? && players.contains (b.up (β := Person)).iid?) "both players"⟩

-- @tg: verifies:: [[openspec:orm#References by key or IID#Insert returns IID]] {level: integration}
def insertIID : Test := ⟨"orm: insert returns an IID reference", fun c => do
  setup c
  let f ← c.driver.runSync c.db .write do
    let a ← Entity.insert ann
    let b ← Entity.insert { ann with email := "b@x" }
    Relation.insert { a, b, since := 1 : Friendship }
  check f.iid?.isSome "IID reference"
  let got ← c.driver.runSync c.db .read (Relation.get? f)
  checkEq (got.map (·.since)) (some 1) "resolves to the relation"⟩

-- @tg: verifies:: [[openspec:orm#References by key or IID#Key reference to missing instance]] {level: integration}
def missingPlayer : Test := ⟨"orm: key reference to a missing player", fun c => do
  setup c
  discard <| c.driver.runSync c.db .write (Entity.insert ann)
  discard <| expectError (c.driver.runSync c.db .write
      (Relation.insert { a := Ref.key "ann@x", b := Ref.key "ghost@x", since := 1 : Friendship }))
    (fun _ => true) "inserting with a missing player"
  checkEq (← c.driver.runSync c.db .read (Relation.count (α := Friendship))) 0 "nothing inserted"⟩

-- @tg: verifies:: [[openspec:orm#Relations as role players#Endorsement of a friendship]] {level: integration}
def relationPlayer : Test := ⟨"orm: a relation playing a role", fun c => do
  setup c
  let (f, e) ← c.driver.runSync c.db .write do
    let a ← Entity.insert ann
    let b ← Entity.insert bob
    let f ← Relation.insert { a, b := b.up, since := 2020 : Friendship }
    let e ← Relation.insert { endorsed := f, endorser := a, note := some "great" : Endorsement }
    return (f, e)
  let some en ← c.driver.runSync c.db .read (Relation.get? e) | check false "found"
  checkEq en.endorsed.iid? f.iid? "endorsed friendship"
  checkEq en.note (some "great") "note"⟩

-- @tg: verifies:: [[openspec:orm#Subtyping#Subtype instance is a parent instance]] {level: integration}
def subtyping : Test := ⟨"orm: a subtype instance is a parent instance", fun c => do
  setup c
  let r ← c.driver.runSync c.db .write (Entity.insert bob)
  let people ← c.driver.runSync c.db .read (Entity.all (α := Person))
  checkEq (people.map (·.2.email)) #["bob@x"] "persons include the employee"
  let some e ← c.driver.runSync c.db .read (Entity.get? r) | check false "found"
  checkEq e bob "employee fields"⟩

-- @tg: verifies:: [[openspec:orm#Polymorphic decoding#Mixed person types]] {level: integration}
def polymorphic : Test := ⟨"orm: polymorphic decoding", fun c => do
  setup c
  c.driver.runSync c.db .write do
    discard <| Entity.insert ann
    discard <| Entity.insert bob
  let all ← c.driver.runSync c.db .read (Polymorphic.all (α := AnyPerson))
  let kinds := all.map fun (_, p) => match p with
    | .person p => s!"person {p.email}" | .employee e => s!"employee {e.email} {e.company}"
  checkEq (kinds.qsort (· < ·)) #["employee bob@x Acme", "person ann@x"] "constructors"⟩

-- @tg: verifies:: [[openspec:orm#Update and delete#Update attribute]] {level: integration}
def update : Test := ⟨"orm: update an attribute", fun c => do
  setup c
  let r ← c.driver.runSync c.db .write (Entity.insert ann)
  c.driver.runSync c.db .write do
    Entity.update r Person.field.name "Annie"
    Entity.update r Person.field.age none
    Entity.update r Person.field.tags #["z"]
  let some p ← c.driver.runSync c.db .read (Entity.get? r) | check false "found"
  checkEq (p.name, p.age, p.tags) ("Annie", none, #["z"]) "updated"
  let names ← c.driver.runSync c.db .read
    (query (α := Col "n" String) typeql!"match $p isa person, has name $n;")
  checkEq (names.map (·.val)) #["Annie"] "old name no longer owned"⟩

-- @tg: verifies:: [[openspec:orm#Update and delete#Delete]] {level: integration}
def delete : Test := ⟨"orm: delete", fun c => do
  setup c
  let r ← c.driver.runSync c.db .write (Entity.insert ann)
  c.driver.runSync c.db .write (Entity.delete r)
  check (← c.driver.runSync c.db .read (Entity.get? r)).isNone "gone"⟩

-- @tg: verifies:: [[openspec:orm#Schema generation#Generated schema is accepted]] {level: integration}
def schemaAccepted : Test := ⟨"orm: the generated schema is accepted", fun c => do
  setup c
  setup c -- defining again is harmless
  let s ← c.driver.typeSchema c.db
  check (Str.contains s "entity employee" && Str.contains s "relates friend @card(0..2)") "schema"⟩

-- @tg: verifies:: [[openspec:orm#Schema verification#Matching schema passes]] {level: integration}
def verifyOk : Test := ⟨"orm: verification passes on the generated schema", fun c => do
  setup c
  let issues ← c.driver.runSync c.db .read (Schema.verify schema)
  checkEq issues.length 0 s!"issues {issues.map toString}"⟩

-- @tg: verifies:: [[openspec:orm#Schema verification#Drift is reported]] {level: integration}
def verifyDrift : Test := ⟨"orm: verification reports drift", fun c => do
  c.driver.runSync c.db .schema (exec typeql!"define attribute email, value string; attribute name, value string;
    entity person, owns email @key, owns name;")
  let issues ← c.driver.runSync c.db .read (Schema.verify [TypeSpec.of Person])
  check (issues.contains (.missingOwns "person" "age")) s!"issues {issues.map toString}"
  check (issues.contains (.missingOwns "person" "tags")) "tags missing too"
  discard <| expectError (c.driver.runSync c.db .read (Schema.verify! [TypeSpec.of Person]))
    (fun | .schemaMismatch .. => true | _ => false) "verify!"⟩

/-! ## Migrations -/

def m1 : Migration := Migration.tql 1 "people" "define attribute name, value string; entity person, owns name;"
  (down := some "undefine person; name;")
def m2 : Migration := Migration.tql 2 "ages" "define attribute age, value integer; person owns age;"
  (down := some "undefine owns age from person; age;")
def m3 : Migration :=
  { version := 3, name := "seed", fingerprint := "seed ann"
    up := exec typeql!"insert $p isa person, has name \"Ann\", has age 1;"
    down := .step (exec typeql!"match $p isa person; delete $p;") }

-- @tg: verifies:: [[openspec:migrations#Versioned migrations#Duplicate versions rejected]] {level: integration}
def duplicates : Test := ⟨"migrations: duplicate versions are rejected", fun c => do
  discard <| expectError (c.driver.migrateSync c.db [m1, { m2 with version := 1 }])
    (fun | .migration 1 _ => true | _ => false) "duplicate"
  checkEq (← Migrations.history c.driver c.db).size 0 "nothing ran"⟩

-- @tg: verifies:: [[openspec:migrations#Migrate applies pending steps#Fresh database]] {level: integration}
def fresh : Test := ⟨"migrations: a fresh database gets every step", fun c => do
  let r ← (c.driver.migrate c.db [m1, m2, m3]).block
  checkEq (r.steps.map (·.1)) #[1, 2, 3] "applied"
  checkEq ((← Migrations.history c.driver c.db).map (·.version)) #[1, 2, 3] "history"⟩

-- @tg: verifies:: [[openspec:migrations#Migrate applies pending steps#Already up to date]] {level: integration}
def upToDate : Test := ⟨"migrations: nothing to do the second time", fun c => do
  discard <| c.driver.migrateSync c.db [m1, m2, m3]
  let r ← c.driver.migrateSync c.db [m1, m2, m3]
  checkEq r.steps.size 0 "no steps"⟩

-- @tg: verifies:: [[openspec:migrations#Atomic steps#Failing step]] {level: integration}
def failingStep : Test := ⟨"migrations: a failing step leaves no trace", fun c => do
  let bad := Migration.tql 2 "bad" "define entity person, owns nonexistent;"
  discard <| expectError (c.driver.migrateSync c.db [m1, bad, m3])
    (fun | .migration 2 _ => true | _ => false) "step 2"
  checkEq ((← Migrations.history c.driver c.db).map (·.version)) #[1] "only step 1 applied"
  let people ← c.driver.runSync c.db .read (queryWith (pure ()) typeql!"match $p isa person;")
  checkEq people.size 0 "step 3 did not run"⟩

-- @tg: verifies:: [[openspec:migrations#Migration history#History is queryable]] {level: integration}
def historyRows : Test := ⟨"migrations: history records version, name, checksum and time", fun c => do
  discard <| c.driver.migrateSync c.db [m1, m2]
  let h ← Migrations.history c.driver c.db
  checkEq (h.map fun a => (a.version, a.name, a.checksum)) #[(1, "people", m1.checksum), (2, "ages", m2.checksum)] "history"
  check (h.all fun a => (Time.splitPlainDateTime a.appliedAt).1 > 1700000000) "applied-at"⟩

-- @tg: verifies:: [[openspec:migrations#Checksum drift detection#Edited applied step]] {level: integration}
def drift : Test := ⟨"migrations: an edited applied step is rejected", fun c => do
  discard <| c.driver.migrateSync c.db [m1]
  let edited := Migration.tql 1 "people" "define attribute name, value string; entity person, owns name @card(1..1);"
  discard <| expectError (c.driver.migrateSync c.db [edited, m2])
    (fun | .migration 1 _ => true | _ => false) "drift"
  checkEq (← Migrations.history c.driver c.db).size 1 "step 2 did not run"⟩

-- @tg: verifies:: [[openspec:migrations#Rollback#Roll back two steps]] {level: integration}
def rollbackTwo : Test := ⟨"migrations: roll back two steps", fun c => do
  discard <| c.driver.migrateSync c.db [m1, m2, m3]
  let r ← (c.driver.rollback c.db [m1, m2, m3] (to := 1)).block
  checkEq (r.steps.map (·.1)) #[3, 2] "rolled back newest first"
  checkEq ((← Migrations.history c.driver c.db).map (·.version)) #[1] "history"
  check (!(Str.contains (← c.driver.typeSchema c.db) "attribute age")) "age undefined"⟩

-- @tg: verifies:: [[openspec:migrations#Rollback#Irreversible step]] {level: integration}
def irreversible : Test := ⟨"migrations: an irreversible step stops the rollback", fun c => do
  let m2i := { m2 with down := .irreversible }
  discard <| c.driver.migrateSync c.db [m1, m2i, m3]
  discard <| expectError (c.driver.rollbackSync c.db [m1, m2i, m3] (to := 0))
    (fun | .migration 2 _ => true | _ => false) "irreversible step 2"
  checkEq ((← Migrations.history c.driver c.db).map (·.version)) #[1, 2] "step 3 rolled back, 2 kept"⟩

-- @tg: verifies:: [[openspec:migrations#Schema helpers#Load schema file]] {level: integration}
def loadFile : Test := ⟨"migrations: a step from a .tql file", fun c => do
  let path : System.FilePath := s!"/tmp/{c.db}.tql"
  IO.FS.writeFile path "define attribute title, value string; entity book, owns title;"
  let m ← Migration.ofFile 1 "books" path
  discard <| c.driver.migrateSync c.db [m]
  IO.FS.removeFile path
  check (Str.contains (← c.driver.typeSchema c.db) "entity book") "book defined"⟩

def all : Array Test :=
  #[insertGet, missingKey, tags, relation, insertIID, missingPlayer, relationPlayer, subtyping,
    polymorphic, update, delete, schemaAccepted, verifyOk, verifyDrift, duplicates, fresh, upToDate,
    failingStep, historyRows, drift, rollbackTwo, irreversible, loadFile]

end OrmTests
