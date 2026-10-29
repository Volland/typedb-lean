/*
 * C shim between Lean objects and the TypeDB C driver (ffi/typedb_driver.h).
 *
 * Every function that calls into the driver reads the driver's thread-local error
 * (check_error / get_last_error) immediately, on the same thread, and returns it to Lean as
 * an `EIO TypeDB.Native.NativeError` failure. Native handles are wrapped in Lean external
 * objects whose finalizers release whatever an explicit close has not.
 *
 * The constructors built here mirror Lean inductives in TypeDB/Native.lean and
 * TypeDB/Value.lean. Lean lays a constructor out as its object fields first, then its scalar
 * fields by decreasing size; the offsets below follow that rule and must change with them.
 */
#include <lean/lean.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "typedb_driver.h"

#define OBJ_OFF(nobjs) ((unsigned)(sizeof(void *) * (nobjs)))

/* ---------- errors ---------- */

/* TypeDB.Native.NativeError: structure { code : String, message : String } */
static lean_object *mk_native_error(const char *code, const char *message) {
  lean_object *e = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(e, 0, lean_mk_string(code ? code : ""));
  lean_ctor_set(e, 1, lean_mk_string(message ? message : ""));
  return e;
}

static lean_obj_res io_error(const char *code, const char *message) {
  return lean_io_result_mk_error(mk_native_error(code, message));
}

/* Takes the driver's pending error and turns it into an EIO failure. */
static lean_obj_res driver_error(void) {
  Error *e = get_last_error();
  if (!e) return io_error("TDBLEAN0", "the driver reported an error without details");
  char *code = error_code(e);
  char *msg = error_message(e);
  lean_obj_res r = io_error(code, msg);
  string_free(code);
  string_free(msg);
  error_drop(e);
  return r;
}

static lean_obj_res closed_error(const char *what) {
  char buf[128];
  snprintf(buf, sizeof buf, "the %s is closed", what);
  return io_error("TDBLEAN1", buf);
}

/* Moves a driver-allocated string into a Lean string. */
static lean_object *take_string(char *s) {
  lean_object *r = lean_mk_string(s ? s : "");
  if (s) string_free(s);
  return r;
}

/* ---------- background closer ---------- */

/* transaction_drop_sync waits until the driver has closed the transaction. The Rust driver's own
   drop closes without waiting; to match it, closes are queued for one background thread. Only
   operations that need every close to be done (deleting a database, closing the driver) wait
   for the queue to drain. */

typedef struct close_node {
  Transaction *txn;
  struct close_node *next;
} close_node;

static pthread_mutex_t g_close_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_close_cv = PTHREAD_COND_INITIALIZER;
static pthread_cond_t g_drained_cv = PTHREAD_COND_INITIALIZER;
static close_node *g_close_head, *g_close_tail;
static long g_close_pending;
static pthread_once_t g_closer_once = PTHREAD_ONCE_INIT;

static void *closer_main(void *arg) {
  (void)arg;
  for (;;) {
    pthread_mutex_lock(&g_close_mu);
    while (!g_close_head) pthread_cond_wait(&g_close_cv, &g_close_mu);
    close_node *n = g_close_head;
    g_close_head = n->next;
    if (!g_close_head) g_close_tail = NULL;
    pthread_mutex_unlock(&g_close_mu);
    transaction_drop_sync(n->txn);
    free(n);
    pthread_mutex_lock(&g_close_mu);
    if (--g_close_pending == 0) pthread_cond_broadcast(&g_drained_cv);
    pthread_mutex_unlock(&g_close_mu);
  }
  return NULL;
}

static void start_closer(void) {
  pthread_t t;
  pthread_create(&t, NULL, closer_main, NULL);
  pthread_detach(t);
}

static void close_async(Transaction *txn) {
  pthread_once(&g_closer_once, start_closer);
  close_node *n = malloc(sizeof *n);
  n->txn = txn;
  n->next = NULL;
  pthread_mutex_lock(&g_close_mu);
  if (g_close_tail) g_close_tail->next = n;
  else g_close_head = n;
  g_close_tail = n;
  g_close_pending++;
  pthread_cond_signal(&g_close_cv);
  pthread_mutex_unlock(&g_close_mu);
}

