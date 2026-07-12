;; Fiber concurrency: a slow query must not block sibling fibers, and two
;; connections' queries must overlap rather than run sequentially
;; (KEP-0001 Phase 6 acceptance criterion). Requires PostgreSQL with
;; database "kaappi_test" (see tests/test-dbapi.scm).
(import (scheme base) (scheme write) (scheme time) (srfi 18)
        (kaappi fibers) (kaappi pg))

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

(define (elapsed-seconds start)
  (/ (- (current-jiffy) start) (exact->inexact (jiffies-per-second))))

;; --- A slow query must not block a sibling fiber's ticker ---
(display "=== Slow query doesn't block sibling fibers ===") (newline)

(let ((ticks 0) (query-done #f) (conn (pg-connect "dbname=kaappi_test")))
  (define ticker
    (spawn (lambda ()
             (let loop ()
               (unless query-done
                 (set! ticks (+ ticks 1))
                 (thread-sleep! 0.001)
                 (loop))))))
  (define worker
    (spawn (lambda ()
             (pg-query conn "SELECT pg_sleep(0.2)")
             (set! query-done #t))))
  (fiber-join worker)
  (fiber-join ticker)
  (pg-close conn)
  (display "  (ticks during 200ms pg_sleep query: ") (display ticks) (display ")") (newline)
  (check "sibling fiber kept ticking during slow query" #t (> ticks 50)))

;; --- Two connections' slow queries overlap rather than serialize ---
(display "=== Two connections' queries overlap ===") (newline)

(let ((conn1 (pg-connect "dbname=kaappi_test"))
      (conn2 (pg-connect "dbname=kaappi_test"))
      (start (current-jiffy)))
  (define worker1 (spawn (lambda () (pg-query conn1 "SELECT pg_sleep(0.3)"))))
  (define worker2 (spawn (lambda () (pg-query conn2 "SELECT pg_sleep(0.3)"))))
  (fiber-join worker1)
  (fiber-join worker2)
  (let ((elapsed (elapsed-seconds start)))
    (pg-close conn1)
    (pg-close conn2)
    (display "  (elapsed for two concurrent 300ms sleeps: ") (display elapsed) (display "s)") (newline)
    ;; Sequential execution would take ~0.6s; concurrent execution
    ;; should finish close to the single-query duration. 0.5s leaves
    ;; generous headroom above 0.3s while still well under the 0.6s a
    ;; blocking implementation would take.
    (check "two concurrent queries overlap (well under sum of durations)" #t (< elapsed 0.5))))

(newline)
(display "=== Results: ")
(display pass) (display " passed, ")
(display fail) (display " failed ===")
(newline)
(when (> fail 0) (exit 1))
