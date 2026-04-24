#!/usr/bin/env bash
# Paste an Anthropic API key into .env without leaving a trace in shell history.
# Runs a test call to verify the key works, and bounces the backend to pick it up.
#
#   ./scripts/set-anthropic-key.sh           # interactive (silent paste)
#   ANTHROPIC_API_KEY=sk-ant-... ./scripts/set-anthropic-key.sh   # scripted (CI)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -t 1 ]]; then GRN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; RST=$'\033[0m';
else GRN=''; RED=''; YEL=''; RST=''; fi

[[ -f .env ]] || { echo "${RED}.env not found — run ./start.sh --check first${RST}"; exit 1; }

KEY="${ANTHROPIC_API_KEY:-}"
if [[ -z "$KEY" ]]; then
  if [[ ! -t 0 ]]; then
    echo "${RED}no key provided and stdin is not a tty${RST}"
    exit 1
  fi
  echo -n "Anthropic API key (hidden): "
  read -rs KEY
  echo
fi

if [[ ! "$KEY" =~ ^sk-ant- ]]; then
  echo "${YEL}warning: key doesn't start with 'sk-ant-' — proceeding anyway${RST}"
fi

# Atomic write: never leave a half-written .env.
tmp="$(mktemp "${TMPDIR:-/tmp}/kitty-env.XXXXXX")"
awk -v key="$KEY" '
  /^ANTHROPIC_API_KEY=/ { print "ANTHROPIC_API_KEY=" key; found=1; next }
  { print }
  END { if (!found) print "ANTHROPIC_API_KEY=" key }
' .env > "$tmp"
mv "$tmp" .env
chmod 600 .env

echo "${GRN}✓${RST} .env updated"

# Verify against the API.
PY="./backend/.venv/bin/python"
[[ -x "$PY" ]] || PY="python3"

echo "verifying against Anthropic..."
ANTHROPIC_API_KEY="$KEY" "$PY" - <<'PY'
import os, sys
try:
    from anthropic import Anthropic
except Exception as e:
    print(f"couldn't import anthropic SDK: {e}")
    sys.exit(2)
client = Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
resp = client.messages.create(
    model=os.environ.get("CLAUDE_FAST_MODEL", "claude-haiku-4-5-20251001"),
    max_tokens=16,
    messages=[{"role": "user", "content": "say pong"}],
)
text = "".join(b.text for b in resp.content if hasattr(b, "text")).strip()
print(f"api ok: model={resp.model} usage={resp.usage.input_tokens}in/{resp.usage.output_tokens}out reply={text!r}")
PY

echo "${GRN}✓${RST} Anthropic API reachable"

# Bounce the backend so it picks up the new key (settings are read at startup).
if [[ -f .kitty-run/backend.pid ]] && kill -0 "$(cat .kitty-run/backend.pid)" 2>/dev/null; then
  echo "bouncing backend to pick up new key..."
  ./stop.sh >/dev/null
  SKIP_DEPS=1 SKIP_MIGRATE=1 ./start.sh >/dev/null &
  # wait for health
  for _ in {1..30}; do
    if curl -sf "http://127.0.0.1:${BACKEND_PORT:-8000}/health" >/dev/null 2>&1; then
      echo "${GRN}✓${RST} backend healthy again"
      exit 0
    fi
    sleep 0.5
  done
  echo "${YEL}backend didn't come back up — check .kitty-run/backend.log${RST}"
else
  echo "backend not running — start with ./start.sh when ready"
fi
