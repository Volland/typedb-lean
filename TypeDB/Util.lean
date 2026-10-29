/-!
# String helpers

Small string operations used across the library, written over `List Char` so they do not depend
on the `String`/`String.Slice` API, which changes between Lean releases.
-/

namespace TypeDB.Str

def dropRight (s : String) (n : Nat) : String := String.ofList (s.toList.take (s.length - n))
def takeRight (s : String) (n : Nat) : String := String.ofList (s.toList.drop (s.length - n))
def dropLeft (s : String) (n : Nat) : String := String.ofList (s.toList.drop n)
def dropRightWhile (s : String) (p : Char → Bool) : String :=
  String.ofList (s.toList.reverse.dropWhile p).reverse
def dropLeftWhile (s : String) (p : Char → Bool) : String := String.ofList (s.toList.dropWhile p)
def trim (s : String) : String := dropRightWhile (dropLeftWhile s Char.isWhitespace) Char.isWhitespace
def padLeft (s : String) (width : Nat) (c : Char) : String := "".pushn c (width - s.length) ++ s

/-- Whether `sub` occurs in `s`. -/
def contains (s sub : String) : Bool := (s.splitOn sub).length > 1

/-- `kebab-case` of a `CamelCase` identifier: `FriendRequest` ↦ `friend-request`. -/
def kebab (s : String) : String := Id.run do
  let mut out := ""
  let mut prevLower := false
  for c in s.toList do
    if c.isUpper then
      if prevLower then out := out.push '-'
      out := out.push c.toLower
      prevLower := false
    else
      out := out.push (if c == '_' then '-' else c)
      prevLower := c.isLower || c.isDigit
  return out

end TypeDB.Str
