# Troubleshooting

Start here:

```bash
docker compose ps                                    # which container is unhealthy
docker compose logs --tail=100 gateway
curl -s localhost:8500/health | jq
curl -s localhost:8500/health/services | jq
curl -s localhost:8500/health/attendance-sessions | jq
```

Every proxied response carries `x-correlation-id`. It is echoed in the error
body and recorded in `audit_logs`, so one id ties the browser request to the
service log line.

---

## Gateway returns 503

The gateway could not reach the owning service, or it timed out.

```bash
docker compose ps attendance-service result-service
docker compose logs --tail=200 attendance-service
```

`/health/services` names which one is down. Check, in order: the container is
running, Postgres and Redis are healthy, and the service's own `/health`
returns 200.

From inside the gateway container:

```bash
docker compose exec gateway wget -qO- http://attendance-service:3001/health
```

`wget` on Alpine resolves the service name — if that fails, the problem is
Docker networking, not the application.

## Every request returns 401 or 403, only in Docker

`INTERNAL_SERVICE_TOKEN` differs between the gateway and the services, or is
missing on one side. The gateway presents it in `x-internal-token`; each service
verifies it in constant time.

```bash
docker compose exec gateway printenv INTERNAL_SERVICE_TOKEN
docker compose exec result-service printenv INTERNAL_SERVICE_TOKEN
```

They must be byte-identical. An unset token on a service disables verification
there, so a mismatch shows up as one side rejecting valid traffic.

Outside Docker this usually means the token is set on your shell but not in the
service. Restart the stack after editing `.env` — the variables are read once
at startup.

## Users logged out after a deploy

`JWT_ACCESS_SECRET` / `JWT_REFRESH_SECRET` changed, or only the old
`JWT_ACCESS_TOKEN_SECRET` / `JWT_REFRESH_TOKEN_SECRET` names were set. All three
processes must share the original values; changing them invalidates every
access and refresh token. Restore the previous secret and users log back in.

## Gateway is fine, frontend shows failed API calls

```bash
docker compose logs --tail=100 frontend
docker compose exec frontend printenv BACKEND_BASE_URL
```

The Next.js server rewrites `/v1/*` to the gateway. A failure here is usually a
blank or stale `BACKEND_BASE_URL`, or the gateway not yet healthy — `frontend`
depends on the gateway being *started*, not *healthy*, so a browser hit during
the first 30 seconds can 502.

## Duplicate alerts

Both stacks are running against the same database, and each schedules the same
cron. This is the one genuinely destructive side effect of running the monolith
and the services side by side.

```bash
docker compose -f docker-compose.yml ps
cd ARMS-360-Backend && docker compose ps
```

Stop one of them. Both should never be scheduled at once — see
`docs/migration-guide.md` §2.

To rehearse without sending mail, set `ALERT_DRY_RUN=true`: payloads are built
and logged, nothing is delivered.

## Attendance dashboard is empty

The executive dashboard query is gateway-resident and joins `attendance_records`
directly. That only works while the gateway shares the attendance service's
database.

- Confirm `DATABASE_URL` is identical in the gateway and attendance-service
  containers.
- Confirm the record exists: `docker compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select count(*) from attendance_records;"`
- Mark attendance, then re-check — the dashboard may be cached; `redis-cli -c flushall` inside the Redis container clears it.

This is the clearest symptom of the shared-database design, and it disappears
in Phase 2 when the dashboard becomes an attendance-service endpoint.

## Uploads 404 after switching to Docker

Uploads are stored on a per-service volume:

| Volume | Mount | Serves |
| --- | --- | --- |
| `gateway-uploads` | `/app/uploads` | `/uploads/*` static routes |
| `attendance-uploads` | `/app/uploads` | attendance assets |
| `result-uploads` | `/app/uploads` | marksheets, templates |

An upload written through the monolith lands in the monolith's volume, not
these. Copy the old directory in:

```bash
docker cp ./ARMS-360-Backend/uploads/. arms360-gateway:/app/uploads/
```

## `docker compose config` fails

Podman-compose (the `docker` shim on some Linux images) is stricter and less
complete than Docker Compose. Check the error text — `podman-compose` has known
gaps around `depends_on: condition:` and YAML anchors. Validate the file
independently:

