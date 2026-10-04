# Troubleshooting

Each entry gives the symptom, the cause and the fix. Start with these two commands; they answer most questions:

```bash
make status   # container state and health
make logs     # follow the database log (Ctrl-C to stop)
```

## Contents

1. [Port 5432 is already in use](#port-5432-is-already-in-use)
2. [Container is unhealthy or `make up` times out on first boot](#container-is-unhealthy-or-make-up-times-out-on-first-boot)
3. [Database starts but tables or data are missing](#database-starts-but-tables-or-data-are-missing)
4. [Changes to initdb, `.env` or `POLARIS_SCALE` have no effect](#changes-to-initdb-env-or-polaris_scale-have-no-effect)
5. [Apple Silicon](#apple-silicon)
6. [Recency queries return no rows](#recency-queries-return-no-rows)
7. [pg_cron: "can only create extension in database polaris"](#pg_cron-can-only-create-extension-in-database-polaris)
8. ["database is being accessed by other users"](#database-is-being-accessed-by-other-users)
9. [File permission errors with `/sql`, `/data` and other mounts](#file-permission-errors-with-sql-data-and-other-mounts)
10. [Out of memory or shared memory errors](#out-of-memory-or-shared-memory-errors)
11. [`make test` fails](#make-test-fails)
12. [Resetting a stuck environment](#resetting-a-stuck-environment)

---

## Port 5432 is already in use

**Symptom.** `make up` fails with `Bind for 0.0.0.0:5432 failed: port is already allocated` or `address already in use`.

**Cause.** A local PostgreSQL (Homebrew, Postgres.app, a system service) or another container already listens on 5432. The same applies to 8080 and 8081 for `make ui`.

**Fix.** Find the process with `lsof -i :5432` (macOS/Linux) and stop it, or move Polaris to another port:

```bash
# docker/.env
POSTGRES_PORT=5433
# .env (host tools)
PGPORT=5433
```

Then `make up`. The "ready on localhost:5432" message printed by `make up` reads the port from your shell, not from `docker/.env`, so it may still show 5432; `make status` shows the real mapping.

## Container is unhealthy or `make up` times out on first boot

**Symptom.** `make up` reports `container polaris-db is unhealthy`, or `make status` shows `health: starting` for a long time.

**Cause.** On an empty volume the entrypoint builds the whole dataset before the server accepts TCP connections. The health check probes over TCP, so the container stays "starting" until the build ends. This takes about 30 seconds at scale 1 and grows roughly linearly with `POLARIS_SCALE`. The health check gives up after about 5.5 minutes. If the build fails, the container never becomes healthy.

**Fix.** Run `make logs` and look for the `[polaris] 1/4 ... 4/4` progress lines and `[polaris] build complete`, or for an `ERROR:` line.

- Still building: wait, then run `make up` again; it returns as soon as the container is healthy.
- A large `POLARIS_SCALE`: boot with scale 1, then use `make build SCALE=n` once the server is up.
- An `ERROR:`: fix the cause, then `make clean && make up` (see the next entry for why a clean volume is needed).

## Database starts but tables or data are missing

**Symptom.** The container is healthy, but `SELECT * FROM meta.dataset` fails with `relation "meta.dataset" does not exist`, or schemas are empty.

**Cause.** Either `POLARIS_SKIP_BOOTSTRAP=1` was set on first boot, or the first-boot build failed part-way. In the second case the official entrypoint has already created the data directory, so a restart starts the server normally and never retries the build.

**Fix.** Rebuild in place with `make build`, or start over with `make clean && make up`.

## Changes to initdb, `.env` or `POLARIS_SCALE` have no effect

**Symptom.** You edited `docker/initdb/*`, `POLARIS_SCALE`, `POLARIS_SEED`, `POSTGRES_USER`/`POSTGRES_PASSWORD` or `PG_MAJOR`, restarted, and nothing changed.

**Cause.** The initdb scripts and these variables are used only when the `polaris-pgdata` volume is empty. A restart reuses the existing volume. Changes to the `Dockerfile` or `docker/conf/postgresql.conf` also need an image rebuild, which `make up` does not do once the image exists.

**Fix.**

| What changed | Run |
|---|---|
| `POLARIS_SCALE` / `POLARIS_SEED` only | `make build SCALE=n SEED=n` (keeps the volume) |
| initdb scripts, credentials, `PG_MAJOR` | `make clean && make up` |
| `Dockerfile` or `postgresql.conf` | `make bootstrap && make clean && make up` |

`make clean` deletes the data volume and everything you created in it.

## Apple Silicon

**Symptom.** Concern about emulation, or a warning such as `requested image's platform (linux/amd64) does not match the detected host platform`.

**Cause.** The image is built `FROM postgres:<PG_MAJOR>-bookworm`, which is multi-arch, and the extensions come from PGDG packages for both architectures. It builds and runs natively on arm64. The warning appears only if something forces `linux/amd64`, such as `DOCKER_DEFAULT_PLATFORM` or a `platform:` line you added.

**Fix.** Unset `DOCKER_DEFAULT_PLATFORM`, remove any `platform:` override, then `make nuke && make bootstrap && make up`. `SELECT version();` should report `aarch64`.

## Recency queries return no rows

**Symptom.** A query such as `WHERE order_date > now() - interval '30 days'` returns 0 rows or empty dashboards.

**Cause.** The synthetic data is generated relative to a fixed instant, `meta.as_of()` = 2025-12-31 23:59:59 UTC, so that results are identical on every machine. Nothing is dated after it, so windows anchored on `now()` or `CURRENT_DATE` slide past the data.

**Fix.** Anchor on `meta.as_of()`:

```sql
SELECT count(*) FROM commerce.orders
WHERE order_date > meta.as_of() - interval '30 days';   -- 4358 at scale 1, seed 42
```

## pg_cron: "can only create extension in database polaris"

**Symptom.** `CREATE EXTENSION pg_cron` in another database fails with `can only create extension in database polaris`, or `cron.schedule` is missing outside `polaris`.

**Cause.** pg_cron's background worker reads jobs from one database, set by `cron.database_name = 'polaris'` in `docker/conf/postgresql.conf`. The extension is installed there on first boot. Module 14 (`pg_cron_scheduled_jobs.sql`) and the monitoring capstone detect its absence elsewhere, print a NOTICE and run the job bodies manually instead.

**Fix.** Schedule jobs from `polaris`. To schedule work in another database from there, use `cron.schedule_in_database(...)`.

## "database is being accessed by other users"

**Symptom.** `DROP DATABASE x` fails with `database "x" is being accessed by other users`.

**Cause.** Another session is connected: psql, Adminer, pgAdmin, DBeaver, or a postgres_fdw/dblink connection opened by a module. For `polaris` itself, the pg_cron launcher is always connected.

**Fix.**

- Scratch databases: `DROP DATABASE x WITH (FORCE);` (this is what the scripts use).
- `polaris_ci_template` (created by `make test-modules`) is a template that refuses connections. Run `ALTER DATABASE polaris_ci_template IS_TEMPLATE false;` before dropping it.
- Do not drop `polaris`. Rebuild it in place with `make build`, or recreate the volume with `make clean && make up`.

## File permission errors with `/sql`, `/data` and other mounts

**Symptom.** `could not open file "/data/....csv" for writing: Read-only file system`, `Permission denied` when the server reads a file under `/sql` or `/data`, or `path must live under sql/, tests/, examples/, data/ or benchmarks/` from `make module`.

**Cause.**

- `sql/`, `data/`, `tests/`, `examples/` and `benchmarks/` are bind-mounted read-only, so server-side `COPY ... TO` cannot write there.
- Server-side `COPY FROM` runs as the `postgres` user in the container. On Linux, files the host user made unreadable to others, or SELinux labels (Fedora, RHEL), block it.
- `make module` maps repo paths to container paths and only accepts files in the mounted directories.

**Fix.** Write exports to `/tmp` inside the container (as module 09 does) or use psql's client-side `\copy`. On Linux, `chmod -R a+rX sql data tests examples benchmarks`; with SELinux, add `:z` to the bind mounts in `docker/docker-compose.yml`. Keep your own SQL files under `sql/` or `examples/`. On Windows, clone inside the WSL2 filesystem, not under `/mnt/c`. If `make` reports `Permission denied` for a script, restore the execute bit with `chmod +x scripts/*.sh benchmarks/*.sh`.

## Out of memory or shared memory errors

**Symptom.** `could not resize shared memory segment ... No space left on device`, `server closed the connection unexpectedly`, or `terminated by signal 9: Killed` in `make logs`, often during `make build-all`, `make test-modules` or `make bench`.

**Cause.** Parallel queries use `/dev/shm`. Compose sets `shm_size: 512mb`, but running the image outside compose gives Docker's 64 MB default. Signal 9 means the kernel or Docker Desktop killed the server for lack of memory. `shared_buffers` is 256 MB, and parallel workers and `maintenance_work_mem` add to that.

**Fix.** Always start the stack with `make up` (or compose). Give Docker at least 4 GB. At large scales, or if memory is tight, lower `SCALE` or `SET max_parallel_workers_per_gather = 0;` in the session.

## `make test` fails

**Symptom.** `pg_prove` reports `Bad plan. You planned 119 tests but ran 87.` or individual failures such as `dataset was generated at scale 1`.

**Cause.**

- A plan mismatch means a test file stopped early. Each file runs with `ON_ERROR_STOP`, so one SQL error aborts the remaining tests. The real error is printed above the summary.
- If you edited a test file, `SELECT plan(n)` must match the number of assertions (184, 119 and 58, for 361 in total).
- The data-invariant tests expect the reference dataset: scale 1, seed 42. They fail after `make build SCALE=5` or with a different `POLARIS_SEED`.

**Fix.** Read the first error in the output. To restore the reference dataset, run `make build` (scale 1, seed 42 by default), then `make test`.

## Resetting a stuck environment

Use the least destructive step that works:

| Step | Keeps | Command |
|---|---|---|
| Restart the containers | everything | `make restart` |
| Regenerate base data | module objects, volume | `make reset` |
| Rebuild schemas and data | volume (module objects are dropped) | `make build` |
| Fresh volume | nothing in the database | `make clean && make up` |
| Fresh image and volume | nothing | `make nuke && make bootstrap && make up` |

If `make` itself fails with `container 'polaris-db' is not running`, start it with `make up`. If compose reports a name conflict for `polaris-db`, an old container with that name exists: `docker rm -f polaris-db`, then `make up`.
