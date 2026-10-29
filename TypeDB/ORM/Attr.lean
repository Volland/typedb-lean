import Lean

/-!
# ORM attributes

`@[typedb "label"]` on a structure sets its TypeDB type label (default: the kebab-case of the
type's name). Field-level settings are type markers (`Key`, `Role`, `Label` in `TypeDB.ORM`),
because Lean does not accept attributes on structure fields.
-/

namespace TypeDB.ORM
open Lean

syntax (name := typedb) "typedb " str : attr

initialize typedbLabelAttr : ParametricAttribute String ←
  registerParametricAttribute {
    name := `typedb
    descr := "TypeDB type label of a mapped structure"
    getParam := fun _ stx => match stx with
      | `(attr| typedb $s:str) => pure s.getString
      | _ => throwError "expected `@[typedb \"label\"]`"
  }

end TypeDB.ORM
