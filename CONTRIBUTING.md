# Contributing

Contributions are welcome: corrections, new exercises, new modules, detectors, benchmark workloads.

## Development loop

```bash
make bootstrap && make up     # PostgreSQL 17 with the dataset built
make module F=sql/07_geospatial/routing_nearest.sql
make check                    # lint, pgTAP, every module, reproducibility
```

To test on PostgreSQL 18, set `PG_MAJOR=18` in `docker/.env`, then run `make clean && make up`.

## Rules for SQL modules

`make test-modules` enforces these for every file under `sql/02_*` to `sql/16_*`:

1. **Runs clean.** The file runs with `ON_ERROR_STOP=1` on a fresh copy of the base dataset.
2. **Idempotent.** It runs a second time without errors. Use `CREATE OR REPLACE`, `IF NOT EXISTS`, and `DROP ... IF EXISTS` for objects the file owns.
3. **Standalone.** It depends only on the base build (`sql/build.sql`). Create anything you need from another module yourself.
4. **Leaves the base intact.** Do not drop, rename or truncate base tables. Run data-changing demos in a transaction that rolls back, or on tables the module owns. Adding indexes is fine.
5. **Uses dataset time.** Recency filters use `meta.as_of()`, not `now()` or `CURRENT_DATE`.
6. **Measures distance correctly.** Use `::geography` for metres. Never measure in EPSG:3857.
7. **Cleans up.** Leave nothing running: no event triggers, replication slots, cron jobs or held advisory locks.
8. **Stays readable.** Each section starts with a comment saying what it teaches, and output stays short (`LIMIT`, `\echo` headers).

## Tests

- **pgTAP.** Suites live in `tests/*.sql` and run with `make test`. Update `plan(n)` when you add assertions.
- **Generator changes.** If you change `seed_data.sql`, bump `generator_version`, update `docs/DATASET.md`, and run `make reproduce`.
- **Constraints.** A new constraint needs a test proving it rejects bad data, using `throws_ok` with the SQLSTATE.

## Commits and pull requests

- Use focused commits with a conventional prefix (`feat`, `fix`, `docs`, `test`, `build`, `ci`) and a body that says why.
- CI must pass on PostgreSQL 17 and 18.
- If a change alters a result quoted in the docs, such as a recovered effect or a row count, update the docs in the same pull request.
