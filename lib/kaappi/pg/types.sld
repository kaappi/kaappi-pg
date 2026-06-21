(define-library (kaappi pg types)
  (import (scheme base))
  (export pg-convert-value pg-convert-param)
  (begin

    ;; PostgreSQL type OIDs
    (define OID_BOOL     16)
    (define OID_INT8     20)
    (define OID_INT2     21)
    (define OID_INT4     23)
    (define OID_TEXT     25)
    (define OID_OID      26)
    (define OID_FLOAT4  700)
    (define OID_FLOAT8  701)
    (define OID_VARCHAR 1043)
    (define OID_NUMERIC 1700)

    (define (pg-convert-value oid text)
      (cond
        ((= oid OID_BOOL)
         (cond ((equal? text "t") #t)
               ((equal? text "f") #f)
               (else text)))
        ((or (= oid OID_INT2) (= oid OID_INT4)
             (= oid OID_INT8) (= oid OID_OID))
         (or (string->number text) text))
        ((or (= oid OID_FLOAT4) (= oid OID_FLOAT8))
         (or (string->number text) text))
        ((= oid OID_NUMERIC)
         (or (string->number text) text))
        (else text)))

    (define (pg-convert-param value)
      (cond
        ((eq? value #f)   #f)
        ((eq? value #t)   "t")
        ((string? value)  value)
        ((number? value)  (number->string value))
        (else (error "pg: unsupported parameter type" value))))))
