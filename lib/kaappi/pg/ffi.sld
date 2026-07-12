(define-library (kaappi pg ffi)
  (import (scheme base) (kaappi ffi))
  (export %pg-connect-start %pg-connect-poll %pg-set-nonblocking %pg-socket
          %pg-status %pg-finish %pg-error-message
          %pg-set-sql %pg-clear-params %pg-add-param %pg-add-null-param
          %pg-send-query %pg-send-query-params %pg-flush
          %pg-consume-input %pg-is-busy %pg-get-result
          %pg-poll-read %pg-poll-write
          %pg-result-status %pg-ntuples %pg-nfields %pg-clear
          %pg-result-error %pg-cmd-tuples
          %pg-fname %pg-ftype %pg-getvalue %pg-getisnull
          %pg-ptr-to-str %pg-free-ptr %pg-escape-literal
          PGRES_COMMAND_OK PGRES_TUPLES_OK PGRES_FATAL_ERROR
          CONNECTION_OK CONNECTION_BAD
          PGRES_POLLING_FAILED PGRES_POLLING_READING
          PGRES_POLLING_WRITING PGRES_POLLING_OK)
  (begin

    (define %lib (ffi-open "libkaappi_pg"))

    ;; Status constants
    (define CONNECTION_OK 0)
    (define CONNECTION_BAD 1)
    (define PGRES_EMPTY_QUERY 0)
    (define PGRES_COMMAND_OK 1)
    (define PGRES_TUPLES_OK 2)
    (define PGRES_FATAL_ERROR 7)

    ;; PostgresPollingStatusType
    (define PGRES_POLLING_FAILED 0)
    (define PGRES_POLLING_READING 1)
    (define PGRES_POLLING_WRITING 2)
    (define PGRES_POLLING_OK 3)

    ;; Connection (async: PQconnectStart/PQconnectPoll, never blocks)
    (define %pg-connect-start (ffi-fn %lib "kpg_connect_start" '(string) 'pointer))
    (define %pg-connect-poll  (ffi-fn %lib "kpg_connect_poll" '(pointer) 'int))
    (define %pg-set-nonblocking (ffi-fn %lib "kpg_set_nonblocking" '(pointer) 'int))
    (define %pg-socket        (ffi-fn %lib "kpg_socket" '(pointer) 'int))
    (define %pg-status        (ffi-fn %lib "kpg_status" '(pointer) 'int))
    (define %pg-finish        (ffi-fn %lib "kpg_finish" '(pointer) 'void))
    (define %pg-error-message (ffi-fn %lib "kpg_error_message" '(pointer) 'string))

    ;; Query setup (per-connection now, no more shared global state)
    (define %pg-set-sql       (ffi-fn %lib "kpg_set_sql" '(pointer string) 'void))
    (define %pg-clear-params  (ffi-fn %lib "kpg_clear_params" '(pointer) 'void))
    (define %pg-add-param     (ffi-fn %lib "kpg_add_param" '(pointer string) 'void))
    (define %pg-add-null-param (ffi-fn %lib "kpg_add_null_param" '(pointer) 'int))

    ;; Query execution (async: PQsendQuery(Params) + drain loop)
    (define %pg-send-query        (ffi-fn %lib "kpg_send_query" '(pointer) 'int))
    (define %pg-send-query-params (ffi-fn %lib "kpg_send_query_params" '(pointer) 'int))
    (define %pg-flush             (ffi-fn %lib "kpg_flush" '(pointer) 'int))
    (define %pg-consume-input     (ffi-fn %lib "kpg_consume_input" '(pointer) 'int))
    (define %pg-is-busy           (ffi-fn %lib "kpg_is_busy" '(pointer) 'int))
    (define %pg-get-result        (ffi-fn %lib "kpg_get_result" '(pointer) 'pointer))

    ;; Raw-fd polling
    (define %pg-poll-read  (ffi-fn %lib "kpg_poll_read" '(int int) 'int))
    (define %pg-poll-write (ffi-fn %lib "kpg_poll_write" '(int int) 'int))

    ;; Result status
    (define %pg-result-status (ffi-fn %lib "kpg_result_status" '(pointer) 'int))
    (define %pg-ntuples     (ffi-fn %lib "kpg_ntuples" '(pointer) 'int))
    (define %pg-nfields     (ffi-fn %lib "kpg_nfields" '(pointer) 'int))
    (define %pg-clear       (ffi-fn %lib "kpg_clear" '(pointer) 'void))
    (define %pg-result-error (ffi-fn %lib "kpg_result_error" '(pointer) 'string))
    (define %pg-cmd-tuples  (ffi-fn %lib "kpg_cmd_tuples" '(pointer) 'string))

    ;; Field metadata (col as pointer — fixnum trick)
    (define %pg-fname       (ffi-fn %lib "kpg_fname" '(pointer pointer) 'pointer))
    (define %pg-ftype       (ffi-fn %lib "kpg_ftype" '(pointer pointer) 'int))

    ;; Cell access (row as pointer — fixnum trick)
    (define %pg-getvalue    (ffi-fn %lib "kpg_getvalue" '(pointer pointer long) 'pointer))
    (define %pg-getisnull   (ffi-fn %lib "kpg_getisnull" '(pointer pointer long) 'int))

    ;; Utility
    (define %pg-ptr-to-str  (ffi-fn %lib "kpg_ptr_to_str" '(pointer) 'string))
    (define %pg-free-ptr    (ffi-fn %lib "kpg_free_ptr" '(pointer) 'void))
    (define %pg-escape-literal (ffi-fn %lib "kpg_escape_literal" '(pointer pointer) 'pointer))))
