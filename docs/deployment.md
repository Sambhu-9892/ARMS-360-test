# Deployment

## Local development

```bash
cp .env.example .env      # fill in the REQUIRED values
docker compose up --build -d
docker compose ps
curl -s localhost:8500/health/services
```

| Service | URL | Notes |
| --- | --- | --- |
| Frontend | http://localhost:9000 | public |
| Gateway | http://localhost:8500 | the only public backend port |
| Attendance | — | internal, `:3001` on the `backend` network |
| Result | — | internal, `:3002` on the `backend` network |
| Postgres | — | internal; `docker compose exec postgres psql` |
| Redis | — | internal |
| Migrate | — | one-shot; runs the drizzle migrations, exits 0, then services start |

```bash
docker compose logs -f gateway
docker compose logs -f attendance-service
docker compose restart result-service      # independent restart, no gateway bounce
docker compose up -d --build attendance-service   # independent deploy
```

### Migrations

The `migrate` service runs `drizzle-kit migrate` once, before any backend
service starts, and every backend service declares
`depends_on: migrate: service_completed_successfully`. A failed migration
therefore stops the rollout instead of letting a half-migrated app serve
traffic.

```bash
docker compose run --rm migrate             # apply migrations manually
docker compose logs migrate                 # inspect the last run
```

The production database restored from `deerwalk_erp_backup.dump` is already
ahead of the local journal (30 applied rows vs 28 journal entries), so the
runner is a no-op there. It is still required for a fresh volume.

### Running the services without Docker

```bash
cd ARMS-360-Backend
npm run dev:gateway           # :3000
npm run dev:attendance        # :3001
npm run dev:result            # :3002
```

Point the gateway at them with `ATTENDANCE_SERVICE_URL` and
`RESULT_SERVICE_URL`, or leave the defaults, which are
`http://localhost:3001` and `http://localhost:3002`.

> The Next.js dev server also defaults to port 3001. Start the services with
> explicit `PORT` values, or run the frontend in Docker, to avoid the clash.

## Builds

Each service compiles from its own entrypoint, so TypeScript's import graph
pulls in only what it needs.

```bash
npm run build:gateway
npm run build:attendance
npm run build:result
npm run build:services      # all three
npm run check:services      # type-check all three + service tests, no emit
```

### What actually lands in each build

Isolation is **asymmetric**, and it is worth being precise about:

| Build | attendance modules | result modules |
| --- | --- | --- |
| `attendance-service` | yes | **yes** |
| `result-service` | **no** | yes |
| `gateway` | yes | yes |

`result-service` is clean: nothing it imports reaches an attendance module.