/* Waits until every queued close has finished. */
static void wait_closes(void) {
  pthread_mutex_lock(&g_close_mu);
  while (g_close_pending > 0) pthread_cond_wait(&g_drained_cv, &g_close_mu);
  pthread_mutex_unlock(&g_close_mu);
}

LEAN_EXPORT lean_obj_res tdb_wait_closes(lean_obj_arg w) {
  (void)w;
  wait_closes();
  return lean_io_result_mk_ok(lean_box(0));
}

/* ---------- external classes ---------- */

typedef struct { TypeDBDriver *driver; } driver_box;
typedef struct { Transaction *txn; QueryOptions *qopts; } tx_box;
typedef struct { ConceptRowIterator *it; } rows_box;
typedef struct { ConceptRow *row; } row_box;
typedef struct { StringIterator *it; } docs_box;

static lean_external_class *g_driver_class, *g_tx_class, *g_rows_class, *g_row_class, *g_docs_class;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void noop_foreach(void *p, b_lean_obj_arg f) { (void)p; (void)f; }

static void driver_finalize(void *p) {
  driver_box *b = p;
  if (b->driver) {
    wait_closes();
    driver_close(b->driver);
  }
  free(b);
}

static void tx_finalize(void *p) {
  tx_box *b = p;
  if (b->txn) close_async(b->txn);
  if (b->qopts) query_options_drop(b->qopts);
  free(b);
}

static void rows_finalize(void *p) {
  rows_box *b = p;
  if (b->it) concept_row_iterator_drop(b->it);
  free(b);
}

static void row_finalize(void *p) {
  row_box *b = p;
  if (b->row) concept_row_drop(b->row);
  free(b);
}

static void docs_finalize(void *p) {
  docs_box *b = p;
  if (b->it) string_iterator_drop(b->it);
  free(b);
}

// @tg: implements:: [[openspec:native-driver#Native resources are released]]
static void register_classes(void) {
  g_driver_class = lean_register_external_class(driver_finalize, noop_foreach);
  g_tx_class = lean_register_external_class(tx_finalize, noop_foreach);
  g_rows_class = lean_register_external_class(rows_finalize, noop_foreach);
  g_row_class = lean_register_external_class(row_finalize, noop_foreach);
  g_docs_class = lean_register_external_class(docs_finalize, noop_foreach);
}

static void ensure_classes(void) { pthread_once(&g_once, register_classes); }

static lean_object *box_external(lean_external_class **cls, void *data) {
  ensure_classes();
  return lean_alloc_external(*cls, data);
}

#define UNBOX(type, o) ((type *)lean_get_external_data(o))

/* ---------- values and concepts ---------- */

/* TypeDB.Value constructors, in declaration order. */
enum { V_BOOL, V_INTEGER, V_DOUBLE, V_DECIMAL, V_STRING, V_DATE, V_DATETIME, V_DATETIME_TZ, V_DURATION };

/* TypeDB.Native.RawConcept constructors, in declaration order. */
enum { C_ENTITY, C_RELATION, C_ATTRIBUTE, C_VALUE, C_ENTITY_TYPE, C_RELATION_TYPE, C_ATTRIBUTE_TYPE, C_ROLE_TYPE };

/* Column flags from TypeDB.Decode.Plan: which parts of a concept the decoder reads. */
#define WANT_LABEL 1
#define WANT_IID 2

/* Reads the value of an attribute or value concept. Returns NULL with the driver error set
   for a value type this library does not support (structs). */
