#!/usr/bin/env bash
# Kitty — one-command dev startup
#
# Usage:
#   ./start.sh              Boot TigerBeetle + backend; print Expo hint
#   ./start.sh --mobile     ... and start Expo in the foreground
#   ./start.sh --check      Preflight only (no services started)
#   ./start.sh --reset      Tear down TB data before starting (fresh ledger)
#
# Env:
#   SKIP_DEPS=1             Skip pip/npm install
#   SKIP_MIGRATE=1          Skip db migrations
#   BACKEND_PORT=8000       Override port (matches backend/.env)

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Colors + logging
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'
  C_CYA=$'\033[36m'
else
  C_RESET='' C_DIM='' C_BOLD='' C_RED='' C_GRN='' C_YEL='' C_BLU='' C_CYA=''
fi

log()  { printf "%s[kitty]%s %s\n" "$C_CYA" "$C_RESET" "$*"; }
ok()   { printf "%s[kitty]%s %s%s%s\n" "$C_GRN" "$C_RESET" "$C_GRN" "$*" "$C_RESET"; }
warn() { printf "%s[kitty]%s %s%s%s\n" "$C_YEL" "$C_RESET" "$C_YEL" "$*" "$C_RESET"; }
die()  { printf "%s[kitty]%s %s%s%s\n" "$C_RED" "$C_RESET" "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
section() { printf "\n%s══ %s%s\n" "$C_BOLD" "$*" "$C_RESET"; }

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$REPO_ROOT/.kitty-run"
mkdir -p "$LOG_DIR"
BACKEND_LOG="$LOG_DIR/backend.log"
BACKEND_PIDFILE="$LOG_DIR/backend.pid"

# ─────────────────────────────────────────────────────────────────────────────
# Args
# ─────────────────────────────────────────────────────────────────────────────
WITH_MOBILE=0
CHECK_ONLY=0
RESET_TB=0
for arg in "$@"; do
  case "$arg" in
    --mobile)  WITH_MOBILE=1 ;;
    --check)   CHECK_ONLY=1 ;;
    --reset)   RESET_TB=1 ;;
    -h|--help)
      sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "unknown flag: $arg (try --help)" ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Preflight — verify prerequisites
# ─────────────────────────────────────────────────────────────────────────────
section "preflight"

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing: $1 — $2"
}

need docker  "install Docker Desktop (https://www.docker.com/products/docker-desktop)"
need node    "install Node 20+ (https://nodejs.org)"
need npm     "comes with Node"

docker info >/dev/null 2>&1 || die "Docker daemon is not running — start Docker Desktop and retry"
ok "docker running"

# Find the newest Python >=3.12 on PATH. pyproject.toml requires 3.12+.
# Order: explicit $PYTHON env override → python3.13 → python3.12 → python3.
PYTHON_BIN=""
for candidate in "${PYTHON:-}" python3.13 python3.12 python3; do
  [[ -z "$candidate" ]] && continue
  if command -v "$candidate" >/dev/null 2>&1; then
    ver=$("$candidate" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)
    if [[ "$ver" == "3.12" || "$ver" == "3.13" || "$ver" == "3.14" ]]; then
      PYTHON_BIN="$(command -v "$candidate")"
      ok "python $ver ($PYTHON_BIN)"
      break
    fi
  fi
done
if [[ -z "$PYTHON_BIN" ]]; then
  die "no Python 3.12+ found — install via 'brew install python@3.12' or set PYTHON=/path/to/python3.12"
fi
export PYTHON_BIN

node_ver=$(node -v | sed 's/v//' | cut -d. -f1)
if (( node_ver < 18 )); then
  warn "node v$node_ver — 20+ recommended for Expo"
else
  ok "node v$node_ver"
fi

# .env check — warn on missing, don't fatal (so devs can still start TB + Expo for offline work)
if [[ ! -f "$REPO_ROOT/.env" ]]; then
  warn ".env not found — copying from .env.example (fill in secrets before features work)"
  cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"
fi

check_env_var() {
  local name="$1"
  local val
  val=$(grep -E "^${name}=" "$REPO_ROOT/.env" 2>/dev/null | cut -d= -f2- || true)
  if [[ -z "$val" ]]; then
    warn "  $name is empty — expect 5xx on related routes"
  else
    ok  "  $name set"
  fi
}

log "inspecting .env:"
check_env_var SUPABASE_URL
check_env_var SUPABASE_SERVICE_ROLE_KEY
check_env_var ANTHROPIC_API_KEY
# bunq is optional now — multi-user contexts live outside .env
if grep -q "^BUNQ_API_KEY=.\+" "$REPO_ROOT/.env" 2>/dev/null; then
  ok "  BUNQ_API_KEY set (optional)"
else
  log "  BUNQ_API_KEY empty — use ${C_BOLD}make bunq-bootstrap${C_RESET} to mint sandbox users"
fi

if (( CHECK_ONLY )); then
  ok "preflight passed — exiting (--check)"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Dependencies
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "${SKIP_DEPS:-}" ]]; then
  section "installing dependencies"
  if [[ ! -d "$REPO_ROOT/backend/.venv" ]]; then
    log "creating backend/.venv with $PYTHON_BIN"
    "$PYTHON_BIN" -m venv "$REPO_ROOT/backend/.venv"
  fi
  log "installing backend deps (pip)"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/backend/.venv/bin/activate"
  pip install --quiet --upgrade pip
  pip install --quiet -e "$REPO_ROOT/backend"
  pip install --quiet -r "$REPO_ROOT/third_party/bunq_toolkit/requirements.txt" 2>/dev/null || true
  ok "backend deps installed"

  if [[ ! -d "$REPO_ROOT/mobile/node_modules" ]]; then
    log "installing mobile deps (npm)"
    ( cd "$REPO_ROOT/mobile" && npm install --silent )
    ok "mobile deps installed"
  else
    ok "mobile deps cached"
  fi
