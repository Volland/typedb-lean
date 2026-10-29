import TypeDB.Value

/-!
# Native bindings

Thin `@[extern]` declarations over `ffi/typedb_lean.c`. Every function returns the driver's
error as a `NativeError` in the same call, because the driver keeps its last error in
thread-local state. Handles are external objects: dropping the last reference releases them,
and the explicit `close` functions release them early.

This module is internal; `TypeDB.Driver`, `TypeDB.Tx` and `TypeDB.Query` wrap it.
-/

namespace TypeDB.Native

/-- An error reported by the driver: its code (`CXN05`, `TQL03`, …) and message. Codes starting
with `TDBLEAN` come from the shim itself. -/
structure NativeError where
  code : String
  message : String
  deriving Repr, Inhabited

opaque DriverPointed : NonemptyType
/-- An open driver connection. -/
def DriverHandle := DriverPointed.type
instance : Nonempty DriverHandle := DriverPointed.property

opaque TxPointed : NonemptyType
/-- An open transaction, with the query options it runs queries with. -/
def TxHandle := TxPointed.type
instance : Nonempty TxHandle := TxPointed.property

opaque RowsPointed : NonemptyType
/-- A stream of concept rows; valid only while its transaction is open. -/
def RowsHandle := RowsPointed.type
instance : Nonempty RowsHandle := RowsPointed.property

opaque RowPointed : NonemptyType
def RowHandle := RowPointed.type
instance : Nonempty RowHandle := RowPointed.property

opaque DocsPointed : NonemptyType
/-- A stream of JSON documents from a `fetch`; valid only while its transaction is open. -/
def DocsHandle := DocsPointed.type
instance : Nonempty DocsHandle := DocsPointed.property

/-- What a query answered. Constructor order is mirrored by the shim. -/
inductive RawAnswer where
  | ok
  | rows (it : RowsHandle)
  | docs (it : DocsHandle)

instance : Nonempty RawAnswer := ⟨.ok⟩

abbrev NIO := EIO NativeError

/-- Opens a connection. An empty `rootCA` with `tls` uses the system's root certificates. A
`timeoutMs` of 0 keeps the driver's default request timeout. -/
@[extern "tdb_driver_open"]
opaque driverOpen (address user password : @& String) (tls : Bool) (rootCA : @& String)
  (timeoutMs : Int64) : NIO DriverHandle

@[extern "tdb_driver_close"] opaque driverClose (d : @& DriverHandle) : NIO Unit
@[extern "tdb_driver_is_open"] opaque driverIsOpen (d : @& DriverHandle) : NIO Bool

@[extern "tdb_db_create"] opaque dbCreate (d : @& DriverHandle) (name : @& String) : NIO Unit
@[extern "tdb_db_contains"] opaque dbContains (d : @& DriverHandle) (name : @& String) : NIO Bool
@[extern "tdb_db_delete"] opaque dbDelete (d : @& DriverHandle) (name : @& String) : NIO Unit
/-- `kind` 0 is the full schema, 1 the type schema only. -/
@[extern "tdb_db_schema"] opaque dbSchema (d : @& DriverHandle) (name : @& String) (kind : UInt8) : NIO String
@[extern "tdb_db_all"] opaque dbAll (d : @& DriverHandle) : NIO (Array String)

/-- `type` is 0 read, 1 write, 2 schema; a `timeoutMs` or `prefetch` of 0 keeps the default. -/
@[extern "tdb_tx_open"]
opaque txOpen (d : @& DriverHandle) (db : @& String) (type : UInt8) (timeoutMs prefetch : Int64) : NIO TxHandle

/-- Commits and releases the transaction, whatever the outcome. -/
@[extern "tdb_tx_commit"] opaque txCommit (t : @& TxHandle) : NIO Unit
@[extern "tdb_tx_rollback"] opaque txRollback (t : @& TxHandle) : NIO Unit
/-- Closes the transaction without committing and releases it, without waiting for the driver to
finish closing it (like the Rust driver's `drop`). Idempotent. -/
@[extern "tdb_tx_close"] opaque txClose (t : @& TxHandle) : NIO Unit
/-- Waits until every transaction closed so far has finished closing. -/
@[extern "tdb_wait_closes"] opaque waitCloses : NIO Unit
@[extern "tdb_tx_is_open"] opaque txIsOpen (t : @& TxHandle) : NIO Bool
@[extern "tdb_tx_query"] opaque txQuery (t : @& TxHandle) (query : @& String) : NIO RawAnswer

@[extern "tdb_rows_next"] opaque rowsNext (it : @& RowsHandle) : NIO (Option RowHandle)
@[extern "tdb_rows_close"] opaque rowsClose (it : @& RowsHandle) : NIO Unit
@[extern "tdb_row_columns"] opaque rowColumns (r : @& RowHandle) : NIO (Array String)
/-- The concept in column `col`, or `none` if the row leaves it empty. -/
@[extern "tdb_row_get"] opaque rowGet (r : @& RowHandle) (col : @& String) (flags : UInt8) : NIO (Option Concept)

/-- Pulls up to `k` rows and returns the concepts of `cols` in each, in one native call. A result
shorter than `k` means the stream is exhausted (and already released). -/
-- @tg: implements:: [[openspec:decoding#Batched row decoding]]
@[extern "tdb_rows_next_batch"]
opaque rowsNextBatch (it : @& RowsHandle) (cols : @& Array String) (flags : @& ByteArray) (k : USize) :
  NIO (Array (Array (Option Concept)))

@[extern "tdb_docs_next"] opaque docsNext (it : @& DocsHandle) : NIO (Option String)
@[extern "tdb_docs_close"] opaque docsClose (it : @& DocsHandle) : NIO Unit

/-- Column flags: read the concept's type label. -/
def wantLabel : UInt8 := 1
/-- Column flags: read the instance's IID. -/
def wantIID : UInt8 := 2

end TypeDB.Native