static lean_object *mk_value(const Concept *c) {
  lean_object *o;
  if (concept_is_boolean(c)) {
    o = lean_alloc_ctor(V_BOOL, 0, 1);
    lean_ctor_set_uint8(o, OBJ_OFF(0), concept_get_boolean(c));
  } else if (concept_is_integer(c)) {
    o = lean_alloc_ctor(V_INTEGER, 0, 8);
    lean_ctor_set_uint64(o, OBJ_OFF(0), (uint64_t)concept_get_integer(c));
  } else if (concept_is_double(c)) {
    o = lean_alloc_ctor(V_DOUBLE, 0, 8);
    lean_ctor_set_float(o, OBJ_OFF(0), concept_get_double(c));
  } else if (concept_is_decimal(c)) {
    Decimal d = concept_get_decimal(c);
    o = lean_alloc_ctor(V_DECIMAL, 0, 16);
    lean_ctor_set_uint64(o, OBJ_OFF(0), (uint64_t)d.integer);
    lean_ctor_set_uint64(o, OBJ_OFF(0) + 8, d.fractional);
  } else if (concept_is_string(c)) {
    o = lean_alloc_ctor(V_STRING, 1, 0);
    lean_ctor_set(o, 0, take_string(concept_get_string(c)));
  } else if (concept_is_date(c)) {
    o = lean_alloc_ctor(V_DATE, 0, 8);
    lean_ctor_set_uint64(o, OBJ_OFF(0), (uint64_t)concept_get_date_as_seconds(c));
  } else if (concept_is_datetime(c)) {
    DatetimeInNanos dt = concept_get_datetime(c);
    o = lean_alloc_ctor(V_DATETIME, 0, 12);
    lean_ctor_set_uint64(o, OBJ_OFF(0), (uint64_t)dt.seconds);
    lean_ctor_set_uint32(o, OBJ_OFF(0) + 8, dt.subsec_nanos);
  } else if (concept_is_datetime_tz(c)) {
    DatetimeAndTimeZone *tz = concept_get_datetime_tz(c);
    if (!tz) return NULL;
    /* datetimeTz (seconds : Int64) (nanos : UInt32) (zone : String) (offset : Int32) (fixed : Bool) */
    o = lean_alloc_ctor(V_DATETIME_TZ, 1, 17);
    lean_ctor_set(o, 0, lean_mk_string(tz->zone_name ? tz->zone_name : ""));
    lean_ctor_set_uint64(o, OBJ_OFF(1), (uint64_t)tz->datetime_in_nanos.seconds);
    lean_ctor_set_uint32(o, OBJ_OFF(1) + 8, tz->datetime_in_nanos.subsec_nanos);
    lean_ctor_set_uint32(o, OBJ_OFF(1) + 12, (uint32_t)tz->local_minus_utc_offset);
    lean_ctor_set_uint8(o, OBJ_OFF(1) + 16, tz->is_fixed_offset);
    datetime_and_time_zone_drop(tz);
  } else if (concept_is_duration(c)) {
    Duration d = concept_get_duration(c);
    /* duration (months : UInt32) (days : UInt32) (nanos : UInt64) */
    o = lean_alloc_ctor(V_DURATION, 0, 16);
    lean_ctor_set_uint64(o, OBJ_OFF(0), d.nanos);
    lean_ctor_set_uint32(o, OBJ_OFF(0) + 8, d.months);
    lean_ctor_set_uint32(o, OBJ_OFF(0) + 12, d.days);
  } else {
    o = lean_alloc_ctor(V_STRING, 1, 0);
    lean_ctor_set(o, 0, take_string(concept_to_string(c)));
  }
  return o;
}

static lean_object *mk_label_ctor(unsigned tag, const Concept *c) {
  lean_object *o = lean_alloc_ctor(tag, 1, 0);
  lean_ctor_set(o, 0, take_string(concept_get_label(c)));
  return o;
}

