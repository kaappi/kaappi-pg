# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

## [0.1.0] - 2026-07-26

### Added
- PostgreSQL client — `pg-connect`/`pg-close`, DB-API-style cursors
  (`pg-cursor`, `pg-execute`, `pg-fetchone`/`pg-fetchall`/`pg-fetchmany`,
  `pg-description`, `pg-rowcount`), transactions (`pg-commit`/`pg-rollback`),
  convenience `pg-exec`/`pg-query`, and
  `call-with-pg-connection`/`call-with-pg-transaction`
- Schema migrations via `(kaappi pg migrate)`
- Async libpq integration with the fiber scheduler
- libpq-backed C FFI built via `make`
- CI workflow for automated testing
