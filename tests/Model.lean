import TypeDB

/-! The mapped types the ORM and migration tests use. -/

namespace Model

open TypeDB

@[typedb "person"]
structure Person where
  email : Key String
  name : String
  age : Option Int64 := none
  tags : Array String := #[]
  deriving Repr, BEq, Entity

structure Employee extends Person where
  company : String
  salary : Decimal
  deriving Repr, BEq, Entity

structure Friendship where
  a : Role "friend" (Ref Person)
  b : Role "friend" (Ref Person)
  since : Int64
  deriving Repr, BEq, Relation

structure Endorsement where
  endorsed : Role "endorsed" (Ref Friendship)
  endorser : Role "endorser" (Ref Person)
  note : Option String := none
  deriving Repr, BEq, Relation

inductive AnyPerson where
  | person (p : Person)
  | employee (e : Employee)
  deriving Repr, Polymorphic

def schema : List TypeSpec :=
  [TypeSpec.of Person, TypeSpec.of Employee, TypeSpec.of Friendship, TypeSpec.of Endorsement]

end Model