/* Converts one concept to a TypeDB.Native.RawConcept, reading only the parts in `flags`. */
static lean_object *mk_concept(Concept *c, uint8_t flags) {
  if (concept_is_entity(c) || concept_is_relation(c)) {
    lean_object *o = lean_alloc_ctor(concept_is_entity(c) ? C_ENTITY : C_RELATION, 2, 0);
    lean_ctor_set(o, 0, (flags & WANT_IID) ? take_string(concept_try_get_iid(c)) : lean_mk_string(""));
    lean_ctor_set(o, 1, (flags & WANT_LABEL) ? take_string(concept_try_get_label(c)) : lean_mk_string(""));
    return o;
  }
  if (concept_is_attribute(c)) {
    lean_object *v = mk_value(c);
    if (!v) return NULL;
    if (!(flags & WANT_LABEL)) {
      lean_object *o = lean_alloc_ctor(C_VALUE, 1, 0);
      lean_ctor_set(o, 0, v);
      return o;
    }
    lean_object *o = lean_alloc_ctor(C_ATTRIBUTE, 2, 0);
    lean_ctor_set(o, 0, take_string(concept_try_get_label(c)));
    lean_ctor_set(o, 1, v);
    return o;
  }
  if (concept_is_value(c)) {
    lean_object *v = mk_value(c);
    if (!v) return NULL;
    lean_object *o = lean_alloc_ctor(C_VALUE, 1, 0);
    lean_ctor_set(o, 0, v);
    return o;
  }
  if (concept_is_entity_type(c)) return mk_label_ctor(C_ENTITY_TYPE, c);
  if (concept_is_relation_type(c)) return mk_label_ctor(C_RELATION_TYPE, c);
  if (concept_is_attribute_type(c)) return mk_label_ctor(C_ATTRIBUTE_TYPE, c);
  return mk_label_ctor(C_ROLE_TYPE, c);
}

static lean_object *mk_some(lean_object *x) {
  lean_object *o = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(o, 0, x);
  return o;
}

/* ---------- driver ---------- */

LEAN_EXPORT lean_obj_res tdb_driver_open(b_lean_obj_arg addr, b_lean_obj_arg user, b_lean_obj_arg pass,
                                         uint8_t tls, b_lean_obj_arg root_ca, int64_t timeout_ms,
                                         lean_obj_arg w) {
  (void)w;
  DriverTlsConfig *tls_cfg;
  if (!tls) tls_cfg = driver_tls_config_new_disabled();
  else if (lean_string_size(root_ca) <= 1) tls_cfg = driver_tls_config_new_enabled_with_native_root_ca();
  else tls_cfg = driver_tls_config_new_enabled_with_root_ca_path(lean_string_cstr(root_ca));
  if (!tls_cfg) return driver_error();
  DriverOptions *opts = driver_options_new(tls_cfg);
  driver_tls_config_drop(tls_cfg);
  if (!opts) return driver_error();
  if (timeout_ms > 0) driver_options_set_request_timeout_millis(opts, timeout_ms);
  Credentials *cred = credentials_new(lean_string_cstr(user), lean_string_cstr(pass));
  TypeDBDriver *d = driver_new(lean_string_cstr(addr), cred, opts, "typedb-lean");
  credentials_drop(cred);
  driver_options_drop(opts);
  if (!d) return driver_error();
  driver_box *b = malloc(sizeof *b);
  b->driver = d;
  return lean_io_result_mk_ok(box_external(&g_driver_class, b));
}

