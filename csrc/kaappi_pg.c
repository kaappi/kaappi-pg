#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <poll.h>
#include <libpq-fe.h>

/* -----------------------------------------------------------------------
   Connection state — one KpgConn per PGconn, holding the "set-then-send"
   query buffer that used to be process-global. It must live per-connection
   now: PQsendQuery/PQsendQueryParams don't block, so a fiber can suspend
   mid-query (waiting on socket readiness) and hand the OS thread to a
   sibling fiber that runs a query on a different connection. A single
   shared buffer would let that sibling clobber the SQL/params still
   in flight on this one.

   Every function taking a KpgConn* guards against NULL: the Scheme layer
   zeroes its handle on pg-close, so a use-after-close hands NULL in here.
   The wrapper raises before calling us, but a caller going through
   (kaappi pg ffi) directly gets a soft failure code instead of a segfault.
   ----------------------------------------------------------------------- */

#define MAX_PARAMS 64

typedef struct {
    PGconn *conn;
    char    sql[16384];
    int     param_count;
    char   *param_values[MAX_PARAMS];
} KpgConn;

/* -----------------------------------------------------------------------
   Connection — async (PQconnectStart/PQconnectPoll), so the handshake
   never blocks the OS thread. lib/kaappi/pg.sld drives kpg_connect_poll
   in a loop, waiting on kpg_socket's readiness between calls exactly like
   kaappi-net's TLS handshake (KEP-0001 Phase 6).
   ----------------------------------------------------------------------- */

/* (string) -> pointer */
void *kpg_connect_start(const char *conninfo) {
    PGconn *conn = PQconnectStart(conninfo);
    if (!conn) return NULL;
    KpgConn *kc = calloc(1, sizeof(KpgConn));
    if (!kc) { PQfinish(conn); return NULL; }
    kc->conn = conn;
    return kc;
}

/* (pointer) -> int — PostgresPollingStatusType: FAILED=0 READING=1
   WRITING=2 OK=3 ACTIVE=4(deprecated) */
int kpg_connect_poll(void *kconn) {
    if (!kconn) return PGRES_POLLING_FAILED;
    return (int)PQconnectPoll(((KpgConn *)kconn)->conn);
}

/* (pointer) -> int — 1 on success, per PQsetnonblocking. Called once the
   connection is up so PQflush (inside PQsendQuery/PQsendQueryParams)
   never blocks either. */
int kpg_set_nonblocking(void *kconn) {
    if (!kconn) return 0;
    return PQsetnonblocking(((KpgConn *)kconn)->conn, 1) == 0 ? 1 : 0;
}

/* (pointer) -> int — the socket fd, for the caller to poll. */
int kpg_socket(void *kconn) {
    if (!kconn) return -1;
    return PQsocket(((KpgConn *)kconn)->conn);
}

/* (pointer) -> int   — CONNECTION_OK = 0, CONNECTION_BAD = 1 */
int kpg_status(void *kconn) {
    if (!kconn) return CONNECTION_BAD;
    return (int)PQstatus(((KpgConn *)kconn)->conn);
}

/* (pointer) -> void */
void kpg_finish(void *kconn) {
    KpgConn *kc = (KpgConn *)kconn;
    if (!kc) return;
    PQfinish(kc->conn);
    for (int i = 0; i < kc->param_count; i++) free(kc->param_values[i]);
    free(kc);
}

/* (pointer) -> string */
const char *kpg_error_message(void *kconn) {
    if (!kconn) return "connection is closed\n";
    return PQerrorMessage(((KpgConn *)kconn)->conn);
}

/* -----------------------------------------------------------------------
   Query setup — now keyed on the connection's own buffer.
   ----------------------------------------------------------------------- */

/* (pointer, string) -> void */
void kpg_set_sql(void *kconn, const char *sql) {
    KpgConn *kc = (KpgConn *)kconn;
    if (!kc) return;
    strncpy(kc->sql, sql, sizeof(kc->sql) - 1);
    kc->sql[sizeof(kc->sql) - 1] = '\0';
}

/* (pointer) -> void */
void kpg_clear_params(void *kconn) {
    KpgConn *kc = (KpgConn *)kconn;
    if (!kc) return;
    for (int i = 0; i < kc->param_count; i++) {
        free(kc->param_values[i]);
        kc->param_values[i] = NULL;
    }
    kc->param_count = 0;
}

/* (pointer, string) -> void */
void kpg_add_param(void *kconn, const char *value) {
    KpgConn *kc = (KpgConn *)kconn;
    if (!kc) return;
    if (kc->param_count >= MAX_PARAMS) return;
    kc->param_values[kc->param_count] = strdup(value);
    kc->param_count++;
}

