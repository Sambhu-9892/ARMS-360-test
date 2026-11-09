#!/usr/bin/env python3
"""
Validate docker-compose.yml without needing Docker installed.

`docker compose config` is the source of truth when Docker is available, but it
is unavailable on some machines (and podman-compose is a partial implementation
that mishandles `depends_on: condition:` and YAML anchors). This script performs
the same checks CI depends on, using only the standard library.

It verifies:

  1. the file parses as YAML
  2. all REQUIRED (`:?`) variables are set or defaulted
  3. exactly the expected services are present
  4. only the intended services publish host ports
  5. every backend service resolves the variables it interpolates

Usage:
    python3 scripts/validate-compose.py [--env-file .env] [path]

Exit code is 0 when valid, 1 otherwise, so it can gate a pre-commit hook or CI.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")

EXPECTED_SERVICES = {
    "gateway",
    "attendance-service",
    "result-service",
    "frontend",
    "migrate",
    "postgres",
    "redis",
}

# The only services allowed to publish a host port.
MAY_PUBLISH_PORTS = {"gateway", "frontend"}

# Services that must interpolate cleanly - catches typos in variable names,
# which Compose would otherwise silently render as an empty string.
BACKEND_SERVICES = ("gateway", "attendance-service", "result-service")

_VAR = re.compile(r"\$\{([A-Z_][A-Z_0-9]*)(:-([^}]*))?\}")
_VAR_REQUIRED = re.compile(r"\$\{([A-Z_][A-Z_0-9]*):\?[^}]*\}")
# `${NAME:-}` means "default to empty" and is NOT a required variable.
_VAR_OPTIONAL_EMPTY = re.compile(r"\$\{([A-Z_][A-Z_0-9]*):-\}")


def load_env_file(path: Path) -> dict[str, str]:
    """Minimal .env reader: KEY=VALUE, `#` comments, optional quotes."""
    values: dict[str, str] = {}
    if not path.is_file():
        return values

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def required_names(text: str) -> set[str]:
    """Required names minus the ones that have an explicit empty default."""
    optional = set(_VAR_OPTIONAL_EMPTY.findall(text))
    return set(_VAR_REQUIRED.findall(text)) - optional


def substitute(text: str, env: dict[str, str], errors: list[str]) -> str:
    def replace(match: re.Match[str]) -> str:
        name = match.group(1)
        if name in env:
            return env[name]
        default = match.group(3)
        if default is not None:
            return default
        errors.append(f"unset variable with no default: ${{{name}}}")
        return ""

    return _VAR.sub(replace, text)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compose_file", nargs="?", default="docker-compose.yml")
    parser.add_argument(
        "--env-file",
        default=".env",
        help="optional .env to source values from (default: .env if present)",
    )
    args = parser.parse_args()

    compose_path = Path(args.compose_file)
    if not compose_path.is_file():
        sys.exit(f"not found: {compose_path}")

    env = dict(load_env_file(Path(args.env_file)))
    # Real environment wins over the file, matching Compose precedence.
    env.update(os.environ)

    raw = compose_path.read_text(encoding="utf-8")
    errors: list[str] = []

    missing = required_names(raw)
    for name in sorted(missing):
        if name not in env or env[name] == "":
            errors.append(f"REQUIRED variable is not set: {name}")

    if errors:
        for err in errors:
            print(f"  ERROR  {err}", file=sys.stderr)
        print(
            f"\n{len(errors)} problem(s). See .env.example for the template.",
            file=sys.stderr,
        )
        return 1

    rendered = substitute(raw, env, errors)
    if errors:
        for err in errors:
            print(f"  ERROR  {err}", file=sys.stderr)
        return 1

    config = yaml.safe_load(rendered)
    services = config.get("services", {})

    problems = 0

    got = set(services)
    if got != EXPECTED_SERVICES:
        problems += 1
        print(
            f"  ERROR  service set mismatch: "
            f"unexpected={sorted(got - EXPECTED_SERVICES)} "
            f"missing={sorted(EXPECTED_SERVICES - got)}"
        )

    for name, spec in services.items():
        ports = spec.get("ports")
        if ports and name not in MAY_PUBLISH_PORTS:
            problems += 1
            print(f"  ERROR  {name} publishes a host port: {ports}")
        elif ports:
            print(f"  ok     {name} publishes {ports}")

        # One-shot services (restart: "no") exit by design: no healthcheck.
        one_shot = str(spec.get("restart", "")).lower() == "no"
        modes = ("restart",) if one_shot else ("restart", "healthcheck")
        for mode in modes:
            if not spec.get(mode):
                problems += 1
                print(f"  WARN   {name} has no {mode}")

    for name in BACKEND_SERVICES:
        service_env = services.get(name, {}).get("environment", {})
        for key in ("DATABASE_URL", "REDIS_HOST", "INTERNAL_SERVICE_TOKEN", "APP", "PORT"):
            if key not in service_env:
                problems += 1
                print(f"  ERROR  {name} is missing {key}")

    apps = {services[n]["environment"]["APP"] for n in BACKEND_SERVICES if n in services}
    if apps != {"gateway", "attendance-service", "result-service"}:
        problems += 1
        print(f"  ERROR  APP values do not match service names: {sorted(apps)}")

    for volume in ("postgres-data", "redis-data"):
        if volume not in config.get("volumes", {}):
            problems += 1
            print(f"  ERROR  persistent volume missing: {volume}")

    if problems:
        print(f"\n{problems} problem(s) found.", file=sys.stderr)
        return 1

    print(f"\ncompose OK: {len(services)} services, only "
          f"{sorted(MAY_PUBLISH_PORTS)} reachable from the host")
    return 0


if __name__ == "__main__":
    sys.exit(main())