# Kitty

ROSCA / Tontine savings-pot app for the bunq Hackathon 7.0.

**bunq** = the bank · **TigerBeetle** = the accountant · **Claude agents** = the organizer.

N friends contribute monthly; one member gets the pot each cycle on rotation. Agents handle the social layer (charter, reminders, disputes, emergencies, payouts). TigerBeetle enforces money invariants. bunq moves real euros.

## Stack

- **Mobile**: Expo (React Native) + Expo Router + NativeWind + Reanimated 3 + Skia
- **Backend**: FastAPI (Python 3.12)
- **Ledger**: TigerBeetle (double-entry, two-phase transfers, `debits_must_not_exceed_credits` invariants)
- **App DB / Auth / Realtime**: Supabase
- **LLM**: Claude Sonnet 4.6 + Haiku 4.5 (prompt caching on)
- **Money rails**: bunq sandbox

## Quickstart

### Fast path (one command)

```bash
cp .env.example .env   # fill SUPABASE_* + ANTHROPIC_API_KEY
./start.sh --mobile    # preflight → TB → migrations → backend → expo QR
```

`./start.sh --check` runs just the preflight. `./stop.sh` tears everything down.

### Manual path

```bash
# 1. Configure env
cp .env.example .env
# Fill in SUPABASE_*, ANTHROPIC_API_KEY. BUNQ_API_KEY is optional now — see step 5.

# 2. Boot TigerBeetle
make tb

# 3. Install + run backend
make install
make backend

# 4. Apply Supabase schema
make db-migrate

# 5. Bootstrap bunq sandbox users (uses the vendored toolkit at third_party/bunq_toolkit)
#    Edit SANDBOX_USERS.md to set the labels you want, then:
make bunq-bootstrap
#    For each user, request €500 test funds from sugardaddy:
make bunq-funds LABEL=asha

# 6. Run mobile (scan QR on Expo Go)
make mobile

# 7. Demo seed (optional)
make seed-demo
```

## Repo layout

```
backend/            FastAPI orchestrator + agents + TB client + bunq client
  app/
    config/         Pydantic Settings
    db/             Supabase client singleton
    ledger/         TigerBeetle client + two-phase helpers
    bunq/           httpx wrapper + webhook dispatcher
    agents/         Claude agent cast (Router, Constitution, Collector, ...)
    routes/         FastAPI routers (groups, charter, contribute, payout, ...)
    models/         Pydantic domain models
    utils/          Shared utilities

mobile/             Expo app (iOS + Android)
  app/              Expo Router screens
  src/
    components/     Pot, LedgerTape, AgentMessage, ...
    lib/            Supabase + typed API client
    hooks/
    theme/

supabase/
  migrations/       SQL migrations (0001_init.sql, ...)

third_party/
  bunq_toolkit/     Cloned from github.com/bunq/hackathon_toolkit — used by
                    scripts/bunq_bootstrap.py to mint sandbox users and
                    cache sessions in the toolkit's bunq_context.json format.

SANDBOX_USERS.md    Table of sandbox identities — drives bunq-bootstrap.
scripts/            Seed + reset scripts for demos
```

## Plan

The approved 48-hour implementation plan lives at `~/.claude/plans/what-about-multi-model-async-candle.md`. CLAUDE.md has hackathon-level context.
