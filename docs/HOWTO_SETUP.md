# Setup

Polaris runs as a single PostgreSQL container with the curriculum and a synthetic city dataset built in. Everything is driven by `make`; run `make help` for the full target list.

## Prerequisites

| Requirement | Notes |
|---|---|
| Docker 24+ with Compose v2 | `docker compose version` must work (the plugin, not legacy `docker-compose`). |
| 4 GB RAM for Docker | Docker Desktop: Settings > Resources. |
| About 3 GB free disk | Image is about 1 GB; the data volume at scale 1 is about 1.5 GB. |
| GNU Make and bash | macOS's bash 3.2 is supported. |
| OS | Linux, macOS (Intel or Apple Silicon), Windows with WSL2. On Windows, clone and run inside the WSL2 filesystem. |

No local PostgreSQL install is needed: `psql`, `pg_prove` and `pg_dump` run inside the container.

## Quick start

```bash
git clone https://github.com/SatvikPraveen/Postgres-Polaris.git
cd Postgres-Polaris
make bootstrap   # copies docker/.env and .env from the examples, builds the image
make up          # starts PostgreSQL and waits until it is healthy
make psql        # opens psql in database polaris
```

Try a first query:

```sql
SELECT generator_version, scale, seed, as_of FROM meta.dataset;
SELECT count(*) FROM commerce.orders WHERE order_date > meta.as_of() - interval '30 days';
```

The dataset ends at `meta.as_of()` (2025-12-31 23:59:59 UTC). Every recency query in the curriculum uses `meta.as_of()` instead of `now()`, and yours should too.

## What the first boot does

The scripts in `docker/initdb/` run only when the data volume is empty:

1. `000_databases.sql` creates the scratch database `polaris_test` and sets the `search_path` to the domain schemas.
2. `010_extensions.sql` installs the extensions (PostGIS, pg_cron, pg_partman, pgTAP, HypoPG, pgvector, pg_stat_statements and others).
3. `020_roles.sql` creates the group roles and the login roles `polaris_app_user` and `polaris_readonly_user`.
4. `100_bootstrap_curriculum.sh` runs `sql/build.sql`: schemas, tables, constraints and the synthetic data for `POLARIS_SCALE` and `POLARIS_SEED`.

This takes about 30 seconds at scale 1. `make up` returns only when the build has finished. Later starts reuse the volume and are fast.

## Configuration

`docker/.env` (created from `docker/.env.example`) controls the container. `.env` at the repo root holds client settings (`PGHOST`, `PGPORT`, ...) for tools on the host.

| Variable | Default | Effect |
|---|---|---|
| `PG_MAJOR` | `17` | PostgreSQL major version, `17` or `18`. Builds image `polaris-db:<PG_MAJOR>`. |
| `POSTGRES_PORT` | `5432` | Host port for PostgreSQL. |
| `ADMINER_PORT` / `PGADMIN_PORT` | `8080` / `8081` | Host ports for the optional web UIs. |
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | `polaris` / `polaris` / `polaris_dev_only` | Database and superuser. Local use only. |
| `POLARIS_SCALE` | `1` | Dataset size multiplier for the first-boot build. |
| `POLARIS_SEED` | `42` | Generator seed for the first-boot build. |
| `POLARIS_SKIP_BOOTSTRAP` | `0` | `1` leaves the database empty (extensions and roles only). |

`PG_MAJOR`, `POLARIS_*` and the credentials take effect only on a fresh volume. After changing them run `make clean && make up`. If you change `POSTGRES_PORT`, change `PGPORT` in `.env` to match.

## Connecting from host tools

| Setting | Value |
|---|---|
| Host / port | `localhost` / `5432` (or `POSTGRES_PORT`) |
| Database | `polaris` |
| User / password | `polaris` / `polaris_dev_only` |
| URI | `postgresql://polaris:polaris_dev_only@localhost:5432/polaris` |

This works for a local `psql`, DBeaver, DataGrip or a desktop pgAdmin. For browser UIs in containers:

```bash
make ui   # Adminer on http://localhost:8080, pgAdmin on http://localhost:8081
```

- Adminer: system PostgreSQL, server `db`, user `polaris`, password `polaris_dev_only`, database `polaris`.
- pgAdmin runs in desktop mode (no login) with a preconfigured server "Polaris"; enter the password when prompted.

## Running modules

Modules live in `sql/02_*` to `sql/16_*`. Each file is standalone (it needs only the base dataset) and idempotent (safe to re-run).

```bash
make module F=sql/03_dml_queries/practice_selects.sql   # run one file
make build-all                                          # rebuild base data, then run every module in order
```

For options such as per-statement timing or a different target database, use the script directly:

```bash
scripts/run_sql.sh -t sql/11_perf_tuning/explain_analyze_playbook.sql
scripts/run_sql.sh examples/quick_demo.sql
```

Files must live under `sql/`, `tests/`, `examples/`, `data/` or `benchmarks/`, which are mounted read-only in the container. See [MODULE_MAP_EXERCISES.md](MODULE_MAP_EXERCISES.md) for what each module covers and [LEARNING_PATHS.md](LEARNING_PATHS.md) for suggested orders.

## Scaling the dataset

```bash
make build SCALE=5 SEED=7   # rebuild polaris in place at scale 5, seed 7
```

`make build` recreates every curriculum schema, so objects created by modules are dropped. Row counts for people, orders, trips and readings scale linearly; geography (neighbourhoods, roads, stations) does not. Scale 1 is about 420k rows.

To keep `polaris` unchanged and build a separate database:

```bash
scripts/build_db.sh -s 5 -r 7 -d city5
```

`make reset` regenerates only the base data in place (using `POLARIS_SCALE` and `POLARIS_SEED` from the env files) and keeps module objects. It asks for confirmation; `scripts/reset_db.sh -y` skips the prompt.

## Verification

| Command | What it checks |
|---|---|
| `make test` | 361 pgTAP tests via `pg_prove` (schema, constraints, data invariants, regressions). |
| `make test-modules` | All 39 module files run twice, each on a fresh copy of the base dataset. Logs go to `.check_logs/`. |
| `make reproduce` | Builds the same seed twice under different planner settings and compares `meta.fingerprint()`. |
| `make backup` | `pg_dump`, restore into a scratch database, fingerprint comparison. Dumps go to `backups/`. |
| `make bench` | pgbench workload suite; see [benchmarks/README.md](../benchmarks/README.md). |
| `make check` | `lint`, `test`, `test-modules` and `reproduce`, as in CI. `lint` needs `shellcheck` on the host. |

CI runs these against PostgreSQL 17 and 18 on every push.

## Stopping, resetting, uninstalling

| Command | Effect |
|---|---|
| `make down` | Stop containers. Data is kept. |
| `make restart` | `down` then `up`. |
| `make clean` | Stop containers and delete the data and pgAdmin volumes. The next `make up` rebuilds from scratch. |
| `make nuke` | `clean`, plus remove the `polaris-db` image for the current `PG_MAJOR` and `.check_logs/`. |

To remove everything, run `make nuke`, delete the repository directory, and optionally remove the pulled `postgres`, `adminer` and `dpage/pgadmin4` base images.

If something fails, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
