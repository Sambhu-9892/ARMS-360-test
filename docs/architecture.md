# Architecture

## 1. Why this shape

The brief was "exactly two independent business services". Before writing any
code we mapped what the monolith actually does to each domain, and the answer
constrained the design:

| Domain | Modules | Owned tables |
| --- | --- | --- |
| **Attendance** | `attendance`, `section-attendance-sessions` | `attendance_records`, `section_attendance_sessions`, holiday calendar |
| **Result** | `cas-marks`, `cas-term-marks`, `cas-weeks`, `cas-type`, `cas-core` (grading/scaling), `exam`, `marksheet`, `see-result`, `rankings` | `cas_marks`, `cas_term_marks`, `cas_weeks`, `student_exams`, `student_theory_marks`, `see_students_*`, ranking aggregates |
| **Platform** (stays with gateway) | `auth`, `users`, `roles`, `iam`, `students`, `staff`, `sections`, `subjects`, `terms`, `grades`, `schools`, `announcements`, `alerts`, `audit-logs`, `dashboard`, `bus`, `bug-reports`, `database-backups` | user/school/curriculum tables |

A third business service was rejected: the split that matches how the data is
actually shaped is two, and the remaining platform concerns are cross-cutting
rather than a third bounded context.

## 2. Runtime topology

```
                    ┌───────────────┐
 browser ──────────▶│   frontend    │  Next.js :9000
                    └───────┬───────┘
                            │ /v1/* (server-side rewrite)
                            ▼
                    ┌───────────────┐
 public :8500 ─────▶│   gateway     │  NestJS, PUBLIC
                    └───┬───────┬───┘
       owns /v1 core   │       │  proxies owned prefixes
                        ▼       ▼
        ┌──────────────────┐   ┌──────────────────┐
        │ attendance-svc   │   │  result-svc      │  internal only
        │ :3001            │   │  :3002           │
        └────────┬─────────┘   └────────┬─────────┘
                 └──────────┬───────────┘
                            ▼
                   postgres :5432   redis :6379
```

Only `gateway` and `frontend` publish ports. Postgres and Redis are reachable
only on the internal `backend` bridge network.

## 3. Request path

1. Browser calls `https://host/v1/cas-marks/weekly` with a bearer JWT.
2. Next.js rewrites `/v1/*` to the gateway (server-side), so the httpOnly
   `refresh_token` cookie stays first-party and survives a hard reload.
3. `ServiceProxyMiddleware` asks `resolveOwningService()` which service owns the
   first path segment. No match ⇒ the gateway handles it in-process.
4. `ServiceProxyService` strips `/v1`, forwards method, path, query, body and
   headers, adds `x-correlation-id`, `x-forwarded-by` and
   `x-internal-token`, and enforces a timeout.
5. The service's `InternalTokenGuard` rejects anything not arriving via the
   gateway (when the token is configured), then `ContextMiddleware` establishes
   the CLS request context and the normal guards/authorization run.
6. The response streams back, preserving status, content type and the
   correlation id.

Retries apply to **idempotent verbs only** (`GET`, `HEAD`, `OPTIONS`,
`DELETE`) and only on `502/503/504` or transport failure. `POST`, `PUT` and
`PATCH` are never retried — a duplicated marks entry or attendance write is
silent data corruption.

## 4. Data ownership: what is real and what is not

**This is the most important section in this document.**

The services are separate processes with separate build configs and separate
images. They are **not** separate databases yet. All three processes point at
one `DATABASE_URL`.

That is a deliberate, reversible Phase 1 decision, not an oversight. Four
repositories read across the domain boundary:

| File | Cross-domain access |
| --- | --- |
| `src/modules/students/infrastructure/students.repository.ts` | reads and **deletes** `attendance_records`, `cas_marks`, `cas_term_marks` |
| `src/modules/section/infrastructure/section.repository.ts` | counts and deletes `section_attendance_sessions`, `cas_marks`, `cas_term_marks` |
| `src/modules/subject/infrastructure/subject.repository.ts` | imports `cas_marks` |
| `src/modules/executive-dashboard/infrastructure/executive-dashboard.repository.ts` | joins `attendance_records` |

