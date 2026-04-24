#!/usr/bin/env bash
# Kitty — tear down everything start.sh spun up.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$REPO_ROOT/.kitty-run"
BACKEND_PIDFILE="$LOG_DIR/backend.pid"

if [[ -t 1 ]]; then
  C_DIM=$'\033[2m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYA=$'\033[36m'; C_RESET=$'\033[0m'
else
  C_DIM=''; C_GRN=''; C_YEL=''; C_CYA=''; C_RESET=''
fi
log()  { printf "%s[kitty]%s %s\n" "$C_CYA" "$C_RESET" "$*"; }
ok()   { printf "%s[kitty]%s %s%s%s\n" "$C_GRN" "$C_RESET" "$C_GRN" "$*" "$C_RESET"; }
warn() { printf "%s[kitty]%s %s%s%s\n" "$C_YEL" "$C_RESET" "$C_YEL" "$*" "$C_RESET"; }

# Backend
if [[ -f "$BACKEND_PIDFILE" ]]; then
  pid=$(cat "$BACKEND_PIDFILE")
  if kill -0 "$pid" 2>/dev/null; then
    log "stopping backend (pid $pid)"
    kill "$pid" || true
    for _ in {1..10}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.3
    done
    if kill -0 "$pid" 2>/dev/null; then
      warn "backend still alive — sending SIGKILL"
      kill -9 "$pid" || true
    fi
    ok "backend stopped"
  else
    warn "backend pidfile stale — removing"
  fi
  rm -f "$BACKEND_PIDFILE"
else
  log "no backend pidfile"
fi

# Stray uvicorns we may have missed (dev reload forks can orphan)
if pgrep -f "uvicorn app.main:app" >/dev/null; then
  warn "killing stray uvicorn processes"
  pkill -f "uvicorn app.main:app" || true
fi

# TigerBeetle
if docker compose -f "$REPO_ROOT/docker-compose.yml" ps tigerbeetle 2>/dev/null | grep -q Up; then
  log "stopping tigerbeetle container"
  ( cd "$REPO_ROOT" && docker compose stop tigerbeetle ) >/dev/null
  ok "tigerbeetle stopped"
fi

# Expo (foreground — usually already gone, but be defensive)
if pgrep -f "expo start" >/dev/null; then
  warn "killing lingering expo processes"
  pkill -f "expo start" || true
fi

ok "all down"
