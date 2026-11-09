# Testing

## Commands

```bash
cd ARMS-360-Backend

npm test                      # full suite
npm run test:services         # only the microservice layer (fast)
npm run test:boundary         # architectural boundary assertions
npm run check:services        # compile + test, no emit
```

Current state: **147 suites / 1147 tests passing**, of which 4 suites / 82 tests
cover the service layer.

## What the microservice tests cover

### `src/apps/gateway/routing/service-ownership.spec.ts` — 18 tests

Pins the routing contract in `service-ownership.ts`:

- every registered prefix resolves to its owning service
- `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS` all route
- `/v1` is stripped exactly once, not case-mangled
- query strings and paths survive the rewrite
- a prefix that is a *substring* of another (`/cas-marks` vs `/cas-term-marks`)
  resolves correctly — a naive `startsWith` would misroute these
- gateway-owned prefixes resolve to no service, so they stay in-process
- upstream URLs fall back to localhost defaults

### `src/apps/gateway/routing/service-proxy.service.spec.ts` — 12 tests

Runs against a **real local HTTP server**, not a mock, so the parts most likely
to break in production are actually exercised:

- JSON bodies and responses round-trip
- `multipart/form-data` is streamed through byte-for-byte, boundary intact
- status codes and headers are preserved
- query parameters are forwarded
- upstream unreachable → 503
- timeout → 504 via `AbortController`
- `x-correlation-id` is generated when absent and preserved when present
- non-idempotent verbs are **not** retried

### `src/apps/shared/internal-token.guard.spec.ts` — 10 tests

- unset or blank token ⇒ pass-through (opt-in enforcement)
- missing, wrong, short and long tokens rejected with 401
- token accepted as a header array
- `/health` and `/health/*` exempt; `/healthz` correctly **not** exempt

### `src/apps/gateway/gateway-boundary.spec.ts` — 34 tests

Architecture is enforced by test, not convention:

- exactly `attendance-service` and `result-service` exist
- the gateway composes **no** business module
- no `HealthModule` in the gateway or services, so only the shared health
  controller serves `/health`
- `StudentsRepository` contains no attendance/CAS table import
- the gateway app module imports `GatewayRoutingModule`

> **Deliberate limit.** The boundary test checks *application* composition and
> direct repository imports. It does not assert transitive SQL isolation, because
> today `SectionRepository`, `SubjectRepository` and
> `ExecutiveDashboardRepository` still cross the boundary. That gap is tracked
> in `docs/architecture.md` §4 and `docs/migration-guide.md` §5.1 — it closes
> when those repositories are refactored, and the assertion should be tightened
> then.

## Testing strategy

| Layer | Approach |
| --- | --- |
| Routing / proxy | unit + real-HTTP integration |
| Auth | token required and forwarded verbatim; guards reused from the monolith |
| Service boundaries | metadata assertions on Nest module composition |
| Business logic | untouched — inherited with its 1000+ existing tests |

Because the split changes no controller, DTO, guard or use case, the existing
suite is the regression guarantee: all 1147 tests pass unchanged against the
service composition.

## Adding a route

1. Add it to the owning module's controller.
2. If the prefix is new, add it to `SERVICE_ROUTE_PREFIXES` in
   `service-ownership.ts` and to the service's `RouterModule.register`.
3. Run `npm run test:boundary` and `npm run test:services`.
4. Regenerate `docs/api/endpoints.md`.

## Adding a third business service

The guardrail is `gateway-boundary.spec.ts` — it fails if the service count
moves away from two. That is intentional: the brief is exactly two business
services, and any change to that is a decision to make deliberately, not by
accident.

## Manual verification

Automated tests cannot prove a distributed system routes correctly end to end.
Before each release, walk the checklist in `docs/migration-guide.md` §6 —
particularly student deletion (cross-domain), attendance → dashboard, and CAS
submit/lock/unsubmit.