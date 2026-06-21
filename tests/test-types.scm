;; Offline type conversion tests (no PostgreSQL needed)
(import (scheme base) (scheme write) (kaappi pg types))

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

(display "=== pg-convert-value ===") (newline)

;; Bool (OID 16)
(check "bool t" #t (pg-convert-value 16 "t"))
(check "bool f" #f (pg-convert-value 16 "f"))

;; Integer types
(check "int4"   42   (pg-convert-value 23 "42"))
(check "int4 neg" -7 (pg-convert-value 23 "-7"))
(check "int2"   1    (pg-convert-value 21 "1"))
(check "int8"   9999999999 (pg-convert-value 20 "9999999999"))

;; Float types
(check "float8" 3.14 (pg-convert-value 701 "3.14"))
(check "float4" 2.5  (pg-convert-value 700 "2.5"))

;; Numeric
(check "numeric int" 100 (pg-convert-value 1700 "100"))

;; Text/varchar
(check "text" "hello" (pg-convert-value 25 "hello"))
(check "varchar" "world" (pg-convert-value 1043 "world"))

;; Unknown OID → string passthrough
(check "unknown" "2024-01-01" (pg-convert-value 1082 "2024-01-01"))

(display "=== pg-convert-param ===") (newline)

(check "param string" "hello" (pg-convert-param "hello"))
(check "param int"    "42"    (pg-convert-param 42))
(check "param float"  #t      (string? (pg-convert-param 3.14)))
(check "param bool t" "t"     (pg-convert-param #t))
(check "param null"   #f      (pg-convert-param #f))

(newline)
(display "=== Results: ")
(display pass) (display " passed, ")
(display fail) (display " failed ===")
(newline)
(when (> fail 0) (exit 1))
