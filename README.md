# ARMS360

A school management system for Deerwalk International School — rebuilt as
**exactly two business microservices** behind an API gateway, with the existing
Next.js frontend unchanged.

| Service | Responsibility | Public |
| --- | --- | --- |
| **gateway** | Routing, auth, users, roles, curriculum, schools, alerts, dashboards | Yes (`:8500`) |
| **attendance-service** | Attendance records, class registers, session reconciliation, holidays | No |
| **result-service** | CAS marks, term marks, exams, theory marks, marksheets, SEE results, rankings | No |
| frontend | Next.js app, unchanged API surface | Yes (`:9000`) |
| postgres / redis | Data and cache | No |

```
browser ──▶ frontend ──▶ gateway ──┬──▶ attendance-service ──┐
                                    └──▶ result-service ──────┴──▶ postgres, redis
```

## Quick start

```bash
cp .env.example .env      # fill in the REQUIRED values
docker compose up --build -d
docker compose ps
curl -s localhost:8500/health/services
```

Then open <http://localhost:9000>.

No schema migration is required — see [Why there is no data migration](#why-there-is-no-data-migration).

## What changed, and what did not

**Unchanged:** every URL (`/v1/**`), every request and response body, the Drizzle
schema, the JWT contract, all role and permission checks, and the frontend. Not a
single controller, DTO, guard or use case was edited to perform the split.

**Added:** three application entrypoints, a routing layer, a reverse proxy,
shared bootstrap/health/auth infrastructure, per-service build configs,
`Dockerfile.services`, and a root Compose stack.

Routes were moved by remounting existing modules with Nest `RouterModule`:

```ts
// attendance-service/attendance-app.module.ts
RouterModule.register([
  { path: 'attendance-records', module: AttendanceModule },
])
```

That is the whole migration for 63 business routes.

## Documentation

| Document | Read it when |
| --- | --- |
| [Architecture](docs/architecture.md) | Understanding the boundaries, request path, and the data-ownership caveat |
| [Migration guide](docs/migration-guide.md) | Deploying, rehearsing, rolling back, and Phase 2 |
| [Deployment](docs/deployment.md) | Builds, images, production, scaling |
| [API catalog](docs/api/endpoints.md) | Finding which service owns an endpoint |
| [Security](docs/security.md) | Trust boundaries and the pre-production checklist |
| [Observability](docs/observability.md) | Correlation ids, health, alerting |
| [Testing](docs/testing.md) | Test strategy and coverage |
| [Troubleshooting](docs/troubleshooting.md) | Something is broken |

## Repository layout

```
arms360/
├── docker-compose.yml          # all six services
├── .env.example                # documented configuration template
├── docs/
├── ARMS-360-Backend/
│   ├── Dockerfile.services     # one image definition, three services
│   ├── scripts/docker-service-entrypoint.sh
│   ├── tsconfig.app.{gateway,attendance-service,result-service}.json
│   └── src/
│       ├── apps/
│       │   ├── gateway/        # proxy, health, owned /v1 routes
│       │   ├── attendance-service/
│       │   ├── result-service/
│       │   └── shared/         # bootstrap, health, ownership, internal-token guard
│       ├── modules/            # business modules, unmodified
│       ├── routers/            # original monolith router, still intact
│       └── main.ts             # monolith entrypoint, still intact
└── ARMS-360-Frontend/          # unchanged
```

The monolith entrypoint and its `Dockerfile` / `docker-compose.yml` still work.
That is intentional: rollback is a port flip, not a code revert.

## Local development without Docker

```bash
cd ARMS-360-Backend
npm ci
npm run dev:gateway       # :3000
npm run dev:attendance    # :3001
npm run dev:result        # :3002
```

The Next.js dev server also wants port 3001 — give the services explicit `PORT`
values or run the frontend in Docker.

## Testing

```bash
cd ARMS-360-Backend
npm run check:services    # compile + service tests
npm test                  # full suite — 149 suites / 1186 tests
```

## Why there is no data migration

The brief asked for database ownership per service. Phase 1 deliberately keeps
**one** PostgreSQL database, because four repositories read across the boundary —
`students`, `section`, `subject` and `executive-dashboard` all touch both
domains, and deleting a student must cascade into attendance records *and* CAS
marks.

Splitting the database first would break student deletion or silently orphan
rows. So the order is: **separate the processes now, separate the data once the
cross-domain queries are behind interfaces.** Phase 2 is specified step by step,
with dual-write, backfill, reconciliation and rollback, in
[the migration guide](docs/migration-guide.md) §5.

The process boundary is what makes that second step incremental instead of a
big-bang rewrite.

## Security posture

- Only `gateway` and `frontend` publish ports; services and data stores are internal.
- Services require `x-internal-token`, verified in constant time, so an accidental port mapping does not expose raw endpoints.
- The caller's JWT is forwarded unchanged — the target service authorizes, so there is no token-minting surface in the gateway.
- `MASTER_PASSWORD` must be empty in production.
- `CORS_ORIGINS` must be an explicit list.

Full detail and the pre-production checklist: [docs/security.md](docs/security.md).