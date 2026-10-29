# The ORM

## Mapping types

```lean
@[typedb "person"]                     -- the type label; default: the name in kebab-case
structure Person where
  email : Key String                   -- owns email @key
  name : String                        -- owns name @card(1..1)
  age : Option Int64 := none           -- owns age
  tags : Array String := #[]           -- owns tags @card(0..)
  nick : Attr "nickname" (Option String) := none   -- attribute label override
  deriving Entity

structure Employee extends Person where   -- employee sub person
  company : String
  deriving Entity

structure Friendship where
  a : Role "friend" (Ref Person)       -- relates friend; person plays friendship:friend
  b : Role "friend" (Ref Person)
  since : Int64
  deriving Relation

structure Endorsement where
  endorsed : Role "endorsed" (Ref Friendship)   -- a relation playing a role
  endorser : Role "endorser" (Ref Person)
  deriving Relation
```

`Key`, `Role` and `Attr` are transparent: a `Key String` is a `String`. Lean does not accept attributes on structure fields, so the markers sit in the field types instead.

## References

`Ref α` points at an instance by key (`Ref.key (α := Person) "ann@example.com"`) or by IID. `Entity.insert` returns an IID reference. `r.up` views a reference to a subtype as one to its supertype.

## Operations

```lean
let ann ← Entity.insert ({ email := "ann@x", name := "Ann" } : Person)  -- Ref Person
let p? ← Entity.get? ann                                  -- Option Person
let all ← Entity.all (α := Person)                        -- includes subtype instances
Entity.update ann Person.field.name "Annie"                -- typed field handles
Entity.update ann Person.field.age none                    -- removes the attribute
Entity.delete ann
let n ← Entity.count (α := Person)
```

`Relation.insert`, `Relation.get?` and the others work the same way for relations. Inserting a relation whose key reference matches no instance fails, and nothing is inserted.

Reads fetch all of an instance's attributes and role players in two queries, however many instances there are. Fields that share a role take its players in order.

## Polymorphism

```lean
inductive AnyPerson where
  | person (p : Person)
  | employee (e : Employee)
  deriving Polymorphic

for (iid, p) in ← Polymorphic.all (α := AnyPerson) do
  match p with
  | .person p => …
  | .employee e => …
```

The first constructor's type is the root that is queried. Each instance decodes into the constructor of its own type, or into the first constructor if its type is not listed.

## Schema

```lean
def schema := [TypeSpec.of Person, TypeSpec.of Employee, TypeSpec.of Friendship, TypeSpec.of Endorsement]

Schema.defineText schema        -- the TypeQL define, as text
d.runSync db .schema (Schema.defineTx schema)
let issues ← d.runSync db .read (Schema.verify schema)   -- List SchemaIssue
d.runSync db .read (Schema.verify! schema)               -- fails with schemaMismatch
```

`verify` reports missing types, wrong kinds, wrong supertypes, attributes that are not owned or have another value type, and missing `relates` and `plays`.
