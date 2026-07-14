(define-library (kaappi pg)
  (import (scheme base) (kaappi fibers) (kaappi pg ffi) (kaappi pg types))
  (export pg-connect pg-close pg-connected? pg-error-message
          pg-cursor pg-execute pg-fetchone pg-fetchall pg-fetchmany
          pg-description pg-rowcount pg-cursor-close
          pg-commit pg-rollback
          pg-exec pg-query
          call-with-pg-connection call-with-pg-transaction)
  (begin

    ;; --- Async plumbing (KEP-0001 Phase 6) ---
    ;;
    ;; Every libpq call that would traditionally block (connect, send,
    ;; fetch) is driven through its async counterpart and a poll loop
    ;; instead: PQconnectStart/PQconnectPoll for connect,
    ;; PQsendQuery(Params)+PQflush for send, PQisBusy/PQconsumeInput/
    ;; PQgetResult to drain. Waiting for the socket blocks in poll(2) for
    ;; a short bounded slice (%poll-timeout-ms) rather than the whole
    ;; query, then calls (yield) so an already-ready sibling fiber gets a
    ;; turn before this fiber's next attempt.
    ;;
    ;; (yield) here is a deliberate design choice: yield sets a flag the
    ;; *existing* dispatch loop checks (vm_dispatch.zig's runUntil), so it
    ;; returns Yielded up through one frame instead of recursing into a new
    ;; one — a flat suspend/resume, the same shape waitForFd uses for other
    ;; blocking I/O.
    ;;
    ;; Historical note: this loop originally used (yield) to work around a
    ;; core bug where thread-sleep! always drove the scheduler via a nested
    ;; runSchedulerStep/runUntil call regardless of the calling fiber's
    ;; context, so two fibers each sleeping through hundreds of short
    ;; retries piled up hundreds of nested native stack frames (each only
    ;; unwinding once its own timer fired) — under load this manifested as
    ;; multi-second stalls, not a clean hang. That bug was fixed in kaappi
    ;; core #1463: threadSleepFn now takes the same dispatched-from-
    ;; scheduler yield-retry path waitForFd uses, so thread-sleep! is no
    ;; longer dangerous in a retry loop. The (yield) form is kept because
    ;; yield plus a short poll timeout is just as reasonable a design here.
    (define %poll-timeout-ms 1)

    (define (pg-wait-readable ptr)
      (let loop ()
        (let ((r (%pg-poll-read (%pg-socket ptr) %poll-timeout-ms)))
          (cond
            ((= r 1) #t)
            ((= r 0) (yield) (loop))
            (else (error "pg: poll failed" (%pg-error-message ptr)))))))

    (define (pg-wait-writable ptr)
      (let loop ()
        (let ((r (%pg-poll-write (%pg-socket ptr) %poll-timeout-ms)))
          (cond
            ((= r 1) #t)
            ((= r 0) (yield) (loop))
            (else (error "pg: poll failed" (%pg-error-message ptr)))))))

    (define (pg-connect-poll-loop ptr)
      (let loop ()
        (let ((status (%pg-connect-poll ptr)))
          (cond
            ((= status PGRES_POLLING_OK) #t)
            ((= status PGRES_POLLING_FAILED) #f)
            ((= status PGRES_POLLING_READING) (pg-wait-readable ptr) (loop))
            ((= status PGRES_POLLING_WRITING) (pg-wait-writable ptr) (loop))
            (else (loop))))))

    ;; Drains any unsent output after PQsendQuery(Params); PQflush returns
    ;; 1 when more remains (wait for writability and retry), 0 when done.
    (define (pg-flush-loop ptr)
      (let loop ()
        (let ((rc (%pg-flush ptr)))
          (cond
            ((= rc 0) #t)
            ((= rc 1) (pg-wait-writable ptr) (loop))
            (else (error "pg: flush failed" (%pg-error-message ptr)))))))

    ;; Standard libpq async result drain: while busy, wait for readability
    ;; and consume input; once not busy, PQgetResult won't block. Keeps
    ;; only the last non-NULL result (PQexec's documented behavior for a
    ;; multi-statement string), clearing any earlier ones.
    (define (pg-drain-result ptr)
      (let loop ((final 0))
        (let busy-loop ()
          (when (= (%pg-is-busy ptr) 1)
            (pg-wait-readable ptr)
            (when (= (%pg-consume-input ptr) 0)
              (error "pg: consume input failed" (%pg-error-message ptr)))
            (busy-loop)))
        (let ((res (%pg-get-result ptr)))
          (if (= res 0)
              final
              (begin
                (when (not (= final 0)) (%pg-clear final))
                (loop res))))))

    (define (pg-send-and-drain ptr params?)
      (let ((ok (if params? (%pg-send-query-params ptr) (%pg-send-query ptr))))
        (when (= ok 0)
          (error "pg: send query failed" (%pg-error-message ptr))))
      (pg-flush-loop ptr)
      (pg-drain-result ptr))

    ;; --- Connection record ---

    (define-record-type <pg-connection>
      (%make-pg-connection ptr)
      pg-connection?
      (ptr pg-conn-ptr set-pg-conn-ptr!))

    (define (pg-connect conninfo)
      (let ((ptr (%pg-connect-start conninfo)))
        (pg-connect-poll-loop ptr)
        (when (= (%pg-status ptr) CONNECTION_BAD)
          (let ((msg (%pg-error-message ptr)))
            (%pg-finish ptr)
            (error "pg-connect failed" msg)))
        (%pg-set-nonblocking ptr)
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
      (pg-execute-list cursor sql params))

    ;; Takes params as a plain list rather than a rest-arg so pg-exec/
    ;; pg-query can forward their own captured params without `apply` —
    ;; apply invokes its target closure via the VM's native-reentrant call
    ;; path (vm_calls.callReentrant), which bumps native_reentry_depth for
    ;; the closure's *entire* dynamic extent; yield checks that depth and
    ;; silently no-ops while it's nonzero (by design, for guard/handler
    ;; thunks — see primitives_fiber.zig's yieldFn), so every yield inside
    ;; pg-wait-readable/pg-wait-writable would be a no-op for the rest of
    ;; this call tree, serializing concurrent fibers instead of
    ;; interleaving them. A direct call compiles to a plain bytecode
    ;; CALL/TAILCALL and never touches that counter.
    (define (pg-execute-list cursor sql params)
      (pg-cursor-close cursor)
      (let* ((conn-ptr (pg-conn-ptr (cursor-conn cursor)))
             (res (if (null? params)
                      (begin (%pg-set-sql conn-ptr sql)
                             (pg-send-and-drain conn-ptr #f))
                      (begin (%pg-set-sql conn-ptr sql)
                             (%pg-clear-params conn-ptr)
                             (for-each
                               (lambda (p)
                                 (let ((converted (pg-convert-param p)))
                                   (if converted
                                       (%pg-add-param conn-ptr converted)
                                       (%pg-add-null-param conn-ptr))))
                               params)
                             (pg-send-and-drain conn-ptr #t))))
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
        (pg-execute-list cur sql params)
        (let ((rc (pg-rowcount cur)))
          (pg-cursor-close cur)
          rc)))

    (define (pg-query conn sql . params)
      (let ((cur (pg-cursor conn)))
        (pg-execute-list cur sql params)
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
