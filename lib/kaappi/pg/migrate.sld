;;; (kaappi pg migrate) — Database migrations
;;;
;;; Migrations are .sql files in a directory, named with a numeric prefix:
;;;   001-create-users.sql
;;;   002-add-email-index.sql
;;;   003-create-posts.sql
;;;
;;; Each file contains SQL to run. Down migrations use a -- DOWN marker:
;;;   CREATE TABLE users (id SERIAL, name TEXT);
;;;   -- DOWN
;;;   DROP TABLE users;

(define-library (kaappi pg migrate)
  (import (scheme base) (scheme write) (scheme read) (scheme file)
          (scheme char) (scheme cxr) (srfi 170) (kaappi pg))
  (export migrate-up migrate-down migrate-status
          migrate-create migrate-redo)
  (begin

    (define *table* "schema_migrations")

    ;; --- Ensure migration tracking table exists ---

    (define (ensure-table conn)
      (pg-exec conn (string-append
        "CREATE TABLE IF NOT EXISTS " *table* " ("
        "  version INTEGER PRIMARY KEY,"
        "  name TEXT NOT NULL,"
        "  applied_at TIMESTAMP DEFAULT now()"
        ")")))

    ;; --- Read migration files ---

    (define (read-file path)
      (let ((port (open-input-file path)))
        (let loop ((acc (open-output-string)))
          (let ((ch (read-char port)))
            (if (eof-object? ch)
                (begin (close-input-port port)
                       (get-output-string acc))
                (begin (write-char ch acc)
                       (loop acc)))))))

    (define (parse-migration-file content)
      (let ((down-marker "-- DOWN"))
        (let ((pos (string-search content down-marker)))
          (if pos
              (values (string-trim-right (substring content 0 pos))
                      (string-trim-left (substring content (+ pos (string-length down-marker))
                                                   (string-length content))))
              (values content #f)))))

    (define (string-search haystack needle)
      (let ((hlen (string-length haystack))
            (nlen (string-length needle)))
        (let loop ((i 0))
          (cond ((> (+ i nlen) hlen) #f)
                ((equal? (substring haystack i (+ i nlen)) needle) i)
                (else (loop (+ i 1)))))))

    (define (string-trim-right s)
      (let loop ((i (string-length s)))
        (if (and (> i 0)
                 (let ((ch (string-ref s (- i 1))))
                   (or (char=? ch #\space) (char=? ch #\newline)
                       (char=? ch #\return) (char=? ch #\tab))))
            (loop (- i 1))
            (substring s 0 i))))

    (define (string-trim-left s)
      (let ((len (string-length s)))
        (let loop ((i 0))
          (if (and (< i len)
                   (let ((ch (string-ref s i)))
                     (or (char=? ch #\space) (char=? ch #\newline)
                         (char=? ch #\return) (char=? ch #\tab))))
              (loop (+ i 1))
              (substring s i len)))))

    ;; --- Parse migration filename: "001-create-users.sql" ---

    (define (parse-migration-name filename)
      (let ((dash-pos (let loop ((i 0))
                        (cond ((= i (string-length filename)) #f)
                              ((char=? (string-ref filename i) #\-) i)
                              (else (loop (+ i 1)))))))
        (if dash-pos
            (let ((version (string->number (substring filename 0 dash-pos)))
                  (name (substring filename dash-pos
                                   (- (string-length filename) 4))))
              (if version (values version name) (values #f #f)))
            (values #f #f))))

    ;; --- List migration files in directory ---

    (define (list-migration-files dir)
      (let ((entries (guard (exn (#t '())) (directory-files dir))))
        (let loop ((es entries) (acc '()))
          (if (null? es)
              (sort-migrations acc)
              (let ((name (car es)))
                (if (sql-file? name)
                    (let-values (((version mname) (parse-migration-name name)))
                      (if version
                          (loop (cdr es)
                                (cons (list version mname
                                            (string-append dir "/" name))
                                      acc))
                          (loop (cdr es) acc)))
                    (loop (cdr es) acc)))))))

    (define (sql-file? name)
      (let ((len (string-length name)))
        (and (> len 4)
             (equal? (substring name (- len 4) len) ".sql"))))

    (define (sort-migrations ms)
      (let insert-sort ((items ms) (result '()))
        (if (null? items)
            result
            (insert-sort (cdr items)
                         (insert-by-version (car items) result)))))

    (define (insert-by-version m sorted)
      (cond ((null? sorted) (list m))
            ((<= (car m) (caar sorted)) (cons m sorted))
            (else (cons (car sorted)
                        (insert-by-version m (cdr sorted))))))

    ;; --- Get applied versions ---

    (define (applied-versions conn)
      (let ((rows (pg-query conn
                    (string-append "SELECT version FROM " *table*
                                  " ORDER BY version"))))
        (map (lambda (row) (vector-ref row 0)) rows)))

    ;; --- migrate-up: apply pending migrations ---

    (define (migrate-up conn dir . args)
      (let ((target (if (pair? args) (car args) #f)))
        (ensure-table conn)
        (let ((files (list-migration-files dir))
              (applied (applied-versions conn)))
          (let loop ((fs files) (count 0))
            (if (null? fs) count
                (let* ((m (car fs))
                       (version (car m))
                       (name (cadr m))
                       (path (caddr m)))
                  (if (memv version applied)
                      (loop (cdr fs) count)
                      (if (and target (> version target))
                          count
                          (begin
                            (display "  Applying ")
                            (display version) (display name)
                            (display "...") (newline)
                            (let ((content (read-file path)))
                              (let-values (((up-sql down-sql) (parse-migration-file content)))
                                (call-with-pg-transaction conn
                                  (lambda ()
                                    (pg-exec conn up-sql)
                                    (pg-exec conn
                                      (string-append
                                        "INSERT INTO " *table*
                                        " (version, name) VALUES ($1, $2)")
                                      version name)))))
                            (loop (cdr fs) (+ count 1)))))))))))

    ;; --- migrate-down: rollback last N migrations ---

    (define (migrate-down conn dir . args)
      (let ((n (if (pair? args) (car args) 1)))
        (ensure-table conn)
        (let ((files (list-migration-files dir))
              (applied (reverse (applied-versions conn))))
          (let loop ((versions applied) (count 0))
            (if (or (null? versions) (= count n)) count
                (let* ((version (car versions))
                       (m (find-migration files version)))
                  (if (not m)
                      (begin
                        (display "  Warning: no file for version ")
                        (display version) (newline)
                        (loop (cdr versions) count))
                      (let ((path (caddr m))
                            (name (cadr m)))
                        (display "  Reverting ")
                        (display version) (display name)
                        (display "...") (newline)
                        (let ((content (read-file path)))
                          (let-values (((up-sql down-sql) (parse-migration-file content)))
                            (if (not down-sql)
                                (begin
                                  (display "  Error: no -- DOWN section")
                                  (newline)
                                  count)
                                (begin
                                  (call-with-pg-transaction conn
                                    (lambda ()
                                      (pg-exec conn down-sql)
                                      (pg-exec conn
                                        (string-append
                                          "DELETE FROM " *table*
                                          " WHERE version = $1")
                                        version)))
                                  (loop (cdr versions) (+ count 1))))))))))))))

    (define (find-migration files version)
      (let loop ((fs files))
        (cond ((null? fs) #f)
              ((= (caar fs) version) (car fs))
              (else (loop (cdr fs))))))

    ;; --- migrate-status: show migration status ---

    (define (migrate-status conn dir)
      (ensure-table conn)
      (let ((files (list-migration-files dir))
            (applied (applied-versions conn)))
        (display "Migration Status:") (newline)
        (for-each
          (lambda (m)
            (let ((version (car m))
                  (name (cadr m)))
              (display (if (memv version applied) "  [x] " "  [ ] "))
              (display version) (display name)
              (newline)))
          files)
        (let ((pending (- (length files)
                          (length (filter (lambda (m) (memv (car m) applied))
                                         files)))))
          (display pending) (display " pending")
          (newline))))

    (define (filter pred lst)
      (cond ((null? lst) '())
            ((pred (car lst)) (cons (car lst) (filter pred (cdr lst))))
            (else (filter pred (cdr lst)))))

    ;; --- migrate-redo: rollback and reapply last migration ---

    (define (migrate-redo conn dir)
      (migrate-down conn dir 1)
      (migrate-up conn dir))

    ;; --- migrate-create: create a new migration file ---

    (define (migrate-create dir name)
      (let* ((files (guard (exn (#t '())) (list-migration-files dir)))
             (max-version (if (null? files) 0
                              (apply max (map car files))))
             (next (+ max-version 1))
             (padded (let ((s (number->string next)))
                       (let loop ((s s))
                         (if (< (string-length s) 3)
                             (loop (string-append "0" s))
                             s))))
             (filename (string-append dir "/" padded "-" name ".sql")))
        (let ((port (open-output-file filename)))
          (display "-- Migration: " port)
          (display name port) (newline port)
          (newline port)
          (newline port)
          (display "-- DOWN" port) (newline port)
          (newline port)
          (close-output-port port))
        (display "Created ") (display filename) (newline)
        filename))))
