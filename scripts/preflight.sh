#!/usr/bin/env bash
# Friendly preflight for `docker compose up`, run before it.
#
# Why this exists: on podman, `docker compose` is a shim over podman-compose,
# which reports a missing variable as a Python traceback ending in
#   ValueError: required variable POSTGRES_USER is missing a value
# That reads like a compose bug rather than "you have no .env file". This script
# turns that into one line of actionable output.
#
# Usage:  ./scripts/preflight.sh          # check only
#         ./scripts/preflight.sh --fix    # create .env from .env.example with
#                                         # freshly generated secrets
#
# Safe to run repeatedly. Never prints a secret value.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"
REQUIRED=(POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB
          JWT_ACCESS_TOKEN_SECRET JWT_REFRESH_TOKEN_SECRET INTERNAL_SERVICE_TOKEN)

bold=$'\033[1m'; red=$'\033[31m'; yellow=$'\033[33m'; green=$'\033[32m'; dim=$'\033[2m'; off=$'\033[0m'
if [ ! -t 1 ]; then bold=""; red=""; yellow=""; green=""; dim=""; off=""; fi

fail() { printf '%sERROR%s %s\n' "$red" "$off" "$1" >&2; }
warn() { printf '%swarn%s  %s\n'  "$yellow" "$off" "$1"; }
ok()   { printf '%sok%s    %s\n'  "$green" "$off" "$1"; }

gen_hex()  { openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
gen_pass() { openssl rand -base64 24 2>/dev/null | tr -d '\n=' || head -c 24 /dev/urandom | base64 | tr -d '\n='; }


# ------------------------------------------------------- required values
# env_value VAR -> the value in .env, or "" if absent/blank/whitespace-only
env_value() {
  grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- \
    | sed -e 's/[[:space:]]//g'
}

fix_requested() { [ "${1:-}" = "--fix" ]; }

if [ ! -f "$ENV_FILE" ]; then
  if fix_requested "$@"; then
    cp .env.example "$ENV_FILE"
    ok "created $ENV_FILE from .env.example"
    missing=("${REQUIRED[@]}")
  else
    fail "$ENV_FILE does not exist."
    printf '  %s\n' "docker compose reads it for the required secrets, and on"
    printf '  %s\n' "podman that surfaces as an unhelpful Python traceback."
    printf '\n  Fix:  cp .env.example .env\n'
    printf '  Or:   ./scripts/preflight.sh --fix\n\n'
    exit 1
  fi
else
  ok "$ENV_FILE exists"
  missing=()
  for var in "${REQUIRED[@]}"; do
    [ -n "$(env_value "$var")" ] || missing+=("$var")
  done
fi

# --fix also covers a half-filled .env, which is the more common case.
if [ ${#missing[@]} -gt 0 ] && fix_requested "$@"; then
  command -v openssl >/dev/null \
    || { fail "openssl not found; install it, or fill these in manually:"; printf '  %s\n' "${missing[@]}"; exit 1; }

  # Defaults for the non-secret required names come from .env.example so the
  # stack still starts; secrets are always random.
  declare -A gen=(
    [POSTGRES_PASSWORD]="$(gen_pass)"
    [JWT_ACCESS_TOKEN_SECRET]="$(gen_hex)"
    [JWT_REFRESH_TOKEN_SECRET]="$(gen_hex)"
    [INTERNAL_SERVICE_TOKEN]="$(gen_hex)"
  )

  for var in "${missing[@]}"; do
    value="${gen[$var]:-}"
    if [ -z "$value" ]; then
      value="$(grep -E "^${var}=" .env.example | head -1 | cut -d= -f2-)"
    fi
    if [ -z "$value" ]; then
      fail "cannot auto-fill $var; set it by hand"
      continue
    fi
    # Secrets may contain / and +, so use a delimiter that cannot appear.
    if grep -qE "^${var}=" "$ENV_FILE"; then
      sed -i "s|^${var}=.*|${var}=${value}|" "$ENV_FILE"
    else
      printf '%s=%s\n' "$var" "$value" >> "$ENV_FILE"
    fi
    ok "set $var"
  done

  chmod 600 "$ENV_FILE"
  printf '  %s\n' "Keep these values when you deploy, or every user will be"
  printf '  %s\n' "logged out on the first restart."
  missing=()
  for var in "${REQUIRED[@]}"; do
    [ -n "$(env_value "$var")" ] || missing+=("$var")
  done
fi

if [ ${#missing[@]} -gt 0 ]; then
  for var in "${missing[@]}"; do fail "$var has no value in $ENV_FILE"; done
  printf '\n  Generate one with:  openssl rand -hex 32\n'
  printf '  Or auto-fill every blank:  ./scripts/preflight.sh --fix\n\n'
  exit 1
fi
ok "all ${#REQUIRED[@]} required variables are set"

# --------------------------------------------------------- compose file
if [ ! -f "$COMPOSE_FILE" ]; then fail "$COMPOSE_FILE not found"; exit 1; fi

if command -v python3 >/dev/null && [ -f scripts/validate-compose.py ]; then
  if out="$(python3 scripts/validate-compose.py 2>&1)"; then
    printf '%s\n' "$out" | tail -1 | sed 's/^/  /'
    ok "compose validates"
  else
    printf '%s\n' "$out" >&2
    fail "compose validation failed"
    exit 1
  fi
fi

# ------------------------------------------------------------- runtime
if command -v docker >/dev/null; then
  if docker --version 2>&1 | grep -qi podman; then
    printf '\n%snote%s  `docker` is a podman shim here, using podman-compose.\n' "$dim" "$off"
    printf '%s      %s\n' "$dim" "podman-compose is a partial implementation. If it"
    printf '%s      %s\n' "$dim" "errors on depends_on/conditions or build args,"
    printf '%s      %s\n' "$dim" "build and run the images directly instead:"
    printf '\n        %spodman build -f ARMS-360-Backend/Dockerfile.services \\\n' "$dim"
    printf '%s          --build-arg APP=result-service -t arms360/result-service .\n\n' "$dim"
  fi
fi

printf '\n%s%sReady.%s  docker compose up --build -d\n\n' "$bold" "$green" "$off"