LEAN_EXPORT lean_obj_res tdb_driver_close(b_lean_obj_arg dobj, lean_obj_arg w) {
  (void)w;
  driver_box *b = UNBOX(driver_box, dobj);
  if (b->driver) {
    wait_closes();
    driver_close(b->driver);
    b->driver = NULL;
  }
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res tdb_driver_is_open(b_lean_obj_arg dobj, lean_obj_arg w) {
  (void)w;
  driver_box *b = UNBOX(driver_box, dobj);
  return lean_io_result_mk_ok(lean_box(b->driver && driver_is_open(b->driver)));
}

#define WITH_DRIVER(dobj, d)                          \
  TypeDBDriver *d = UNBOX(driver_box, dobj)->driver; \
  if (!d) return closed_error("driver")

LEAN_EXPORT lean_obj_res tdb_db_create(b_lean_obj_arg dobj, b_lean_obj_arg name, lean_obj_arg w) {
  (void)w;
  WITH_DRIVER(dobj, d);
  databases_create(d, lean_string_cstr(name));
  if (check_error()) return driver_error();
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res tdb_db_contains(b_lean_obj_arg dobj, b_lean_obj_arg name, lean_obj_arg w) {
  (void)w;
  WITH_DRIVER(dobj, d);
  bool r = databases_contains(d, lean_string_cstr(name));
  if (check_error()) return driver_error();
  return lean_io_result_mk_ok(lean_box(r));
}

LEAN_EXPORT lean_obj_res tdb_db_delete(b_lean_obj_arg dobj, b_lean_obj_arg name, lean_obj_arg w) {
  (void)w;
  WITH_DRIVER(dobj, d);
  wait_closes();
  const Database *db = databases_get(d, lean_string_cstr(name));
  if (!db) return driver_error();
  database_delete(db);
  if (check_error()) return driver_error();
  return lean_io_result_mk_ok(lean_box(0));
}

/* kind 0 = full schema, 1 = type schema only */
LEAN_EXPORT lean_obj_res tdb_db_schema(b_lean_obj_arg dobj, b_lean_obj_arg name, uint8_t kind, lean_obj_arg w) {
  (void)w;
  WITH_DRIVER(dobj, d);
  const Database *db = databases_get(d, lean_string_cstr(name));
  if (!db) return driver_error();
  char *s = kind == 0 ? database_schema(db) : database_type_schema(db);
  database_close(db);
  if (!s) return driver_error();
  return lean_io_result_mk_ok(take_string(s));
}

LEAN_EXPORT lean_obj_res tdb_db_all(b_lean_obj_arg dobj, lean_obj_arg w) {
  (void)w;
  WITH_DRIVER(dobj, d);
  DatabaseIterator *it = databases_all(d);
  if (!it) return driver_error();
  lean_object *arr = lean_mk_empty_array();
  const Database *db;
  while ((db = database_iterator_next(it))) {
    arr = lean_array_push(arr, take_string(database_get_name(db)));
    database_close(db);
  }
  database_iterator_drop(it);
  if (check_error()) {
    lean_dec(arr);
    return driver_error();
  }
  return lean_io_result_mk_ok(arr);
}

/* ---------- transactions ---------- */

LEAN_EXPORT lean_obj_res tdb_tx_open(b_lean_obj_arg dobj, b_lean_obj_arg db, uint8_t type, int64_t timeout_ms,
                                     int64_t prefetch, lean_obj_arg w) {
  (void)w;
  WITH_DRIVER(dobj, d);
  TransactionOptions *topts = transaction_options_new();
  if (timeout_ms > 0) transaction_options_set_transaction_timeout_millis(topts, timeout_ms);
  Transaction *txn = transaction_new(d, lean_string_cstr(db), (TransactionType)type, topts);
  transaction_options_drop(topts);
  if (!txn) return driver_error();
  QueryOptions *qopts = query_options_new();
  query_options_set_include_instance_types(qopts, true);
  if (prefetch > 0) query_options_set_prefetch_size(qopts, prefetch);
  tx_box *b = malloc(sizeof *b);
  b->txn = txn;
  b->qopts = qopts;
  return lean_io_result_mk_ok(box_external(&g_tx_class, b));
}

/* Commits and frees the transaction; the handle is unusable afterwards, whatever the outcome. */
LEAN_EXPORT lean_obj_res tdb_tx_commit(b_lean_obj_arg tobj, lean_obj_arg w) {
  (void)w;
  tx_box *b = UNBOX(tx_box, tobj);
  if (!b->txn) return closed_error("transaction");
  VoidPromise *p = transaction_commit(b->txn);
  b->txn = NULL;
  if (!p) return driver_error();
  void_promise_resolve(p);
  if (check_error()) return driver_error();
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res tdb_tx_rollback(b_lean_obj_arg tobj, lean_obj_arg w) {
  (void)w;
  tx_box *b = UNBOX(tx_box, tobj);
  if (!b->txn) return closed_error("transaction");
  VoidPromise *p = transaction_rollback(b->txn);
  if (!p) return driver_error();
  void_promise_resolve(p);
  if (check_error()) return driver_error();
  return lean_io_result_mk_ok(lean_box(0));
}

/* Closes (discarding uncommitted writes) and frees the transaction, without waiting for the
   driver to finish closing it. Idempotent. */
LEAN_EXPORT lean_obj_res tdb_tx_close(b_lean_obj_arg tobj, lean_obj_arg w) {
  (void)w;
  tx_box *b = UNBOX(tx_box, tobj);
  if (b->txn) {
    close_async(b->txn);
    b->txn = NULL;
  }
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res tdb_tx_is_open(b_lean_obj_arg tobj, lean_obj_arg w) {
  (void)w;
  tx_box *b = UNBOX(tx_box, tobj);
  return lean_io_result_mk_ok(lean_box(b->txn && transaction_is_open(b->txn)));
}

/* TypeDB.Native.RawAnswer constructors. */
enum { A_OK, A_ROWS, A_DOCS };

LEAN_EXPORT lean_obj_res tdb_tx_query(b_lean_obj_arg tobj, b_lean_obj_arg query, lean_obj_arg w) {
  (void)w;
  tx_box *b = UNBOX(tx_box, tobj);
  if (!b->txn) return closed_error("transaction");
  QueryAnswerPromise *p = transaction_query(b->txn, lean_string_cstr(query), b->qopts);
  if (!p) return driver_error();
  QueryAnswer *a = query_answer_promise_resolve(p);
  if (!a) return driver_error();
  if (query_answer_is_ok(a)) {
    query_answer_drop(a);
    return lean_io_result_mk_ok(lean_box(A_OK));
  }
  lean_object *o;
  if (query_answer_is_concept_row_stream(a)) {
    rows_box *rb = malloc(sizeof *rb);
    rb->it = query_answer_into_rows(a);
    o = lean_alloc_ctor(A_ROWS, 1, 0);
    lean_ctor_set(o, 0, box_external(&g_rows_class, rb));
  } else {
    docs_box *db = malloc(sizeof *db);
    db->it = query_answer_into_documents(a);
    o = lean_alloc_ctor(A_DOCS, 1, 0);
    lean_ctor_set(o, 0, box_external(&g_docs_class, db));
  }
  return lean_io_result_mk_ok(o);
}

/* ---------- rows: thin path ---------- */

LEAN_EXPORT lean_obj_res tdb_rows_next(b_lean_obj_arg iobj, lean_obj_arg w) {
  (void)w;
  rows_box *b = UNBOX(rows_box, iobj);
  if (!b->it) return lean_io_result_mk_ok(lean_box(0));
  ConceptRow *row = concept_row_iterator_next(b->it);
  if (!row) {
    if (check_error()) return driver_error();
    concept_row_iterator_drop(b->it);
    b->it = NULL;
    return lean_io_result_mk_ok(lean_box(0));
  }
  row_box *rb = malloc(sizeof *rb);
  rb->row = row;
  return lean_io_result_mk_ok(mk_some(box_external(&g_row_class, rb)));
}

LEAN_EXPORT lean_obj_res tdb_rows_close(b_lean_obj_arg iobj, lean_obj_arg w) {
  (void)w;
  rows_box *b = UNBOX(rows_box, iobj);
  if (b->it) {
    concept_row_iterator_drop(b->it);
    b->it = NULL;
  }
  return lean_io_result_mk_ok(lean_box(0));
}

static lean_object *string_iterator_to_array(StringIterator *it) {
  lean_object *arr = lean_mk_empty_array();
  char *s;
  while ((s = string_iterator_next(it))) arr = lean_array_push(arr, take_string(s));
  string_iterator_drop(it);
  return arr;
}

LEAN_EXPORT lean_obj_res tdb_row_columns(b_lean_obj_arg robj, lean_obj_arg w) {
  (void)w;
  ConceptRow *row = UNBOX(row_box, robj)->row;
  StringIterator *it = concept_row_get_column_names(row);
  if (!it) return driver_error();
  return lean_io_result_mk_ok(string_iterator_to_array(it));
}

LEAN_EXPORT lean_obj_res tdb_row_get(b_lean_obj_arg robj, b_lean_obj_arg col, uint8_t flags, lean_obj_arg w) {
  (void)w;
  ConceptRow *row = UNBOX(row_box, robj)->row;
  Concept *c = concept_row_get(row, lean_string_cstr(col));
  if (!c) {
    if (check_error()) return driver_error();
    return lean_io_result_mk_ok(lean_box(0));
  }
  lean_object *o = mk_concept(c, flags);
  concept_drop(c);
  if (!o) return driver_error();
  return lean_io_result_mk_ok(mk_some(o));
}

/* ---------- rows: batched hot path ---------- */

/* Resolves the plan's column names to indices in the answer's header. */
static int resolve_columns(ConceptRow *row, b_lean_obj_arg cols, size_t *idx, lean_object **err) {
  StringIterator *it = concept_row_get_column_names(row);
  if (!it) {
    *err = driver_error();
    return 0;
  }
  lean_object *names = string_iterator_to_array(it);
  size_t n = lean_array_size(names), ncols = lean_array_size(cols);
  for (size_t j = 0; j < ncols; j++) {
    const char *want = lean_string_cstr(lean_array_get_core(cols, j));
    size_t k = 0;
    while (k < n && strcmp(lean_string_cstr(lean_array_get_core(names, k)), want) != 0) k++;
    if (k == n) {
      lean_dec(names);
      *err = io_error("TDBLEAN2", want);
      return 0;
    }
    idx[j] = k;
  }
  lean_dec(names);
  return 1;
}

/* Pulls up to `k` rows and returns, for each, the concepts of the plan's columns
   (Array (Array (Option RawConcept))), in one call. An empty result means the stream is done. */
LEAN_EXPORT lean_obj_res tdb_rows_next_batch(b_lean_obj_arg iobj, b_lean_obj_arg cols, b_lean_obj_arg flags,
                                             size_t k, lean_obj_arg w) {
  (void)w;
  rows_box *b = UNBOX(rows_box, iobj);
  lean_object *out = lean_alloc_array(0, k);
  if (!b->it) return lean_io_result_mk_ok(out);
  size_t ncols = lean_array_size(cols);
  const uint8_t *fl = lean_sarray_cptr(flags);
  size_t nflags = lean_sarray_size(flags);
  size_t stack_idx[32];
  size_t *idx = ncols <= 32 ? stack_idx : malloc(sizeof(size_t) * ncols);
  int resolved = 0;
  lean_object *err = NULL;
  for (size_t i = 0; i < k; i++) {
    ConceptRow *row = concept_row_iterator_next(b->it);
    if (!row) {
      if (check_error()) {
        err = driver_error();
        break;
      }
      concept_row_iterator_drop(b->it);
      b->it = NULL;
      break;
    }
    if (!resolved) {
      if (!resolve_columns(row, cols, idx, &err)) {
        concept_row_drop(row);
        break;
      }
      resolved = 1;
    }
    lean_object *r = lean_alloc_array(ncols, ncols);
    lean_object **slots = lean_array_cptr(r);
    for (size_t j = 0; j < ncols; j++) slots[j] = lean_box(0);
    for (size_t j = 0; j < ncols && !err; j++) {
      Concept *c = concept_row_get_index(row, idx[j]);
      if (!c) {
        if (check_error()) err = driver_error();
        continue;
      }
      lean_object *o = mk_concept(c, j < nflags ? fl[j] : (WANT_LABEL | WANT_IID));
      concept_drop(c);
      if (!o) {
        err = driver_error();
        break;
      }
      slots[j] = mk_some(o);
    }
    concept_row_drop(row);
    if (err) {
      lean_dec(r);
      break;
    }
    out = lean_array_push(out, r);
  }
  if (idx != stack_idx) free(idx);
  if (err) {
    lean_dec(out);
    return err;
  }
  return lean_io_result_mk_ok(out);
}

/* ---------- documents ---------- */

LEAN_EXPORT lean_obj_res tdb_docs_next(b_lean_obj_arg iobj, lean_obj_arg w) {
  (void)w;
  docs_box *b = UNBOX(docs_box, iobj);
  if (!b->it) return lean_io_result_mk_ok(lean_box(0));
  char *s = string_iterator_next(b->it);
  if (!s) {
    if (check_error()) return driver_error();
    string_iterator_drop(b->it);
    b->it = NULL;
    return lean_io_result_mk_ok(lean_box(0));
  }
  return lean_io_result_mk_ok(mk_some(take_string(s)));
}

LEAN_EXPORT lean_obj_res tdb_docs_close(b_lean_obj_arg iobj, lean_obj_arg w) {
  (void)w;
  docs_box *b = UNBOX(docs_box, iobj);
  if (b->it) {
    string_iterator_drop(b->it);
    b->it = NULL;
  }
  return lean_io_result_mk_ok(lean_box(0));
}
