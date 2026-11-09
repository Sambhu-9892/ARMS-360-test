# Observability

## Correlation ids

Every response carries `x-correlation-id`:

- If the client supplied one, it is reused.
- Otherwise the gateway generates it.
- It is forwarded upstream and echoed on the response, including errors.

It appears in the proxy log line, the service log line, and `audit_logs`. One
id therefore spans the browser request, the gateway hop and the service — which
is what makes a slow or failing call traceable without correlating timestamps
by hand.

```bash
# Follow one request end to end
CID=$(curl -sD - -o /dev/null localhost:8500/v1/cas-marks/weekly \
      -H "Authorization: Bearer $TOKEN" | grep -i x-correlation-id | tr -d '\r' | cut -d' ' -f2)

docker compose logs gateway | grep "$CID"
docker compose logs result-service | grep "$CID"
docker compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "select created_at, method, path, status_code, user_id from audit_logs
      where correlation_id = '$CID';"
```

## Health endpoints

| Endpoint | Reports | Use for |
| --- | --- | --- |
| `GET /health` (gateway) | Postgres + Redis; upstream states in the body without failing the gateway | liveness, load balancer |
| `GET /health/services` (gateway) | per-service reachability and latency; **503** if either is down | readiness, alerting |
| `GET /health` (attendance) | Postgres + Redis | container health check |
| `GET /health/attendance-sessions` | open / unreconciled session counts | domain-level signal |
| `GET /health` (result) | Postgres + Redis | container health check |

The gateway staying healthy while a business service is down is intentional:
auth and academic setup stay reachable during an incident, and
`/health/services` is the endpoint that tells you what is actually broken.

## Structured logging

The Nest logger is used throughout, with the correlation id on request-scoped
entries and the service name in every line. Query by service:

```bash
docker compose logs -f result-service
docker compose logs --since 15m gateway | grep '"level":"error"'
```

## Metrics

No Prometheus exporter ships yet. The practical signals today are:

| Signal | Source |
| --- | --- |
| Request rate / errors | reverse-proxy or load-balancer access logs, keyed on `x-correlation-id` |
| Upstream latency | gateway log timing per hop |
| Error rate per service | `502` / `503` / `504` counts in the proxy logs |
| Dependency health | `/health`, `/health/services` |
| Domain integrity | `/health/attendance-sessions` |
| Business activity | `audit_logs` |
| Alert delivery | alert run history in the Alerts screen |

## Alerting recommendations

| Condition | Severity |
| --- | --- |
| `/health` down on any container | page |
| `/health/services` 503 | page |
| 5xx rate > 1% over 5 min | page |
| 504 rate > 0.5% over 5 min | ticket |
| unreconciled attendance sessions > 0 after 06:00 NPT | ticket |
| Postgres volume growth > 80% | ticket |

## Known gaps

- No distributed tracing. Correlation ids tie logs together, but there is no
  span-level view; adding OpenTelemetry to `ServiceProxyService` and the shared
  bootstrap is the natural next step.
- No metrics exporter. The health endpoints are the machine-readable surface
  available today.
- Alert delivery failures are visible in the Alerts screen, not in
  infrastructure monitoring.

These are deliberately left as follow-ups rather than half-implemented here.