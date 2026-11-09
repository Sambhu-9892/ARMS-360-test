# Migration Guide

How to move from the monolith to the three-process deployment, and how to undo
it if something goes wrong.

> **Read this first.** Phase 1 keeps **one** PostgreSQL database. There is no
> data migration in Phase 1. Do not run any DDL against a production database as
> part of this rollout. The schema split is Phase 2 and is described in §5.

---

## 1. Before you start

### 1.1 Back up

```bash
# Logical, restorable, portable
docker compose exec postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  --format=custom --file=/tmp/arms360-pre-split.dump

docker cp arms360-postgres:/tmp/arms360-pre-split.dump ./arms360-pre-split.dump

# Verify the dump is actually restorable, not just present
pg_restore --list ./arms360-pre-split.dump | head
```

Keep that file until the split has run cleanly for a full academic cycle.

### 1.2 Record the baseline

```bash
curl -s localhost:8500/health            | tee /tmp/health-before.json
curl -s localhost:8500/health/services   | tee /tmp/services-before.json
```

### 1.3 Generate secrets

```bash
cp .env.example .env
openssl rand -hex 32   # -> JWT_ACCESS_SECRET
openssl rand -hex 32   # -> JWT_REFRESH_SECRET
openssl rand -hex 32   # -> INTERNAL_SERVICE_TOKEN
openssl rand -base64 24 # -> POSTGRES_PASSWORD
```

`JWT_ACCESS_SECRET` and `JWT_REFRESH_SECRET` **must** match the values the
monolith is currently using. If you let Compose generate new ones, every user is
logged out and every in-flight refresh fails. Use these exact names — the older
`JWT_ACCESS_TOKEN_SECRET` / `JWT_REFRESH_TOKEN_SECRET` spellings are not read.

### 1.4 Choose the cutover window

Attendance session reconciliation and the alert crons are scheduled jobs. Cut
over outside 08:00–18:00 NPT, and outside the 11:00 / 18:00 attendance alert
windows. Do not cut over during a term's marks-entry deadline.

---

## 2. Deploy alongside the monolith (zero downtime)

Both stacks can run at once, because they share the same database and the same
JWT secret. This is the safest way to validate the split.

```bash
# Terminal 1 — keep the monolith serving on its existing port
cd ARMS-360-Backend && docker compose up -d

# Terminal 2 — bring up the new stack on different host ports
GATEWAY_PORT=8600 FRONTEND_PORT=9100 docker compose -f docker-compose.yml up --build -d
```

Verify the new stack:

```bash
curl -s localhost:8600/health
curl -s localhost:8600/health/services          # both services must be "up"
curl -s localhost:8600/health/attendance-sessions
```

Then walk the business flows against `localhost:8600`:

- [ ] Login, refresh, logout
- [ ] Student list + student detail (these touch both domains — the highest-risk path)
- [ ] Mark attendance for one section; verify the summary and the dashboard
- [ ] Generate attendance sessions for a term
- [ ] Open the CAS weekly entry grid, edit a cell, submit, unsubmit
- [ ] Lock and unlock a CAS term mark
- [ ] Enter exam theory marks; upload a bulk template
- [ ] Generate a marksheet; open a SEE result; check rankings
- [ ] Confirm the Alerts screen and that no alert fired twice

Because both stacks share the database, any write you make through one is
visible in the other. That is what makes this rehearsal meaningful.

---

## 3. Cut over

```bash
# 1. Stop writers. Frontend first so no new requests arrive.
docker compose -f docker-compose.yml stop frontend

# 2. Confirm nothing is mid-write.
docker compose exec postgres \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "select pid, state, query from pg_stat_activity
      where datname = current_database() and state <> 'idle';"

# 3. Drain the old stack.
cd ARMS-360-Backend && docker compose stop
cd .. && docker compose -f docker-compose.yml stop frontend

# 4. Move the public port.
#    Option A (recommended): keep the new gateway on 8500 and let DNS/load
    #    balancer point at it.
#    Option B: run the new stack on the old ports.
GATEWAY_PORT=8500 FRONTEND_PORT=9000 docker compose -f docker-compose.yml up -d

# 5. Smoke test before telling anyone.
curl -sf localhost:8500/health/services && echo "services up"
curl -sfI localhost:9000/ >/dev/null && echo "frontend up"
```

Re-point DNS / the reverse proxy at the gateway's host and port. The browser
origin does not change, so no cookie or CORS change is needed.

