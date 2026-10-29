import TypeDB

/-!
# A small social network

Runs against the server at `TYPEDB_ADDRESS` (default `127.0.0.1:1729`) and recreates the
database `social`:

    lake exe social

It shows the mapped types (entities, a subtype, relations, a relation playing a role in another
relation), migrations, ORM inserts and reads, typed TypeQL queries, streaming, polymorphic
decoding and concurrent transactions.
-/

open TypeDB

namespace Social

@[typedb "person"]
structure Person where
  email : Key String
  name : String
  age : Option Int64 := none
  tags : Array String := #[]
  deriving Repr, Entity

structure Employee extends Person where
  company : String
  salary : Decimal
  deriving Repr, Entity

structure Friendship where
  a : Role "friend" (Ref Person)
  b : Role "friend" (Ref Person)
  since : Std.Time.PlainDate
  deriving Repr, Relation

/-- A relation whose `endorsed` player is itself a relation. -/
structure Endorsement where
  endorsed : Role "endorsed" (Ref Friendship)
  endorser : Role "endorser" (Ref Person)
  note : Option String := none
  deriving Repr, Relation

structure Post where
  id : Key String
  body : String
  tags : Array String := #[]
  postedAt : DatetimeTZ
  deriving Repr, Entity

structure Authorship where
  author : Role "author" (Ref Person)
  post : Role "post" (Ref Post)
  deriving Repr, Relation

/-- Every person, decoded as an `Employee` when it is one. -/
inductive AnyPerson where
  | person (p : Person)
  | employee (e : Employee)
  deriving Repr, Polymorphic

/-- A row of a hand-written query: each field is read from the variable of the same name. -/
structure FriendOf where
  name : String
  friend : String
  deriving Repr, FromRow

def schema : List TypeSpec :=
  [TypeSpec.of Person, TypeSpec.of Employee, TypeSpec.of Friendship, TypeSpec.of Endorsement,
   TypeSpec.of Post, TypeSpec.of Authorship]

def migrations : List Migration := [
  Migration.define 1 "social schema" schema,
  Migration.tql 2 "nicknames"
    "define attribute nickname, value string; person owns nickname;"
    (down := some "undefine owns nickname from person; nickname;"),
  { version := 3, name := "default nickname", fingerprint := "nickname := name, v1"
    up := exec typeql!"match $p isa person, has name $n; not \{ $p has nickname $k; }; insert $p has nickname == $n;"
    down := .step (exec typeql!"match $p isa person, has nickname $k; delete has $k of $p;") }
]

def seed : Tx .write (Ref Post) := do
  let ann ← Entity.insert { email := "ann@example.com", name := "Ann", age := some 34, tags := #["lean", "graphs"] : Person }
  let bob ← Entity.insert { email := "bob@example.com", name := "Bob", company := "Acme", salary := 4200, tags := #["rust"] : Employee }
  discard <| Entity.insert { email := "cy@example.com", name := "Cy \"the quoted\"" : Person }
  let f ← Relation.insert { a := ann, b := bob.up, since := Std.Time.PlainDate.ofYearMonthDayClip 2021 3 14 : Friendship }
  discard <| Relation.insert { endorsed := f, endorser := Ref.key (α := Person) "cy@example.com", note := some "true friends" : Endorsement }
  let at_ := DatetimeTZ.ofLocalFixed (Std.Time.PlainDateTime.ofEpochDay ⟨19000⟩ ⟨⟨9, by decide⟩, ⟨30, by decide⟩, ⟨0, by decide⟩, ⟨0, by decide⟩⟩) 3600
  let post ← Entity.insert { id := "p1", body := "Typed graphs from Lean", tags := #["lean"], postedAt := at_ : Post }
  discard <| Relation.insert { author := ann, post := post : Authorship }
  return post

def report : Tx .read Unit := do
  IO.println "-- people (polymorphic):"
  for (_, p) in ← Polymorphic.all (α := AnyPerson) do
    match p with
    | .person p => IO.println s!"  person   {p.name} <{p.email}> tags={p.tags}"
    | .employee e => IO.println s!"  employee {e.name} at {e.company}, salary {e.salary}"
  IO.println "-- friendships (typed query):"
  for r in stream (α := FriendOf) typeql!"match $f isa friendship, links (friend: $x, friend: $y);
      $x has name $name; $y has name $friend;" do
    IO.println s!"  {r.name} ↔ {r.friend}"
  let nicknames ← queryFold (α := Col "k" String) typeql!"match $p isa person, has nickname $k;" 0 fun n _ => n + 1
  IO.println s!"-- {nicknames} nicknames, {← Entity.count (α := Person)} people, {← Relation.count (α := Endorsement)} endorsements"

def main : IO UInt32 := do
  let address := (← IO.getEnv "TYPEDB_ADDRESS").getD "127.0.0.1:1729"
  let result ← (Driver.withDriver { address } fun d => do
    if ← d.databaseExists "social" then d.deleteDatabase "social"
    d.createDatabase "social"
    let applied ← d.migrateSync "social" migrations
    IO.println s!"-- migrations applied: {applied.steps.toList}"
    d.runSync "social" .read (Schema.verify! schema)
    let post ← d.runSync "social" .write seed
    let ann := Ref.key (α := Person) "ann@example.com"
    d.runSync "social" .write (Entity.update ann Person.field.age (some 35))
    d.runSync "social" .read report
    -- Two read transactions at once, on their own threads.
    let (people, posts) ← (Std.Async.EAsync.concurrently
      (d.run "social" .read (Entity.all (α := Person)))
      (d.run "social" .read (Entity.all (α := Post)))).block
    IO.println s!"-- concurrently: {people.size} people, {posts.size} posts"
    if let some p ← d.runSync "social" .read (Entity.get? post) then
      IO.println s!"-- post {p.id}: {p.body} at {render p.postedAt}"
    d.runSync "social" .write (Entity.delete post)
    IO.println s!"-- post deleted: {(← d.runSync "social" .read (Entity.get? post)).isNone}"
    : EIO TypeDBError Unit).toBaseIO
  match result with
  | .ok () => return 0
  | .error e => IO.eprintln s!"error: {e}"; return 1

end Social

def main : IO UInt32 := Social.main