Deleting a student must cascade into attendance records and CAS marks. Splitting
the database before refactoring these repositories would either break student
deletion or silently orphan rows — so the schema split is sequenced **after**
the repository refactor. See `docs/migration-guide.md` §5.

`src/apps/gateway/gateway-boundary.spec.ts` asserts the *application-level*
boundary: the gateway composes no business module, and the result-side
repositories never reference an attendance table. It deliberately does not
assert transitive SQL isolation, because today that assertion would fail.

## 5. What each service may compose

**attendance-service** — `AttendanceModule`, plus the platform support it needs:
`IamModule`, `AuthModule`, `StudentsModule`, `SectionModule`, `AuditLogsModule`,
`RedisModule`, `DatabaseModule`, `ConfigModule`, `ScheduleModule`.

**result-service** — all result modules, plus `IamModule`, `AuthModule`,
`StudentsModule`, `SubjectModule`, `SectionModule`, `AuditLogsModule`,
`RedisModule`, `DatabaseModule`, `ConfigModule`, `ScheduleModule`.

**gateway** — no business module at all. It composes `IamModule`,
`AlertsModule`, `AuditLogsModule`, `S3MimeModule`, `MailModule` and
`GatewayRoutingModule`, which owns the `/v1` core route tree.

Route prefixes are remounted with Nest `RouterModule` so **zero existing
controllers changed**. That is why 63 business routes moved without touching a
single handler:

```ts
RouterModule.register([
  { path: 'attendance-records', module: AttendanceModule },
])
```

## 6. Shared libraries

`src/apps/shared/` holds what all three processes genuinely share:

| File | Purpose |
| --- | --- |
| `bootstrap.ts` | CORS, cookie parser, global validation pipe, exception filter, optional Swagger, permissions-cache warmup, static uploads, graceful shutdown |
| `service-ownership.ts` | the single source of truth for which service owns which prefix |
| `service-health.controller.ts` | dependency-aware `/health` with a subclass hook |
| `internal-token.guard.ts` | service-to-service authentication |

`service-ownership.ts` is the piece to read first — it is the routing contract
between the gateway and both services, and it is what the routing tests pin.

## 7. Health and failure behaviour

| Failure | Behaviour |
| --- | --- |
| Postgres down | Service `/health` → 503, gateway reports the dependency as down, ready-to-fail |
| Redis down | Same |
| Attendance service down | Gateway still boots and serves core routes; `/health/services` → 503; attendance prefixes → 503 with a `Retry-After` |
| Result service down | Same for result prefixes |
| Upstream slow | Abort at `UPSTREAM_TIMEOUT_MS` → 504 |
| Upstream crash mid-response | Connection resets; gateway returns 502 if nothing was written yet |

The gateway deliberately stays up when a business service is down. Core auth
and academic setup stay reachable, which matters most exactly when something has
broken.

## 8. Observability

- Every request carries `x-correlation-id`; the gateway generates one when the
  client did not supply it and echoes it on both request and response.
- `ContextMiddleware` seeds the CLS context that `AuditLogInterceptor` writes to
  the `audit_logs` table, so a mutating request through the gateway is
  attributable to a user and a service.
- Alert crons keep the monolith's schedule and run inside the service that owns
  the underlying data.

## 9. What Phase 2 changes

1. Refactor the four cross-domain repositories behind explicit interfaces.
2. Replace gateway-resident cross-domain queries with read APIs or events.
3. Provision per-service databases and schemas.
4. Move data with dual-write + backfill, then flip reads.
5. Delete the shared-database assumption from compose.

Only after step 3 does "each service owns its data" become literally true. The
process boundary in Phase 1 is what makes step 3 possible without a big-bang
rewrite.