else
  log "SKIP_DEPS=1 — skipping installs"
  # shellcheck disable=SC1091
  [[ -f "$REPO_ROOT/backend/.venv/bin/activate" ]] && source "$REPO_ROOT/backend/.venv/bin/activate"
fi

# ─────────────────────────────────────────────────────────────────────────────
# TigerBeetle
# ─────────────────────────────────────────────────────────────────────────────
section "tigerbeetle"

if (( RESET_TB )); then
  warn "--reset passed: wiping TB data directory"
  docker compose -f "$REPO_ROOT/docker-compose.yml" down --remove-orphans 2>/dev/null || true
  rm -rf "$REPO_ROOT/tb-data"
fi

log "docker compose up -d tigerbeetle"
( cd "$REPO_ROOT" && docker compose up -d tigerbeetle ) >/dev/null
# Wait for TCP on :3000.
for i in {1..20}; do
  if nc -z 127.0.0.1 3000 2>/dev/null; then
    ok "tigerbeetle listening on :3000"
    break
  fi
  (( i == 20 )) && die "tigerbeetle did not open :3000 in 20s — check docker logs"
  sleep 0.5
done

# ─────────────────────────────────────────────────────────────────────────────
# Migrations
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "${SKIP_MIGRATE:-}" ]]; then
  section "supabase migrations"
  SUPABASE_DB_URL=$(grep -E '^SUPABASE_DB_URL=' "$REPO_ROOT/.env" | cut -d= -f2-)
  if [[ -z "$SUPABASE_DB_URL" ]]; then
    warn "SUPABASE_DB_URL empty — skipping migrations (set it and re-run to apply)"
  elif ! command -v psql >/dev/null; then
    warn "psql not installed — skipping migrations (install postgresql client, or run via Supabase dashboard)"
  else
    for f in "$REPO_ROOT"/supabase/migrations/*.sql; do
      log "applying $(basename "$f")"
      psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f "$f" >/dev/null
    done
    ok "migrations applied"
  fi
else
  log "SKIP_MIGRATE=1 — skipping migrations"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Backend
# ─────────────────────────────────────────────────────────────────────────────
section "backend"

BACKEND_PORT="${BACKEND_PORT:-8000}"
if lsof -iTCP:"$BACKEND_PORT" -sTCP:LISTEN -n -P 2>/dev/null | grep -q LISTEN; then
  warn "port $BACKEND_PORT already in use — killing previous backend if it's ours"
  if [[ -f "$BACKEND_PIDFILE" ]] && kill -0 "$(cat "$BACKEND_PIDFILE")" 2>/dev/null; then
    kill "$(cat "$BACKEND_PIDFILE")" || true
    sleep 0.5
  else
    die "port $BACKEND_PORT busy and not ours — stop the other process first"
  fi
fi

log "starting uvicorn → $BACKEND_LOG"
( cd "$REPO_ROOT/backend" && \
  TIGERBEETLE_ADDRESSES=127.0.0.1:3000 \
  nohup python -m uvicorn app.main:app --host 0.0.0.0 --port "$BACKEND_PORT" --reload \
    >"$BACKEND_LOG" 2>&1 &
  echo $! > "$BACKEND_PIDFILE" )

# Wait for /health.
for i in {1..30}; do
  if curl -sf "http://127.0.0.1:$BACKEND_PORT/health" >/dev/null 2>&1; then
    ok "backend healthy on :$BACKEND_PORT  (pid $(cat "$BACKEND_PIDFILE"))"
    break
  fi
  (( i == 30 )) && { tail -n 40 "$BACKEND_LOG"; die "backend failed to come up — see $BACKEND_LOG"; }
  sleep 0.5
done

# ─────────────────────────────────────────────────────────────────────────────
# Info panel
# ─────────────────────────────────────────────────────────────────────────────
section "ready"

cat <<EOF
  ${C_BOLD}backend${C_RESET}         http://127.0.0.1:$BACKEND_PORT
  ${C_BOLD}api docs${C_RESET}        http://127.0.0.1:$BACKEND_PORT/docs
  ${C_BOLD}tigerbeetle${C_RESET}     127.0.0.1:3000 (docker)
  ${C_BOLD}backend log${C_RESET}     tail -f $BACKEND_LOG
  ${C_BOLD}stop${C_RESET}            ./stop.sh   (or Ctrl-C if --mobile)

  ${C_DIM}bunq: run ${C_BOLD}make bunq-bootstrap${C_RESET}${C_DIM} to mint sandbox users from SANDBOX_USERS.md${C_RESET}
  ${C_DIM}demo: run ${C_BOLD}make seed-demo${C_RESET}${C_DIM} to seed a ready-to-pitch group${C_RESET}
EOF

# ─────────────────────────────────────────────────────────────────────────────
# Mobile (foreground)
# ─────────────────────────────────────────────────────────────────────────────
if (( WITH_MOBILE )); then
  section "expo"
  log "starting expo in foreground — Ctrl-C to shut everything down"

  shutdown() {
    echo
    log "shutting down…"
    if [[ -f "$BACKEND_PIDFILE" ]]; then
      kill "$(cat "$BACKEND_PIDFILE")" 2>/dev/null || true
      rm -f "$BACKEND_PIDFILE"
    fi
    ( cd "$REPO_ROOT" && docker compose stop tigerbeetle >/dev/null 2>&1 ) || true
    ok "clean"
    exit 0
  }
  trap shutdown INT TERM

  ( cd "$REPO_ROOT/mobile" && npx expo start --clear )
  shutdown
fi
