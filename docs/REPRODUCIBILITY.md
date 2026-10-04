# Reproducibility

The project is built so that a result produced on one machine can be regenerated and checked on another.

## What is pinned

| Layer | Mechanism |
|---|---|
| Server | `docker/Dockerfile` builds from `postgres:${PG_MAJOR}-bookworm` with PGDG packages; `PG_MAJOR` is 17 or 18 |
| Configuration | `docker/conf/postgresql.conf` is versioned and loaded explicitly, with `jit = off` for stable plans |
| Data | `scale` and `seed` fully determine every row; the generator version is stored in `meta.dataset` |
| Time | queries use `meta.as_of()` instead of `now()` |
| Code | every module is standalone and idempotent, checked by `make test-modules` |

## Verifying a dataset

```bash
make reproduce            # scale 1, seed 42
make reproduce SCALE=2 SEED=7
```

`scripts/reproduce.sh` builds the dataset twice into scratch databases. The second build forces nested loops, a 64 kB `work_mem` and parallel query. It then compares `meta.fingerprint()` table by table, using row count plus an MD5 of all row contents excluding load-time audit columns. The check passes only if every table is identical.

To compare with someone else's run, exchange the fingerprint:

```sql
SELECT table_name, row_count, content_md5 FROM meta.fingerprint() ORDER BY 1;
```

## Verifying backups

`make backup` dumps the database with `pg_dump -Fc` and restores it into a scratch database with four parallel jobs. It compares fingerprints before and after, and declares success only if every table matches.

## Benchmarks

`make bench` records the environment next to the numbers: server version, non-default settings, host, image, dataset parameters and git commit, including a dirty-tree flag. It reports confidence intervals rather than single values. See [`benchmarks/README.md`](../benchmarks/README.md).

## Continuous integration

Every push runs `.github/workflows/ci.yml` on PostgreSQL 17 and 18:
1. A cold start that builds the dataset on first boot.
2. The pgTAP suite.
3. All 39 modules, each twice on a fresh copy.
4. Every example.
5. The reproducibility check.
6. A verified backup and restore.
7. A benchmark smoke run.

## Reporting checklist

When publishing a number produced with this project, include:

1. Commit hash, and whether the tree was clean.
2. `PG_MAJOR` and `server_version`.
3. `meta.dataset`: `generator_version`, `scale`, `seed`.
4. For timings: `environment.json` from the benchmark run, and the confidence interval, not just the mean.
