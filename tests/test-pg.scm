;; Connection lifecycle regression tests: operations on a closed
;; connection must raise a normal Scheme error ("pg: connection is
;; closed"), never reach the FFI with a NULL handle — that used to
;; segfault the whole process (NULL KpgConn dereference in the C shim).
;;
;; Run: make && cp libkaappi_pg.dylib ~/.kaappi/lib/ &&
;;      kaappi --lib-path ./lib tests/test-pg.scm
;;
;; Requires PostgreSQL with database "kaappi_test" (createdb kaappi_test);
;; skips gracefully when no server is reachable.
(import (scheme base) (scheme write) (kaappi pg))

(define pass 0)
(define fail 0)

(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1))
             (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1))
             (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

;; Returns #f if thunk returns normally, else the raised error's message.
(define (raised-message thunk)
  (guard (exn (#t (if (error-object? exn)
                      (error-object-message exn)
                      exn)))
    (thunk)
    #f))

;; --- Skip when no server is available ---
(define conn
  (guard (exn (#t #f))
    (pg-connect "dbname=kaappi_test")))

(unless conn
  (display "SKIP: no reachable PostgreSQL (createdb kaappi_test)") (newline)
  (exit 0))

;; --- Sanity: connection works before close ---
(display "=== Before close ===") (newline)
(check "query before close" 1
  (vector-ref (car (pg-query conn "SELECT 1")) 0))
(define stale-cursor (pg-cursor conn))

;; --- Close, then every operation must raise, not crash ---
(display "=== Use after close ===") (newline)
(pg-close conn)
(check "pg-connected? after close" #f (pg-connected? conn))
(check "pg-query on closed connection raises" "pg: connection is closed"
  (raised-message (lambda () (pg-query conn "SELECT 1"))))
(check "pg-exec on closed connection raises" "pg: connection is closed"
  (raised-message (lambda () (pg-exec conn "SELECT 1"))))
(check "pg-execute on cursor made before close raises" "pg: connection is closed"
  (raised-message (lambda () (pg-execute stale-cursor "SELECT 1"))))
(check "pg-execute on cursor made after close raises" "pg: connection is closed"
  (raised-message (lambda () (pg-execute (pg-cursor conn) "SELECT 1"))))
(check "pg-commit on closed connection raises" "pg: connection is closed"
  (raised-message (lambda () (pg-commit conn))))
(check "pg-error-message on closed connection returns, not crashes"
  "connection is closed" (pg-error-message conn))
(check "double pg-close is safe" #f
  (raised-message (lambda () (pg-close conn))))

;; --- call-with-pg-connection closes again after proc; must be idempotent ---
(display "=== call-with-pg-connection ===") (newline)
(check "call-with-pg-connection tolerates early close" 'ok
  (call-with-pg-connection "dbname=kaappi_test"
    (lambda (c) (pg-close c) 'ok)))

;; --- Process survived it all: a fresh connection still works ---
(display "=== After ===") (newline)
(define conn2 (pg-connect "dbname=kaappi_test"))
(check "fresh connection works" 1
  (vector-ref (car (pg-query conn2 "SELECT 1")) 0))
(pg-close conn2)

(newline)
(display "=== Results: ")
(display pass) (display " passed, ")
(display fail) (display " failed ===")
(newline)
(when (> fail 0) (exit 1))
