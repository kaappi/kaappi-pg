# kaappi-pg

PostgreSQL client library for [Kaappi Scheme](https://github.com/kaappi/kaappi),
inspired by Python's DB-API 2.0 (PEP 249).

Wraps [libpq](https://www.postgresql.org/docs/current/libpq.html) via a thin C
helper. Provides connection objects, cursors, parameterized queries (`$1`, `$2`),
`fetchone`/`fetchall`/`fetchmany`, transactions, and automatic type conversion.

## Build

Requires PostgreSQL client libraries (`libpq`) and `pg_config` on PATH.

```bash
make                    # builds libkaappi_pg.dylib (macOS) or .so (Linux)
```

## Usage

```bash
export DYLD_LIBRARY_PATH=/path/to/kaappi-pg:/path/to/libpq  # macOS
kaappi --lib-path /path/to/kaappi-pg/lib your-script.scm
```

```scheme
(import (kaappi pg))

(define conn (pg-connect "host=localhost dbname=mydb"))

;; Cursor-based (DB-API style)
(let ((cur (pg-cursor conn)))
  (pg-execute cur "SELECT name, age FROM users WHERE age > $1" 25)
  (pg-fetchone cur)     ; => #("Alice" 30) or #f
  (pg-fetchall cur)     ; => (#("Bob" 35) #("Charlie" 40))
  (pg-cursor-close cur))

;; Convenience shortcuts
(pg-query conn "SELECT * FROM users")           ; => list of row vectors
(pg-exec conn "DELETE FROM old_sessions")       ; => rowcount (integer)

;; Transactions
(call-with-pg-transaction conn
  (lambda ()
    (pg-exec conn "UPDATE accounts SET balance = balance - $1 WHERE id = $2" 100 1)
    (pg-exec conn "UPDATE accounts SET balance = balance + $1 WHERE id = $2" 100 2)))

(pg-close conn)
```

## API

### Connection

| Procedure | Description |
|---|---|
| `(pg-connect conninfo)` | Connect using libpq connection string |
| `(pg-close conn)` | Close connection |
| `(pg-connected? conn)` | Check if connected |
| `(pg-commit conn)` | Commit transaction |
| `(pg-rollback conn)` | Rollback transaction |
| `(call-with-pg-connection conninfo proc)` | Auto-closing connection |
| `(call-with-pg-transaction conn proc)` | Auto-commit/rollback block |

### Cursor

| Procedure | Description |
|---|---|
| `(pg-cursor conn)` | Create a new cursor |
| `(pg-execute cur sql arg ...)` | Execute query with `$1`-style params |
| `(pg-fetchone cur)` | Fetch next row as vector, `#f` at end |
| `(pg-fetchall cur)` | Fetch all remaining rows |
| `(pg-fetchmany cur n)` | Fetch up to N rows |
| `(pg-description cur)` | Column info: `((name oid) ...)` |
| `(pg-rowcount cur)` | Rows affected or returned |
| `(pg-cursor-close cur)` | Release result resources |

### Convenience

| Procedure | Description |
|---|---|
| `(pg-query conn sql arg ...)` | Execute + fetchall (returns row list) |
| `(pg-exec conn sql arg ...)` | Execute non-SELECT (returns rowcount) |

## Type Mapping

### PostgreSQL → Scheme (results)

| PostgreSQL | Scheme |
|---|---|
| boolean | `#t` / `#f` |
| smallint, integer, bigint | exact integer |
| real, double precision | inexact number |
| numeric | number |
| text, varchar | string |
| NULL | `#f` |
| everything else | string |

### Scheme → PostgreSQL (parameters)

| Scheme | PostgreSQL |
|---|---|
| `#f` | NULL |
| `#t` | boolean true |
| number | text representation |
| string | text |

## Tests

```bash
# Offline type conversion (no database needed)
kaappi --lib-path lib tests/test-types.scm

# Full DB-API tests (requires PostgreSQL)
createdb kaappi_test
DYLD_LIBRARY_PATH=. kaappi --lib-path lib tests/test-dbapi.scm
```

## Requirements

- [Kaappi](https://github.com/kaappi/kaappi) with `(kaappi ffi)` support
- PostgreSQL client library (`libpq`)
- `pg_config` on PATH

## License

MIT
