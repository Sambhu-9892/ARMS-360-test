# Security

## Trust boundaries

```
  untrusted          DMZ                    internal              data
  browser ─────▶ gateway ─────▶ attendance-service ─┐
                     │                              ├──▶ postgres
                     └────▶ result-service ─────────┤
                                                    └──▶ redis
```

Everything to the right of the gateway is assumed to be inside the perimeter.
The controls below make that assumption explicit rather than implicit.

## 1. Only the gateway is public

`docker-compose.yml` publishes exactly two ports: `frontend` and `gateway`.
Postgres, Redis, and both business services have no `ports:` entry, so they are
reachable only from the `backend` bridge network.

Verify from outside the host:

```bash
nmap -p 5432,6379,3001,3002 <host>     # expect: filtered
```

## 2. Service-to-service authentication

"Not reachable from the internet" is a network control, not authorization. With
`INTERNAL_SERVICE_TOKEN` set, each business service requires the header:

- The gateway presents it in `x-internal-token` on every proxied request.
- `InternalTokenGuard` verifies it in **constant time**
  (`crypto.timingSafeEqual`), length-checked first.
- `/health*` is exempt so orchestrators can probe without holding the secret. It
  exposes only dependency reachability and record counts — never student data.
- Enforcement is opt-in: an empty token disables the guard. Compose requires the
  variable, so the deployed stack always has it on.

If the token is ever leaked, rotate it and restart all three processes:

```bash
openssl rand -hex 32
docker compose up -d --force-recreate
```

## 3. Authentication and authorization

- The caller's JWT is forwarded unchanged; the target service runs the guard.
  The gateway does **not** mint its own tokens, so there is one authority for
  authentication and no token-forgery surface in the gateway.
- All three processes must share `JWT_ACCESS_SECRET` and
  `JWT_REFRESH_SECRET` (the names read by `auth.config.ts`; the older
  `JWT_ACCESS_TOKEN_SECRET` / `JWT_REFRESH_TOKEN_SECRET` spellings are ignored,
  and the app falls back to `change-me` when only they are present). A mismatch
  means proxied requests fail closed, and a fallback secret is a full auth
  bypass. Verify with:

  ```bash
  docker compose exec gateway printenv JWT_ACCESS_SECRET | wc -c   # > 64
  ```
- Roles and permissions are unchanged from the monolith; the boundary tests in
  `src/apps/gateway/gateway-boundary.spec.ts` guard against a business module
  being reintroduced into the gateway composition and against a service
  controller being mounted at `/` (which would shadow single-segment routes).
- Secrets that were shared in plaintext while migrating to this repository
  (database password, Gmail app password, GitHub PAT, ImageKit keys) must be
  rotated before the first public deploy. Rotating the JWT secrets logs every
  user out.

## 4. `MASTER_PASSWORD` is a superuser bypass

When set, this single password logs in **any** role — super admin, principal,
teacher, student — for any valid identifier. It is commented out in
`.env.example` and must be empty in production:

```bash
docker compose exec gateway printenv MASTER_PASSWORD   # expect empty
```

## 5. CORS

`CORS_ORIGINS` is an explicit comma-separated list. `credentials: true` is
required for the httpOnly `refresh_token` cookie, and browsers reject `*`
alongside credentials — a wildcard therefore breaks auth rather than widening it.
Never set `CORS_ORIGINS=*`.

## 6. Secrets handling

- Secrets come from environment variables only; nothing is baked into images.
- `.env` is gitignored. Populate `.env.example` and commit that instead.
- Rotate `JWT_*_SECRET` to invalidate all sessions (users log in again).
- Restrict Postgres and Redis network access in the production platform
  (security groups, firewall rules), not just in Compose.

## 7. Data in transit

Compose runs plain HTTP on the internal network, which is the normal posture for
a single-host deployment where services share a host. Terminate TLS in front of
the gateway and keep the browser origin stable so the refresh cookie stays
first-party. If the services ever leave the host, enable TLS between them and
stop using plain `http://` upstream URLs.

## 8. Input validation

The shared bootstrap applies the global `ValidationPipe` with whitelist and
transform, so DTO validation is identical across all three processes and Drizzle
receives typed values. Proxied bodies are validated by the target service, not by
the gateway — the gateway is a router and does not duplicate that logic.

## 9. Audit trail

`AuditLogInterceptor` writes mutating requests to `audit_logs` using the CLS
request context established by `ContextMiddleware`, which the gateway runs
before proxying. `x-correlation-id` ties a user action in the browser to the
service-side log line and to the gateway entry.

## Pre-production checklist

- [ ] `INTERNAL_SERVICE_TOKEN` set and identical on all three processes
- [ ] `MASTER_PASSWORD` empty
- [ ] `CORS_ORIGINS` lists exact origins, no `*`
- [ ] Postgres/Redis ports unreachable externally (`nmap` check recorded)
- [ ] `ALERT_DRY_RUN=true` for the first deploy, then reviewed
- [ ] `.env` not committed; `.env.example` is the tracked template
- [ ] TLS terminated in front of the gateway; `X-Forwarded-*` forwarded
- [ ] Database backup taken **and restore-tested**
- [ ] Secrets rotated if this stack is ever exposed