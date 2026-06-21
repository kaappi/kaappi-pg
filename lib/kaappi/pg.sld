(define-library (kaappi pg)
  (import (scheme base) (kaappi pg ffi) (kaappi pg types))
  (export pg-connect pg-close pg-connected? pg-error-message
          pg-cursor pg-execute pg-fetchone pg-fetchall pg-fetchmany
          pg-description pg-rowcount pg-cursor-close
          pg-commit pg-rollback
          pg-exec pg-query
          call-with-pg-connection call-with-pg-transaction)
  (begin

    ;; --- Connection record ---

    (define-record-type <pg-connection>
      (%make-pg-connection ptr)
      pg-connection?
      (ptr pg-conn-ptr set-pg-conn-ptr!))

    (define (pg-connect conninfo)
      (let ((ptr (%pg-connect conninfo)))
        (when (= (%pg-status ptr) CONNECTION_BAD)
          (let ((msg (%pg-error-message ptr)))
            (%pg-finish ptr)
            (error "pg-connect failed" msg)))
        (%make-pg-connection ptr)))

    (define (pg-close conn)
      (when (pg-connected? conn)
        (%pg-finish (pg-conn-ptr conn))
        (set-pg-conn-ptr! conn 0)))

    (define (pg-connected? conn)
      (not (= (pg-conn-ptr conn) 0)))

    (define (pg-error-message conn)
      (%pg-error-message (pg-conn-ptr conn)))

    ;; --- Cursor record ---

    (define-record-type <pg-cursor>
      (%make-pg-cursor conn result nrows ncols types row-idx)
      pg-cursor?
      (conn    cursor-conn)
      (result  cursor-result  set-cursor-result!)
      (nrows   cursor-nrows   set-cursor-nrows!)
      (ncols   cursor-ncols   set-cursor-ncols!)
      (types   cursor-types   set-cursor-types!)
      (row-idx cursor-row-idx set-cursor-row-idx!))

    (define (pg-cursor conn)
      (%make-pg-cursor conn 0 0 0 '() 0))

    (define (pg-cursor-close cursor)
      (when (not (= (cursor-result cursor) 0))
        (%pg-clear (cursor-result cursor))
        (set-cursor-result! cursor 0)))

    ;; --- Execute ---

    (define (pg-execute cursor sql . params)
      (pg-cursor-close cursor)
      (let* ((conn-ptr (pg-conn-ptr (cursor-conn cursor)))
             (res (if (null? params)
                      (begin (%pg-set-sql sql)
                             (%pg-exec conn-ptr))
                      (begin (%pg-set-sql sql)
                             (%pg-clear-params)
                             (for-each
                               (lambda (p)
                                 (let ((converted (pg-convert-param p)))
                                   (if converted
                                       (%pg-add-param converted)
                                       (%pg-add-null-param))))
                               params)
                             (%pg-exec-params conn-ptr))))
             (status (%pg-result-status res)))
        (when (= status PGRES_FATAL_ERROR)
          (let ((msg (%pg-result-error res)))
            (%pg-clear res)
            (error "pg: query failed" msg)))
        (set-cursor-result! cursor res)
        (let ((nrows (%pg-ntuples res))
              (ncols (%pg-nfields res)))
          (set-cursor-nrows! cursor nrows)
          (set-cursor-ncols! cursor ncols)
          (set-cursor-row-idx! cursor 0)
          ;; Cache column type OIDs
          (let loop ((i 0) (acc '()))
            (if (= i ncols)
                (set-cursor-types! cursor (reverse acc))
                (loop (+ i 1)
                      (cons (%pg-ftype res i) acc)))))))

    ;; --- Fetch ---

    (define (pg-fetchone cursor)
      (let ((row-idx (cursor-row-idx cursor))
            (nrows   (cursor-nrows cursor))
            (ncols   (cursor-ncols cursor))
            (res     (cursor-result cursor))
            (types   (cursor-types cursor)))
        (if (>= row-idx nrows)
            #f
            (let ((row (make-vector ncols)))
              (let loop ((col 0) (tps types))
                (when (< col ncols)
                  (if (= (%pg-getisnull res row-idx col) 1)
                      (vector-set! row col #f)
                      (let* ((ptr (%pg-getvalue res row-idx col))
                             (text (%pg-ptr-to-str ptr))
                             (oid  (car tps)))
                        (vector-set! row col (pg-convert-value oid text))))
                  (loop (+ col 1) (if (null? tps) '() (cdr tps)))))
              (set-cursor-row-idx! cursor (+ row-idx 1))
              row))))

    (define (pg-fetchall cursor)
      (let loop ((acc '()))
        (let ((row (pg-fetchone cursor)))
          (if (eq? row #f)
              (reverse acc)
              (loop (cons row acc))))))

    (define (pg-fetchmany cursor n)
      (let loop ((acc '()) (count 0))
        (if (>= count n)
            (reverse acc)
            (let ((row (pg-fetchone cursor)))
              (if (eq? row #f)
                  (reverse acc)
                  (loop (cons row acc) (+ count 1)))))))

    ;; --- Description ---

    (define (pg-description cursor)
      (let ((res  (cursor-result cursor))
            (ncols (cursor-ncols cursor)))
        (if (= res 0)
            '()
            (let loop ((i 0) (acc '()))
              (if (= i ncols)
                  (reverse acc)
                  (let* ((name-ptr (%pg-fname res i))
                         (name (%pg-ptr-to-str name-ptr))
                         (oid  (%pg-ftype res i)))
                    (loop (+ i 1)
                          (cons (list name oid) acc))))))))

    ;; --- Rowcount ---

    (define (pg-rowcount cursor)
      (let ((res (cursor-result cursor)))
        (if (= res 0)
            -1
            (let ((status (%pg-result-status res)))
              (if (= status PGRES_TUPLES_OK)
                  (cursor-nrows cursor)
                  (let ((s (%pg-cmd-tuples res)))
                    (or (string->number s) -1)))))))

    ;; --- Convenience ---

    (define (pg-commit conn)
      (let ((cur (pg-cursor conn)))
        (pg-execute cur "COMMIT")
        (pg-cursor-close cur)))

    (define (pg-rollback conn)
      (let ((cur (pg-cursor conn)))
        (pg-execute cur "ROLLBACK")
        (pg-cursor-close cur)))

    (define (pg-exec conn sql . params)
      (let ((cur (pg-cursor conn)))
        (apply pg-execute cur sql params)
        (let ((rc (pg-rowcount cur)))
          (pg-cursor-close cur)
          rc)))

    (define (pg-query conn sql . params)
      (let ((cur (pg-cursor conn)))
        (apply pg-execute cur sql params)
        (let ((rows (pg-fetchall cur)))
          (pg-cursor-close cur)
          rows)))

    (define (call-with-pg-connection conninfo proc)
      (let ((conn (pg-connect conninfo)))
        (guard (exn
                (#t (pg-close conn) (raise exn)))
          (let ((result (proc conn)))
            (pg-close conn)
            result))))

    (define (call-with-pg-transaction conn proc)
      (pg-exec conn "BEGIN")
      (guard (exn
              (#t (pg-rollback conn) (raise exn)))
        (let ((result (proc)))
          (pg-commit conn)
          result)))))
