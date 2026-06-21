(import (scheme base) (scheme write) (kaappi pg))

(call-with-pg-connection "dbname=kaappi_test"
  (lambda (conn)
    ;; Create table
    (pg-exec conn "CREATE TABLE IF NOT EXISTS demo (id SERIAL PRIMARY KEY, name TEXT, score INTEGER)")

    ;; Insert rows
    (pg-exec conn "INSERT INTO demo (name, score) VALUES ($1, $2)" "Alice" 95)
    (pg-exec conn "INSERT INTO demo (name, score) VALUES ($1, $2)" "Bob" 87)
    (pg-exec conn "INSERT INTO demo (name, score) VALUES ($1, $2)" "Charlie" 92)

    ;; Query with cursor
    (let ((cur (pg-cursor conn)))
      (pg-execute cur "SELECT name, score FROM demo ORDER BY score DESC")

      (display "=== Leaderboard ===") (newline)
      (display "Columns: ") (display (pg-description cur)) (newline)
      (newline)

      (let loop ()
        (let ((row (pg-fetchone cur)))
          (when row
            (display (vector-ref row 0))
            (display ": ")
            (display (vector-ref row 1))
            (newline)
            (loop))))
      (pg-cursor-close cur))

    ;; Convenience query
    (newline)
    (display "High scorers: ")
    (display (pg-query conn "SELECT name FROM demo WHERE score >= $1 ORDER BY name" 90))
    (newline)

    ;; Cleanup
    (pg-exec conn "DROP TABLE demo")))
