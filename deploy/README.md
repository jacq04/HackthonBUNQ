# pod. — production deployment

End-to-end topology, with everything we run in production:

```
┌── Cloudflare Pages ──────────────────────────────────────┐
│   pod-chit-together.pages.dev   marketing + voice proxy │
│   pod-app.pages.dev             Flutter web app          │
└──────────────────────────────────────────────────────────┘

┌── Fly.io (eu-central / ams) ─────────────────────────────┐
│   pod-backend.fly.dev           FastAPI orchestrator     │
│   pod-tb.internal:3000          TigerBeetle (private)    │
└──────────────────────────────────────────────────────────┘

┌── Supabase Cloud ────────────────────────────────────────┐
│   <project>.supabase.co         Postgres + Auth + RT     │
└──────────────────────────────────────────────────────────┘

External APIs:
   api.anthropic.com               Claude agents
   generativelanguage.googleapis.com   Gemini Live
   public.api.bunq.com             real EUR rails (sandbox)
```

## What hits what

| From → To | Why |
|---|---|
| Browser → `pod-chit-together.pages.dev` | marketing site + voice WS proxy |
| Browser → `pod-app.pages.dev` | the Flutter app |
| Browser → `pod-backend.fly.dev` | wallet / agent calls (CORS-allowed) |
| Browser → `<project>.supabase.co` | auth + realtime tape |
| FastAPI → `pod-tb.internal:3000` | TigerBeetle ledger over Fly's private 6PN |
| FastAPI → `api.anthropic.com` | agent tool calls |
| FastAPI → `public.api.bunq.com` | move real euros |
| bunq → `pod-backend.fly.dev/webhooks/bunq` | payment webhooks |

## One-time setup

```bash
brew install flyctl supabase/tap/supabase
fly auth login
supabase login
```

### Supabase Cloud project

1. Create project at https://supabase.com/dashboard.
2. From repo root:
   ```bash
   supabase link --project-ref <YOUR_PROJECT_REF>
   ```
3. Capture these from **Settings → API** in the Supabase dashboard:
   - `SUPABASE_URL`
   - `SUPABASE_ANON_KEY`
   - `SUPABASE_SERVICE_ROLE_KEY`
   - `SUPABASE_DB_URL` (under Settings → Database → Connection string, choose URI mode)

### Fly secrets

```bash
fly secrets set --app pod-backend \
  ANTHROPIC_API_KEY=sk-ant-...                                \
  BUNQ_API_KEY=sandbox_...                                     \
  SUPABASE_URL=https://<proj>.supabase.co                      \
  SUPABASE_ANON_KEY=eyJhbGciOi...                              \
  SUPABASE_SERVICE_ROLE_KEY=eyJhbGciOi...                      \
  SUPABASE_DB_URL=postgres://postgres:<pw>@db.<proj>.supabase.co:5432/postgres \
  TIGERBEETLE_ADDRESSES=pod-tb.internal:3000
```

### Shell env for the Flutter web build

The deploy script reads these from your shell to bake into the bundle:

```bash
export SUPABASE_URL=https://<proj>.supabase.co
export SUPABASE_ANON_KEY=eyJhbGciOi...
```

## Deploy

```bash
./deploy/deploy.sh
```

This runs four ordered steps:

1. `supabase db push` — apply migrations from `supabase/migrations/` to the linked project.
2. Deploy TigerBeetle to Fly (`pod-tb`).
3. Deploy FastAPI backend to Fly (`pod-backend`).
4. `flutter build web` and `wrangler pages deploy` to `pod-app`.

## Subsequent deploys

If only the app changed, run just step 4:

```bash
cd mobile && flutter build web --release \
  --dart-define=VOICE_BASE_URL=https://pod-chit-together.pages.dev \
  --dart-define=API_BASE_URL=https://pod-backend.fly.dev \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY
cd build/web && wrangler pages deploy . --project-name=pod-app
```

If only the backend changed:

```bash
fly deploy --config backend/fly.toml --dockerfile backend/Dockerfile --app pod-backend
```

If only Supabase migrations changed:

```bash
supabase db push
```

## Rollback

- **Pages**: every deploy gets a unique `<hash>.pod-app.pages.dev` URL. Promote any historical one in the Cloudflare dashboard.
- **Fly**: `fly releases --app pod-backend` shows the history; `fly deploy --image registry.fly.io/pod-backend:<previous>` rolls back to a specific image.
- **Supabase**: migrations are immutable forward-only. To undo a bad migration, write a compensating migration and `supabase db push`.

## Cost

Free tiers cover hackathon volume:
- Cloudflare Pages: free, 500 builds/mo.
- Fly.io: 3 shared-cpu-1x VMs free; we use 2 (backend + TB).
- Supabase: free tier 500 MB Postgres + 50 MAU.

Estimated post-free-tier cost if kept running: **≈$5/mo** (Fly compute over the free tier).