/* (pointer) -> int   (returns 0, signature needs a return for FFI match) */
int kpg_add_null_param(void *kconn) {
    KpgConn *kc = (KpgConn *)kconn;
    if (!kc) return -1;
    if (kc->param_count >= MAX_PARAMS) return -1;
    kc->param_values[kc->param_count] = NULL;
    kc->param_count++;
    return 0;
}

/* -----------------------------------------------------------------------
   Query execution — async (PQsendQuery/PQsendQueryParams). The caller
   drains the result with kpg_is_busy/kpg_consume_input/kpg_get_result,
   waiting on kpg_socket's readiness whenever kpg_is_busy says so, instead
   of blocking in PQexec/PQexecParams.
   ----------------------------------------------------------------------- */

/* (pointer) -> int — 1 on success, 0 on failure (see kpg_error_message) */
int kpg_send_query(void *kconn) {
    KpgConn *kc = (KpgConn *)kconn;
    if (!kc) return 0;
    return PQsendQuery(kc->conn, kc->sql);
}

/* (pointer) -> int — 1 on success, 0 on failure */
int kpg_send_query_params(void *kconn) {
    KpgConn *kc = (KpgConn *)kconn;
    if (!kc) return 0;
    int ok = PQsendQueryParams(
        kc->conn,
        kc->sql,
        kc->param_count,
        NULL,                           /* paramTypes — let server infer */
        (const char *const *)kc->param_values,
        NULL,                           /* paramLengths — text format */
        NULL,                           /* paramFormats — all text */
        0                               /* resultFormat — text */
    );
    kpg_clear_params(kconn);
    return ok;
}

/* (pointer) -> int — 0 if all pending output was sent, 1 if more remains
   (poll for write-readiness and call again), -1 on error. */
int kpg_flush(void *kconn) {
    if (!kconn) return -1;
    return PQflush(((KpgConn *)kconn)->conn);
}

/* (pointer) -> int — 1 on success (may have read 0 bytes), 0 on error. */
int kpg_consume_input(void *kconn) {
    if (!kconn) return 0;
    return PQconsumeInput(((KpgConn *)kconn)->conn);
}

/* (pointer) -> int — 1 if a call to kpg_get_result would block. */
int kpg_is_busy(void *kconn) {
    if (!kconn) return 0;
    return PQisBusy(((KpgConn *)kconn)->conn);
}

/* (pointer) -> pointer — next result, or NULL (returned as 0) once the
   query is fully drained. Only safe to call when kpg_is_busy is 0. */
void *kpg_get_result(void *kconn) {
    if (!kconn) return NULL;
    return (void *)PQgetResult(((KpgConn *)kconn)->conn);
}

/* -----------------------------------------------------------------------
   Raw-fd polling — same poll(2) convention as kaappi-net's
   knet_poll_read/knet_poll_write (1 ready, 0 timeout, -1 error).
   Duplicated rather than depending on kaappi-net for six lines of code.
   ----------------------------------------------------------------------- */

/* (int, int) -> int — retries on EINTR: a nonzero (blocking) timeout
   gives a signal a real window to interrupt the syscall. Checks POLLIN
   before POLLHUP/POLLERR: a connection that delivers its last bytes and
   hangs up in the same instant sets both, and there's still unread data
   in the socket buffer — only a hangup/error with *no* pending data is a
   real "never becomes readable" condition. */
int kpg_poll_read(int fd, int timeout_ms) {
    struct pollfd pfd = { .fd = fd, .events = POLLIN };
    int rc;
    do {
        rc = poll(&pfd, 1, timeout_ms);
    } while (rc < 0 && errno == EINTR);
    if (rc < 0) return -1;
    if (rc == 0) return 0;
    if (pfd.revents & POLLIN) return 1;
    if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) return -1;
    return 1;
}

/* (int, int) -> int — see kpg_poll_read for why EINTR is retried and
   POLLOUT is checked before POLLHUP/POLLERR. */
int kpg_poll_write(int fd, int timeout_ms) {
    struct pollfd pfd = { .fd = fd, .events = POLLOUT };
    int rc;
    do {
        rc = poll(&pfd, 1, timeout_ms);
    } while (rc < 0 && errno == EINTR);
    if (rc < 0) return -1;
    if (rc == 0) return 0;
    if (pfd.revents & POLLOUT) return 1;
    if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) return -1;
    return 1;
}

/* -----------------------------------------------------------------------
   Result status — operate on a PGresult*, independent of KpgConn.
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
void *kpg_escape_literal(void *kconn, void *str_ptr) {
    if (!kconn) return NULL;
    const char *str = (const char *)str_ptr;
    size_t len = strlen(str);
    return (void *)PQescapeLiteral(((KpgConn *)kconn)->conn, str, len);
}