The other two are not, and that is a direct consequence of the cross-domain
dependencies in [architecture §4](architecture.md#4-data-ownership-what-is-real-and-what-is-not):

- `AttendanceModule` imports `SectionModule`, whose repository touches
  `cas_marks` and `cas_term_marks`.
- `AlertsModule` schedules attendance, CAS and exam reminders, so the gateway
  pulls in both domains.

So a deployment artifact is not yet a domain boundary. Building a smaller image
means fixing those imports first — the same prerequisite as the Phase 2 database
split.

| Script | Output |
| --- | --- |
| `build:gateway` | `dist/gateway/` |
| `build:attendance` | `dist/attendance-service/` |
| `build:result` | `dist/result-service/` |

## The image

One `Dockerfile.services` builds all three images from the same source. The
`APP` build argument selects the entry graph:

```bash
docker build -f ARMS-360-Backend/Dockerfile.services \
  --build-arg APP=result-service \
  --build-arg APP_VERSION=1.4.0 \
  -t arms360/result-service:1.4.0 .
```

At runtime `scripts/docker-service-entrypoint.sh` maps `APP` to the compiled
entrypoint, so the same image definition runs any of the three. This keeps one
Dockerfile to maintain instead of three near-identical ones.

Useful flags:

| Flag | Effect |
| --- | --- |
| `ALERT_DRY_RUN=true` | build alert payloads, do not send mail |
| `AUTO_CAPTURE_ENABLED=false` | stop turning 5xx responses into bug reports |
| `MASTER_PASSWORD=` | disable the universal-login superuser bypass |
| `UPSTREAM_RETRIES=0` | gateway only (retrying writes is never safe) |

## Production

1. `cp .env.example .env`, fill every `REQUIRED` value, and keep the file out
   of version control (`chmod 600 .env`).
2. Check the names, not just the values. The app reads `JWT_ACCESS_SECRET`,
   `JWT_REFRESH_SECRET`, `JWT_ACCESS_TTL` and `JWT_REFRESH_TTL`. The older
   `JWT_ACCESS_TOKEN_SECRET` / `JWT_REFRESH_TOKEN_SECRET` names are **not**
   read: setting only those silently leaves the app on `change-me`.
3. `docker compose config` and read the rendered output — confirm the database
   and Redis have **no** `ports:` entry.
4. `docker compose up --build -d`, then wait for the `migrate` service to exit
   `0` and for `curl -s localhost:8500/health/services` to report both
   services `up`.
5. Terminate TLS in front of the gateway and forward `X-Forwarded-*`. The
   browser origin must stay stable so the `refresh_token` cookie keeps working.
6. Watch the first deploy closely. Set `ALERT_DRY_RUN=true` until alert
   behaviour is confirmed.

### First production boot with a real database

The stack was validated against a 34 MB production dump. Two things bit us and
are worth checking before every migration:

- **Dump corruption.** A binary `pg_dump` copied through a tool that rewrites
  line endings gains a `\r` before every `\n`. `pg_restore -l` then reports
  nonsense (`Archive created at 34370-06-04`, negative TOC entries).
  Detect and repair with:

  ```bash
  python3 - <<'EOF'
  from pathlib import Path
  p = Path('deerwalk_erp_backup.dump')
  data = p.read_bytes()
  assert data.count(b'\r\n') == data.count(b'\n')  # systematic CRLF
  p.with_suffix('.fixed.dump').write_bytes(data.replace(b'\r\n', b'\n'))
  EOF
  ```

- **Fresh volume credentials.** The Postgres named volume initialises
  `POSTGRES_USER`/`POSTGRES_DB` only on first boot. If the volume was created
  with the example `erpuser`/`erpdb` values, changing `.env` will not change
  the existing cluster. Remove the volume (after backing up) or restore into a
  new database explicitly:

  ```bash
  docker compose exec -T postgres dropdb -U postgres --if-exists deerwalk_erp
  docker compose exec -T postgres createdb -U postgres deerwalk_erp
  docker compose exec -T postgres pg_restore -U postgres -d deerwalk_erp \
    --no-owner --no-privileges --exit-on-error < deerwalk_erp.fixed.dump
  ```

### Reverse proxy and TLS

Only two host ports are published: `${FRONTEND_PORT:-9000}` and
`${GATEWAY_PORT:-8500}`. Put nginx (or Caddy) in front and give it the
certificates; nothing inside the stack terminates TLS.

```nginx
# /etc/nginx/sites-available/arms360
server {
    listen 443 ssl http2;
    server_name arms360.deerwalk.edu.np;

    ssl_certificate     /etc/letsencrypt/live/arms360.deerwalk.edu.np/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/arms360.deerwalk.edu.np/privkey.pem;

    # Next.js app + the same-origin /v1 rewrite (keep the prefix).
    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 443 ssl http2;
    server_name arms360-backend.deerwalk.edu.np;

    ssl_certificate     /etc/letsencrypt/live/arms360-backend.deerwalk.edu.np/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/arms360-backend.deerwalk.edu.np/privkey.pem;

    client_max_body_size 25m;   # bulk marksheet / theory-marks uploads

    location / {
        proxy_pass http://127.0.0.1:8500;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;  # marksheet generation can exceed 60s
    }
}
```

Then set the frontend build-time values in `.env` and rebuild:

```bash
NEXT_PUBLIC_API_BASE_URL=
NEXT_PUBLIC_BACKEND_BASE_URL=https://arms360-backend.deerwalk.edu.np
CORS_ORIGINS=https://arms360.deerwalk.edu.np
FRONTEND_URL=https://arms360.deerwalk.edu.np
```

`BACKEND_BASE_URL` stays `http://gateway:3000` in compose: it is baked into the
Next.js routes manifest and must resolve **inside** the container network.

> The route manifest is generated by `next build`. Changing
> `NEXT_PUBLIC_BACKEND_BASE_URL` or `BACKEND_BASE_URL` requires rebuilding the
> frontend image — `docker compose restart frontend` will not pick it up.

### Deploying images without compose's cache

`podman-compose` (used by the `docker` shim on this host) will happily reuse an
old container even after the image tag changed. If a code change does not
appear:

```bash
docker compose up -d --force-recreate --no-deps result-service
podman inspect arms360-result-service --format '{{.Image}}'
podman images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep result-service
```

The two IDs must match. `podman rm -f` on a container that others depend on
fails with `has dependent containers which must be removed before it`; use
`--force-recreate` instead of hand-removing containers.

The compose file is production-oriented: `restart: unless-stopped`, named
volumes for the database, Redis AOF and uploads, health checks on every
container, and `TZ` pinned so scheduled jobs fire at the right local hour.

### Backups

```bash
# Nightly logical backup
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  --format=custom > "backup-$(date +%F).dump"
```

Test the restore into a scratch database on a schedule. An untested backup is a
guess.

### Upgrades

```bash
APP_VERSION=1.5.0 docker compose up --build -d
```

Bump `APP_VERSION` per release so a running container identifies itself and a
rollback is a re-tag of the previous image.

## Scaling

The two business services scale independently and need no gateway change:

```bash
docker compose up -d --scale attendance-service=3
```

`ServiceProxyService` picks a URL from `ATTENDANCE_SERVICE_URL`; for real load
balancing, point it at a DNS name or an nginx upstream that round-robins
between replicas.

## Security posture

- Only the gateway and frontend publish ports; the services and data stores are
  internal.
- Services require `x-internal-token` when `INTERNAL_SERVICE_TOKEN` is set, so
  an accidental port mapping does not expose raw endpoints.
- Compose refuses to start without that token and without the JWT secrets.
- `MASTER_PASSWORD` must be empty in production.
- `CORS_ORIGINS` must be an explicit list — `credentials: true` and `*` do not
  combine, so a wildcard would silently break auth.

See `docs/security.md`.

## Troubleshooting

`docs/troubleshooting.md` covers the failure modes worth knowing before an
incident: 503s from the gateway, 401s that only happen in Docker, upload paths,
duplicate alerts, and empty dashboards.