---

## 4. Rollback

Rollback is a port flip, not a data restore — Phase 1 changed no schema.

```bash
# 1. Stop the new stack.
docker compose -f docker-compose.yml down          # keep volumes; -v would drop the DB volume

# 2. Bring the monolith back.
cd ARMS-360-Backend && docker compose up -d
```

Because both stacks share one database and one JWT secret, users are not logged
out and no data is lost.

| Symptom | Action |
| --- | --- |
| Business routes return 503 | Check `docker compose ps`; inspect the service logs; `/health/services` names the failing dependency |
| Every request 401/403 | `INTERNAL_SERVICE_TOKEN` mismatch between gateway and services |
| Random 401 after deploy | `JWT_ACCESS_SECRET` differs from the monolith's |
| Duplicate alerts | Two stacks running simultaneously — stop one (§2 warning) |
| Frontend loads, API calls fail | `BACKEND_BASE_URL` in the frontend container; check the Next.js rewrite |
| Attendance dashboard empty | The dashboard query is gateway-resident and joins `attendance_records`; confirm the shared database is actually shared |

**Never** run `docker compose down -v` on the production stack. It deletes the
Postgres volume.

---

## 5. Phase 2 — the real database split

Sequenced deliberately. Do not start it until Phase 1 has run cleanly.

### 5.1 Remove the cross-domain SQL

| Repository | Must stop doing | Replacement |
| --- | --- | --- |
| `students.repository.ts` | cascading delete into `attendance_records`, `cas_marks`, `cas_term_marks` | events (`student.deleted`) consumed by each owning service |
| `section.repository.ts` | counting/deleting `section_attendance_sessions`, `cas_*` | section detail API owned by the service holding the data |
| `subject.repository.ts` | importing `cas_marks` | result-service subject endpoint |
| `executive-dashboard.repository.ts` | joining `attendance_records` | attendance-service aggregate endpoint |
| `alerts` | crons spanning attendance + CAS + exam | one scheduler per service, each owning its reminders |

Gate each step on the boundary test:

```bash
cd ARMS-360-Backend && npm run test:boundary
```

### 5.2 Provision

```sql
CREATE ROLE attendance LOGIN PASSWORD '...';
CREATE DATABASE attendance OWNER attendance;
CREATE ROLE result     LOGIN PASSWORD '...';
CREATE DATABASE result     OWNER result;
```

Copy the schema, then copy only the owned tables:

```bash
# Attendance owns
pg_dump -d erpdb -t attendance_records -t section_attendance_sessions \
        -t '*holiday*' -Fc -f attendance.dump
pg_restore -d attendance attendance.dump

# Result owns
pg_dump -d erpdb -t cas_marks -t cas_term_marks -t cas_weeks \
        -t student_exams -t student_theory_marks -t 'see_students*' \
        -t '*ranking*' -Fc -f result.dump
pg_restore -d result result.dump
```

Confirm row counts match before switching reads:

```sql
-- Run against both databases; the numbers must be identical.
SELECT count(*) FROM attendance_records;
SELECT count(*) FROM cas_marks;
```

### 5.3 Dual-write, backfill, flip

1. Point each service at its own database; keep the monolith reading the old one.
2. Dual-write from the monolith to both destinations behind a feature flag.
3. Backfill in batches (`COPY` for bulk, not row-by-row).
4. Reconcile counts per table until they match.
5. Flip reads to the new services.
6. Drop the monolith's writes; leave them readable for one cycle.

### 5.4 Rollback for Phase 2

Keep the monolith database read-only and warm for one full term. Rollback means
flipping reads back; do not attempt a reverse data merge under time pressure.

---

## 6. Post-migration checklist

- [ ] `docker compose ps` — all six services healthy
- [ ] `curl /health/services` — both up
- [ ] Login works and `refresh_token` cookie survives a hard reload
- [ ] Student deletion cascades correctly (highest-risk cross-domain path)
- [ ] Attendance → dashboard reflects a record marked minutes earlier
- [ ] CAS submit/unsubmit/lock/unlock all behave
- [ ] Marksheet and SEE results render
- [ ] Alerts fired exactly once each
- [ ] `audit_logs` shows entries attributed to the correct service
- [ ] Postgres and Redis ports confirmed closed externally (`nmap <host>`)
- [ ] `MASTER_PASSWORD` unset in production
- [ ] `ALERT_DRY_RUN=true` reviewed before switching to real sends