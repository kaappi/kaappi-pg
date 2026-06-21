#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <libpq-fe.h>

/* -----------------------------------------------------------------------
   Query state — set-then-execute pattern for multi-arg calls that don't
   match Kaappi's FFI dispatch table.  Single-threaded, so global state
   is safe.
   ----------------------------------------------------------------------- */

#define MAX_PARAMS 64

static char  stored_sql[16384];
static int   param_count = 0;
static char *param_values[MAX_PARAMS];

/* -----------------------------------------------------------------------
   Connection
   ----------------------------------------------------------------------- */

/* (string) -> pointer */
void *kpg_connect(const char *conninfo) {
    PGconn *conn = PQconnectdb(conninfo);
    return (void *)conn;
}

/* (pointer) -> int   — CONNECTION_OK = 0, CONNECTION_BAD = 1 */
int kpg_status(void *conn) {
    return (int)PQstatus((PGconn *)conn);
}

/* (pointer) -> void */
void kpg_finish(void *conn) {
    PQfinish((PGconn *)conn);
}

/* (pointer) -> string */
const char *kpg_error_message(void *conn) {
    return PQerrorMessage((PGconn *)conn);
}

/* -----------------------------------------------------------------------
   Query setup
   ----------------------------------------------------------------------- */

/* (string) -> void */
void kpg_set_sql(const char *sql) {
    strncpy(stored_sql, sql, sizeof(stored_sql) - 1);
    stored_sql[sizeof(stored_sql) - 1] = '\0';
}

/* () -> void */
void kpg_clear_params(void) {
    for (int i = 0; i < param_count; i++) {
        free(param_values[i]);
        param_values[i] = NULL;
    }
    param_count = 0;
}

/* (string) -> void */
void kpg_add_param(const char *value) {
    if (param_count >= MAX_PARAMS) return;
    param_values[param_count] = strdup(value);
    param_count++;
}

/* () -> int   (returns 0, signature needs a return for FFI match) */
int kpg_add_null_param(void) {
    if (param_count >= MAX_PARAMS) return -1;
    param_values[param_count] = NULL;
    param_count++;
    return 0;
}

/* -----------------------------------------------------------------------
   Query execution
   ----------------------------------------------------------------------- */

/* (pointer) -> pointer — simple exec (no params) */
void *kpg_exec(void *conn) {
    return (void *)PQexec((PGconn *)conn, stored_sql);
}

/* (pointer) -> pointer — parameterised exec */
void *kpg_exec_params(void *conn) {
    PGresult *res = PQexecParams(
        (PGconn *)conn,
        stored_sql,
        param_count,
        NULL,                           /* paramTypes — let server infer */
        (const char *const *)param_values,
        NULL,                           /* paramLengths — text format */
        NULL,                           /* paramFormats — all text */
        0                               /* resultFormat — text */
    );
    kpg_clear_params();
    return (void *)res;
}

/* -----------------------------------------------------------------------
   Result status
   ----------------------------------------------------------------------- */

/* (pointer) -> int */
int kpg_result_status(void *res) {
    return (int)PQresultStatus((PGresult *)res);
}

/* (pointer) -> int */
int kpg_ntuples(void *res) {
    return PQntuples((PGresult *)res);
}

/* (pointer) -> int */
int kpg_nfields(void *res) {
    return PQnfields((PGresult *)res);
}

/* (pointer) -> void */
void kpg_clear(void *res) {
    PQclear((PGresult *)res);
}

/* (pointer) -> string */
const char *kpg_result_error(void *res) {
    return PQresultErrorMessage((PGresult *)res);
}

/* (pointer) -> string */
const char *kpg_cmd_tuples(void *res) {
    return PQcmdTuples((PGresult *)res);
}

/* -----------------------------------------------------------------------
   Field metadata — col passed as pointer (fixnum trick)
   ----------------------------------------------------------------------- */

/* (pointer, pointer) -> pointer   — returns char* for fname */
void *kpg_fname(void *res, void *col_ptr) {
    int col = (int)(intptr_t)col_ptr;
    return (void *)PQfname((PGresult *)res, col);
}

/* (pointer, pointer) -> int   — returns OID as int */
int kpg_ftype(void *res, void *col_ptr) {
    int col = (int)(intptr_t)col_ptr;
    return (int)PQftype((PGresult *)res, col);
}

/* -----------------------------------------------------------------------
   Cell access — row passed as pointer (fixnum trick)
   ----------------------------------------------------------------------- */

/* (pointer, pointer, long) -> pointer   — returns char* */
void *kpg_getvalue(void *res, void *row_ptr, long col) {
    int row = (int)(intptr_t)row_ptr;
    return (void *)PQgetvalue((PGresult *)res, row, (int)col);
}

/* (pointer, pointer, long) -> int */
int kpg_getisnull(void *res, void *row_ptr, long col) {
    int row = (int)(intptr_t)row_ptr;
    return PQgetisnull((PGresult *)res, row, (int)col);
}

/* -----------------------------------------------------------------------
   Utility
   ----------------------------------------------------------------------- */

/* (pointer) -> string   — reinterpret any char* pointer as string */
const char *kpg_ptr_to_str(void *ptr) {
    return (const char *)ptr;
}

/* (pointer) -> void   — free PQescapeLiteral result */
void kpg_free_ptr(void *ptr) {
    PQfreemem(ptr);
}

/* (pointer, pointer) -> pointer
   Escape a string literal.  The string is passed as a bytevector pointer.
   Returns malloc'd string including quotes; free with kpg_free_ptr. */
void *kpg_escape_literal(void *conn, void *str_ptr) {
    const char *str = (const char *)str_ptr;
    size_t len = strlen(str);
    return (void *)PQescapeLiteral((PGconn *)conn, str, len);
}
