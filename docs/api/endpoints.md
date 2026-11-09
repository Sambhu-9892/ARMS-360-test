# API Endpoint Catalog

Generated from the Nest controller metadata. Every route below is reachable
through the gateway at `/v1/...`; the gateway strips `/v1` and forwards to the
owning service.

Regenerate with:

```bash
cd ARMS-360-Backend && npm run build:services   # metadata is compile-time
```

## Conventions

- **Auth** — every `/v1/**` route except `/health*` requires a bearer JWT.
  The gateway forwards the caller `Authorization` header unchanged and the
  target service performs the guard + role checks.
- **Envelopes** — single resources return the object; collections return
  `{ data, meta }` where pagination applies; errors return
  `{ statusCode, error, message, timestamp, path }`.
- **Gateway errors** — `502` upstream crashed / non-JSON reply, `503` upstream
  unreachable or timed out after retries, `504` upstream timeout. All carry
  `x-correlation-id`.

## Attendance Service

Attendance records, per-class registers, daily session reconciliation and holiday calendars.

**10 routes**

Public prefix: `/v1/attendance-records`  →  upstream `attendance-records/*`

| Method | Public path |
| --- | --- |
| `GET` | `/v1/attendance-records/attendance/class/:section_id` |
| `GET` | `/v1/attendance-records/attendance/class/:section_id/summary` |
| `GET` | `/v1/attendance-records/attendance/holiday-dates` |
| `POST` | `/v1/attendance-records/attendance/record` |
| `PUT` | `/v1/attendance-records/attendance/record/:record_id` |
| `GET` | `/v1/attendance-records/attendance/records` |
| `GET` | `/v1/attendance-records/attendance/records/:id` |
| `DELETE` | `/v1/attendance-records/attendance/records/:id` |
| `GET` | `/v1/attendance-records/attendance/sessions` |
| `POST` | `/v1/attendance-records/attendance/sessions/generate` |

## Result Service

Continuous assessment (CAS), term marks, exams, theory marks, marksheets, SEE results and rankings.

**53 routes**

| Method | Public path |
| --- | --- |
| `GET` | `/v1//` |
| `POST` | `/v1//` |
| `PATCH` | `/v1//:casTermMarkId` |
| `DELETE` | `/v1//:casTermMarkId` |
| `POST` | `/v1//:casTermMarkId/lock` |
| `POST` | `/v1//:casTermMarkId/unlock` |
| `GET` | `/v1//:id` |
| `PUT` | `/v1//:id` |
| `PATCH` | `/v1//:id` |
| `DELETE` | `/v1//:id` |
| `GET` | `/v1//analytics-overview` |
| `GET` | `/v1//annual` |
| `PATCH` | `/v1//batch` |
| `DELETE` | `/v1//batch` |
| `GET` | `/v1//batch-summary` |
| `POST` | `/v1//bulk` |
| `GET` | `/v1//comparison` |
| `POST` | `/v1//finalize` |
| `POST` | `/v1//generate` |
| `GET` | `/v1//generation-status` |
| `GET` | `/v1//generation-status/students` |
| `GET` | `/v1//grade` |
| `GET` | `/v1//grade-distribution` |
| `GET` | `/v1//pending-alerts` |
| `GET` | `/v1//selectable-terms` |
| `GET` | `/v1//student` |
| `GET` | `/v1//student-progress` |
| `GET` | `/v1//student-result` |
| `GET` | `/v1//student-subject-performance` |
| `GET` | `/v1//student-subject-progress` |
| `GET` | `/v1//student/:studentDetailId/marks-breakdown` |
| `GET` | `/v1//subjects` |
| `PUT` | `/v1//subjects` |
| `GET` | `/v1//template` |
| `POST` | `/v1//template/upload` |
| `GET` | `/v1//term-grade/:termGradeId` |
| `GET` | `/v1//term-grade/:termGradeId/subjects/:subjectId/sections/:sectionId/marks-matrix` |
| `GET` | `/v1//term-grade/:termGradeId/weeks-overview` |
| `GET` | `/v1//theory-marks` |
| `POST` | `/v1//theory-marks` |
| `POST` | `/v1//theory-marks/bulk` |
| `GET` | `/v1//theory-marks/bulk/template` |
| `POST` | `/v1//theory-marks/bulk/template/upload` |
| `GET` | `/v1//view-groups` |
| `GET` | `/v1//week-status` |
| `GET` | `/v1//week/:casWeekId/sections-summary` |
| `GET` | `/v1//week/:casWeekId/uss/:ussId` |
| `DELETE` | `/v1//week/:casWeekId/uss/:ussId/entry/:entryNo` |
| `GET` | `/v1//week/:casWeekId/uss/:ussId/entry/:entryNo/students` |
| `POST` | `/v1//week/:casWeekId/uss/:ussId/submit` |
| `POST` | `/v1//week/:casWeekId/uss/:ussId/unsubmit` |
| `POST` | `/v1//weekly` |
| `PATCH` | `/v1//weekly` |

## Gateway-owned routes (not proxied)

These are served in-process by the gateway so that core platform concerns do
not require a round trip:

- `/v1/auth/**` — login, refresh, logout, password reset
- `/v1/users/**`, `/v1/roles/**` — identity and access management
- `/v1/academic-years/**`, `/v1/terms/**`, `/v1/grades/**`
- `/v1/schools/**`, `/v1/school-levels/**`
- `/v1/students/**`, `/v1/staff/**`
- `/v1/departments/**`, `/v1/sections/**`, `/v1/subjects/**`
- `/v1/user-subject-sections/**` — teaching assignments
- `/v1/bus/**` — transport
- `/v1/announcements/**`, `/v1/audit-logs/**`
- `/v1/dashboard/**` — executive dashboards
- `/v1/bug-reports/**`
- `/v1/database-backups/**`
- `/v1/alerts/**` — alert settings and history (see caveat below)
- `/uploads/**` — static file serving

> **Cross-domain caveat.** `students`, `sections` and `subjects` currently
> query tables owned by both domains, and the alerts module schedules crons
> for attendance, CAS and exam reminders. They are gateway-resident in this
> phase because they are genuinely cross-cutting; the physical database split
> in `docs/migration-guide.md` is what removes them from the gateway.

## Health endpoints

| Endpoint | Served by | Notes |
| --- | --- | --- |
| `/health` | gateway | Postgres + Redis reachability. Upstream failures are reported in the body but do not fail the gateway. |
| `/health/services` | gateway | Probes both services. `503` when either is unreachable. |
| `/health` | attendance-service | Postgres + Redis + session reconciliation state. |
| `/health/attendance-sessions` | attendance-service | Deep probe: counts open/unreconciled sessions. |
| `/health` | result-service | Postgres + Redis. |

Total business routes owned by the two services: **63**.