```bash
python3 -c "import yaml;yaml.safe_load(open('docker-compose.yml'));print('YAML OK')"
```

## A service build fails after an unrelated change

Each service compiles only its own import graph, so an unrelated file can still
break it through a shared import. Build all three:

```bash
npm run build:services
```

The failure names the real file. `npm run build:services` is the check to run
before pushing.

## Port already in use

```bash
docker compose ps                       # is it ours?
ss -ltnp | grep -E '8500|9000'
```

Override the host port rather than editing compose: `GATEWAY_PORT=8600 docker compose up -d`.
The container-internal ports are fixed by the service topology — change those
only if you also update the gateway's upstream URLs.

## Service cannot reach Postgres

```bash
docker compose exec postgres pg_isready -U "$POSTGRES_USER"
docker compose logs --tail=50 postgres
```

`DATABASE_URL` must use the **container** hostname `postgres:5432`, not
`localhost` — `localhost` inside a service container is that container. The
host-side value of `POSTGRES_*` is only used to build that URL.

## Nothing works after `git pull`

```bash
docker compose up --build -d --force-recreate
docker image prune -f
```

Stale images are the usual culprit after a `Dockerfile.services` change, since
all three services share one Dockerfile.

## Getting a database shell

No host port is published on purpose:

```bash
docker compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
```

If you must use a GUI client, uncomment the commented `ports:` block for
`postgres` and bind it to `127.0.0.1` only — never `0.0.0.0`.

## A single business route returns 400 "invalid input syntax for type uuid"

A support module imported only for its repositories still contributes its
controllers. If it is not registered with a `RouterModule` prefix it mounts at
`/`, and its `@Get(':id')` handler catches single-segment routes such as
`GET /exams` and tries to parse `"exams"` as a UUID.

Both service modules export their route tables (`RESULT_SERVICE_ROUTES`,
`ATTENDANCE_SERVICE_ROUTES`) and `gateway-boundary.spec.ts` asserts that every
directly imported controller module is listed. If you add a module to a
service, add its prefix to that table too.

Confirm the mounted paths from the startup log:

```bash
docker compose logs result-service | grep RoutesResolver
```

Every `XxxController {/...}` line must show a real prefix; a bare `{/}` is the
bug.

## Next.js container hangs on "Installing TypeScript"

`next.config.ts` is loaded by the Next.js server at startup, so the `typescript`
package must exist at **runtime**, even though it is a devDependency. The
frontend Dockerfile copies `node_modules/typescript` from the builder stage into
the runtime image. If that copy is removed, `next start` pauses to run
`yarn add typescript` inside the container.

## Frontend `/v1/*` calls return 500 but the gateway is healthy

The `/v1/:path*` rewrite destination is serialised into
`.next/routes-manifest.json` during `next build`. Check what was baked in:

```bash
docker compose exec frontend grep -o 'http://[a-z0-9.:]*' .next/routes-manifest.json | sort -u
```

It must be `http://gateway:3000`. `BACKEND_BASE_URL` is supplied as a **build
arg** by compose; changing it requires rebuilding the frontend image.

## `podman-compose up` does not pick up a rebuilt image

`podman-compose` reuses the existing container even when the image tag now
points at a new ID. Force the recreation and confirm the IDs match:

```bash
docker compose up -d --force-recreate --no-deps result-service
podman inspect arms360-result-service --format '{{.Image}}'
podman images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep result-service
```

`podman rm -f` fails with `has dependent containers which must be removed
before it` when other containers depend on the target; `--force-recreate`
handles the ordering.

## Restored database is missing tables or `pg_restore -l` prints garbage

A binary `pg_dump` transferred with CRLF conversion is corrupted: every `\n`
becomes `\r\n`. `pg_restore -l` reports an impossible creation date and
negative TOC entry counts. Repair it by stripping the inserted `\r` bytes:

```bash
python3 -c "from pathlib import Path; p=Path('dump.dump'); d=p.read_bytes(); p.with_suffix('.fixed.dump').write_bytes(d.replace(b'\r\n', b'\n'))"
pg_restore -l dump.fixed.dump | head
```

Also remember that `POSTGRES_USER` / `POSTGRES_DB` are only honoured when the
Postgres volume is empty. A volume created with the example `erpuser`/`erpdb`
values will ignore a later `.env` change until it is removed or the restore is
done against a database created with the new role.
