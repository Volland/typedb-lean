import TypeDB

/-! Misuse that must not compile. These run when the test library is built. -/

open TypeDB

-- @tg: verifies:: [[openspec:transactions#Mode-indexed transactions#Write in read transaction does not compile]] {level: unit}
/--
error: failed to synthesize instance of type class
  TxMode.read.Allows TxMode.write

Hint: Type class instance resolution failures can be inspected with the `set_option trace.Meta.synthInstance true` command.
-/
#guard_msgs in
example : Tx .read Unit := exec typeql!"match $p isa person; insert $p has name \"x\";"

-- @tg: verifies:: [[openspec:transactions#Mode-indexed transactions#Read in write transaction compiles]] {level: unit}
example : Tx .write (Array (Col "n" String)) := query typeql!"match $p isa person, has name $n;"
example : Tx .schema Unit := do
  exec typeql!"define entity person;"
  exec typeql!"insert $p isa person;"

/-- A read-mode helper runs inside a write transaction. -/
def readHelper : Tx .read Nat := pure 1
example : Tx .write Nat := do return (← readHelper) + 1

structure NotRenderable where
  x : Nat

-- @tg: verifies:: [[openspec:query#Explicit raw splicing#Unmarked unsupported type]] {level: unit}
/--
error: failed to synthesize instance of type class
  ToTypeQL NotRenderable

Hint: Type class instance resolution failures can be inspected with the `set_option trace.Meta.synthInstance true` command.
-/
#guard_msgs in
example (v : NotRenderable) : Query .read := typeql!"match $p has id {v};"

/-! The README's example, kept compiling. -/
namespace Readme

@[typedb "person"]
structure Person where
  email : Key String
  name : String
  age : Option Int64 := none
  deriving Entity

structure Friendship where
  a : Role "friend" (Ref Person)
  b : Role "friend" (Ref Person)
  deriving Relation

def main : IO Unit := do
  let r ← (Driver.withDriver { address := "127.0.0.1:1729" } fun d => do
    d.ensureDatabase "social"
    d.runSync "social" .schema (Schema.defineTx [TypeSpec.of Person, TypeSpec.of Friendship])
    d.runSync "social" .write do
      let ann ← Entity.insert { email := "ann@example.com", name := "Ann" : Person }
      let bob ← Entity.insert { email := "bob@example.com", name := "Bob", age := some 41 : Person }
      discard <| Relation.insert { a := ann, b := bob : Friendship }
    d.runSync "social" .read do
      for row in stream (α := Col "n" String) typeql!"match $p isa person, has name $n;" do
        IO.println row.val
    : EIO TypeDBError Unit).toBaseIO
  if let .error e := r then IO.eprintln e

end Readme
