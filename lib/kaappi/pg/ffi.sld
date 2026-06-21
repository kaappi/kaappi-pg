(define-library (kaappi pg ffi)
  (import (scheme base) (kaappi ffi))
  (export %pg-connect %pg-status %pg-finish %pg-error-message
          %pg-set-sql %pg-exec %pg-clear-params %pg-add-param
          %pg-add-null-param %pg-exec-params
          %pg-result-status %pg-ntuples %pg-nfields %pg-clear
          %pg-result-error %pg-cmd-tuples
          %pg-fname %pg-ftype %pg-getvalue %pg-getisnull
          %pg-ptr-to-str %pg-free-ptr %pg-escape-literal
          PGRES_COMMAND_OK PGRES_TUPLES_OK PGRES_FATAL_ERROR
          CONNECTION_OK CONNECTION_BAD)
  (begin

    (define %lib (ffi-open "libkaappi_pg"))

    ;; Status constants
    (define CONNECTION_OK 0)
    (define CONNECTION_BAD 1)
    (define PGRES_EMPTY_QUERY 0)
    (define PGRES_COMMAND_OK 1)
    (define PGRES_TUPLES_OK 2)
    (define PGRES_FATAL_ERROR 7)

    ;; Connection
    (define %pg-connect     (ffi-fn %lib "kpg_connect" '(string) 'pointer))
    (define %pg-status      (ffi-fn %lib "kpg_status" '(pointer) 'int))
    (define %pg-finish      (ffi-fn %lib "kpg_finish" '(pointer) 'void))
    (define %pg-error-message (ffi-fn %lib "kpg_error_message" '(pointer) 'string))

    ;; Query setup
    (define %pg-set-sql     (ffi-fn %lib "kpg_set_sql" '(string) 'void))
    (define %pg-clear-params (ffi-fn %lib "kpg_clear_params" '() 'void))
    (define %pg-add-param   (ffi-fn %lib "kpg_add_param" '(string) 'void))
    (define %pg-add-null-param (ffi-fn %lib "kpg_add_null_param" '() 'int))

    ;; Query execution
    (define %pg-exec        (ffi-fn %lib "kpg_exec" '(pointer) 'pointer))
    (define %pg-exec-params (ffi-fn %lib "kpg_exec_params" '(pointer) 'pointer))

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
