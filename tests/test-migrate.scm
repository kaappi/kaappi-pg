;; Migration tests (requires PostgreSQL with database "kaappi_test")
(import (scheme base) (scheme write) (kaappi pg) (kaappi pg migrate))

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
(define mig-dir "tests/migrations")

;; Clean slate
(pg-exec conn "DROP TABLE IF EXISTS mig_posts")
(pg-exec conn "DROP TABLE IF EXISTS mig_users")
(pg-exec conn "DROP TABLE IF EXISTS schema_migrations")

;; --- Status before any migrations ---
(display "=== Initial Status ===") (newline)
(migrate-status conn mig-dir)

;; --- Migrate up (all) ---
(display "=== Migrate Up ===") (newline)
(let ((n (migrate-up conn mig-dir)))
  (check "applied 3 migrations" 3 n))

;; Verify tables exist
(let ((rows (pg-query conn
              "SELECT table_name FROM information_schema.tables
               WHERE table_name LIKE 'mig_%' ORDER BY table_name")))
  (check "tables created" 2 (length rows)))

;; Verify tracking table
(let ((rows (pg-query conn "SELECT version FROM schema_migrations ORDER BY version")))
  (check "versions recorded" '(1 2 3)
    (map (lambda (r) (vector-ref r 0)) rows)))

;; --- Idempotent: running up again does nothing ---
(display "=== Idempotent Up ===") (newline)
(let ((n (migrate-up conn mig-dir)))
  (check "no-op on second run" 0 n))

;; --- Status shows all applied ---
(display "=== Status ===") (newline)
(migrate-status conn mig-dir)

;; --- Insert test data ---
(pg-exec conn "INSERT INTO mig_users (name, email) VALUES ($1, $2)" "Alice" "alice@test.com")
(pg-exec conn "INSERT INTO mig_posts (user_id, title) VALUES ($1, $2)" 1 "Hello World")

;; --- Migrate down (1) ---
(display "=== Migrate Down 1 ===") (newline)
(let ((n (migrate-down conn mig-dir 1)))
  (check "rolled back 1" 1 n))

(let ((rows (pg-query conn "SELECT version FROM schema_migrations ORDER BY version")))
  (check "version 3 removed" '(1 2)
    (map (lambda (r) (vector-ref r 0)) rows)))

;; --- Migrate down (remaining) ---
(display "=== Migrate Down All ===") (newline)
(let ((n (migrate-down conn mig-dir 10)))
  (check "rolled back 2 more" 2 n))

(let ((rows (pg-query conn "SELECT version FROM schema_migrations ORDER BY version")))
  (check "all versions removed" '()
    (map (lambda (r) (vector-ref r 0)) rows)))

;; --- Migrate up again to verify clean re-apply ---
(display "=== Re-apply ===") (newline)
(let ((n (migrate-up conn mig-dir)))
  (check "re-applied 3" 3 n))

;; --- Clean up ---
(pg-exec conn "DROP TABLE IF EXISTS mig_posts")
(pg-exec conn "DROP TABLE IF EXISTS mig_users")
(pg-exec conn "DROP TABLE IF EXISTS schema_migrations")
(pg-close conn)

(newline)
(display "=== Results: ")
(display pass) (display " passed, ")
(display fail) (display " failed ===")
(newline)
(when (> fail 0) (exit 1))
