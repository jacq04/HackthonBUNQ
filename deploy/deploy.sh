#!/usr/bin/env bash
# pod. — full-stack deploy script.
#
# Runs four ordered steps:
#   1. Push Supabase migrations to the linked cloud project.
#   2. Deploy TigerBeetle to Fly (pod-tb).
#   3. Deploy FastAPI backend to Fly (pod-backend).
#   4. Build Flutter web and deploy to Cloudflare Pages (pod-app).
#
# Pre-flight (you do this once):
#   brew install flyctl supabase/tap/supabase
#   fly auth login
#   supabase login
#   supabase link --project-ref <YOUR_PROJECT_REF>      # creates supabase/.temp/
#   fly secrets set --app pod-backend  ANTHROPIC_API_KEY=... BUNQ_API_KEY=... \
#                                      SUPABASE_URL=... SUPABASE_ANON_KEY=... \
#                                      SUPABASE_SERVICE_ROLE_KEY=...           \
#                                      SUPABASE_DB_URL=...                     \
#                                      TIGERBEETLE_ADDRESSES=pod-tb.internal:3000

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

echo "==> 1/4   supabase db push"
supabase db push

echo "==> 2/4   fly deploy pod-tb (TigerBeetle)"
# create app + volume the first time only; both fail-fast safe to re-run
fly apps list | grep -q "^pod-tb " || fly apps create pod-tb --org personal
fly volumes list --app pod-tb | grep -q "^tb_data" \
  || fly volumes create tb_data --size 1 --region ams --app pod-tb --yes
fly deploy \
  --config deploy/tigerbeetle.fly.toml \
  --image ghcr.io/tigerbeetle/tigerbeetle:0.16.30 \
  --app pod-tb \
  --strategy immediate

echo "==> 3/4   fly deploy pod-backend (FastAPI)"
fly apps list | grep -q "^pod-backend " || fly apps create pod-backend --org personal
fly deploy \
  --config backend/fly.toml \
  --dockerfile backend/Dockerfile \
  --app pod-backend

echo "==> 4/4   flutter web → Cloudflare Pages (pod-app)"
cd mobile
flutter pub get
flutter build web --release \
  --dart-define=VOICE_BASE_URL=https://pod-chit-together.pages.dev \
  --dart-define=API_BASE_URL=https://pod-backend.fly.dev \
  --dart-define=SUPABASE_URL="${SUPABASE_URL:?SUPABASE_URL must be set in shell env}" \
  --dart-define=SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:?SUPABASE_ANON_KEY must be set in shell env}"
cd build/web
wrangler pages deploy . --project-name=pod-app --branch=main --commit-dirty=true

echo
echo "✓ deployed:"
echo "   marketing   https://pod-chit-together.pages.dev"
echo "   app         https://pod-app.pages.dev"
echo "   backend     https://pod-backend.fly.dev"
echo "   tigerbeetle pod-tb.internal:3000  (private)"
