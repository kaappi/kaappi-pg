;; Full DB-API tests (requires PostgreSQL with database "kaappi_test")
;; Create with: createdb kaappi_test
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

(define conn (pg-connect "dbname=kaappi_test"))

;; --- Setup ---
(display "=== Setup ===") (newline)
(pg-exec conn "DROP TABLE IF EXISTS test_users")
(pg-exec conn "CREATE TABLE test_users (id SERIAL PRIMARY KEY, name TEXT NOT NULL, age INTEGER, active BOOLEAN DEFAULT TRUE)")
(display "  Table created") (newline)

;; --- Insert ---
(display "=== Insert ===") (newline)
(check "insert 1" 1 (pg-exec conn "INSERT INTO test_users (name, age) VALUES ($1, $2)" "Alice" 30))
(check "insert 2" 1 (pg-exec conn "INSERT INTO test_users (name, age) VALUES ($1, $2)" "Bob" 25))
(check "insert 3" 1 (pg-exec conn "INSERT INTO test_users (name, age, active) VALUES ($1, $2, $3)" "Charlie" 35 #f))
(check "insert null" 1 (pg-exec conn "INSERT INTO test_users (name, age) VALUES ($1, $2)" "Diana" #f))

;; --- Cursor + fetchone ---
(display "=== Cursor fetchone ===") (newline)
(let ((cur (pg-cursor conn)))
  (pg-execute cur "SELECT name, age FROM test_users WHERE id = $1" 1)
  (let ((row (pg-fetchone cur)))
    (check "fetchone name" "Alice" (vector-ref row 0))
    (check "fetchone age" 30 (vector-ref row 1)))
  (check "fetchone exhausted" #f (pg-fetchone cur))
  (pg-cursor-close cur))

;; --- fetchall ---
(display "=== fetchall ===") (newline)
(let ((cur (pg-cursor conn)))
  (pg-execute cur "SELECT name FROM test_users ORDER BY id")
  (let ((rows (pg-fetchall cur)))
    (check "fetchall count" 4 (length rows))
    (check "fetchall first" "Alice" (vector-ref (car rows) 0))
    (check "fetchall last" "Diana" (vector-ref (list-ref rows 3) 0)))
  (pg-cursor-close cur))

;; --- fetchmany ---
(display "=== fetchmany ===") (newline)
(let ((cur (pg-cursor conn)))
  (pg-execute cur "SELECT name FROM test_users ORDER BY id")
  (let ((batch1 (pg-fetchmany cur 2))
        (batch2 (pg-fetchmany cur 2))
        (batch3 (pg-fetchmany cur 2)))
    (check "fetchmany batch1" 2 (length batch1))
    (check "fetchmany batch2" 2 (length batch2))
    (check "fetchmany batch3 (empty)" 0 (length batch3)))
  (pg-cursor-close cur))

;; --- pg-query convenience ---
(display "=== pg-query ===") (newline)
(let ((rows (pg-query conn "SELECT name, age FROM test_users WHERE age > $1 ORDER BY age" 26)))
  (check "query count" 2 (length rows))
  (check "query first" "Alice" (vector-ref (car rows) 0))
  (check "query second" "Charlie" (vector-ref (cadr rows) 0)))

;; --- NULL handling ---
(display "=== NULL ===") (newline)
(let ((rows (pg-query conn "SELECT name, age FROM test_users WHERE name = $1" "Diana")))
  (check "null value" #f (vector-ref (car rows) 1)))

;; --- Boolean handling ---
(display "=== Booleans ===") (newline)
(let ((rows (pg-query conn "SELECT name, active FROM test_users ORDER BY id")))
  (check "bool true" #t (vector-ref (car rows) 1))
  (check "bool false" #f (vector-ref (caddr rows) 1)))

;; --- Type round-trips ---
(display "=== Types ===") (newline)
(pg-exec conn "DROP TABLE IF EXISTS test_types")
(pg-exec conn "CREATE TABLE test_types (i INTEGER, f FLOAT8, t TEXT, b BOOLEAN)")
(pg-exec conn "INSERT INTO test_types VALUES ($1, $2, $3, $4)" 42 3.14 "hello" #t)
(let ((rows (pg-query conn "SELECT * FROM test_types")))
  (let ((row (car rows)))
    (check "int round-trip" 42 (vector-ref row 0))
    (check "float round-trip" #t (and (number? (vector-ref row 1))
                                       (> (vector-ref row 1) 3.13)
                                       (< (vector-ref row 1) 3.15)))
    (check "text round-trip" "hello" (vector-ref row 2))
    (check "bool round-trip" #t (vector-ref row 3))))

;; --- Description ---
(display "=== Description ===") (newline)
(let ((cur (pg-cursor conn)))
  (pg-execute cur "SELECT name, age FROM test_users LIMIT 1")
  (let ((desc (pg-description cur)))
    (check "desc count" 2 (length desc))
    (check "desc col0 name" "name" (car (car desc)))
    (check "desc col1 name" "age" (car (cadr desc))))
  (pg-cursor-close cur))

;; --- Rowcount ---
(display "=== Rowcount ===") (newline)
(let ((cur (pg-cursor conn)))
  (pg-execute cur "SELECT * FROM test_users")
  (check "rowcount select" 4 (pg-rowcount cur))
  (pg-cursor-close cur))
(check "rowcount delete" 1 (pg-exec conn "DELETE FROM test_users WHERE name = $1" "Charlie"))

;; --- Transactions ---
(display "=== Transactions ===") (newline)
(call-with-pg-transaction conn
  (lambda ()
    (pg-exec conn "INSERT INTO test_users (name, age) VALUES ($1, $2)" "Eve" 28)))
(let ((rows (pg-query conn "SELECT name FROM test_users WHERE name = $1" "Eve")))
  (check "transaction committed" 1 (length rows)))

;; --- call-with-pg-connection ---
(display "=== call-with-pg-connection ===") (newline)
(let ((result (call-with-pg-connection "dbname=kaappi_test"
                (lambda (c) (pg-query c "SELECT 1 AS one")))))
  (check "with-connection" 1 (vector-ref (car result) 0)))

;; --- Cleanup ---
(pg-exec conn "DROP TABLE IF EXISTS test_users")
(pg-exec conn "DROP TABLE IF EXISTS test_types")
(pg-close conn)

(newline)
(display "=== Results: ")
(display pass) (display " passed, ")
(display fail) (display " failed ===")
(newline)
(when (> fail 0) (exit 1))
