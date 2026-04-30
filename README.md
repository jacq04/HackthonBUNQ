# Pod — AI-Powered ROSCA Savings Platform

**bunq Hackathon 7.0 submission**

> **bunq** = the bank · **TigerBeetle** = the accountant · **Claude** = the organizer.
> Agents propose, humans approve — with their face.

---

## What is Pod?

**Pod** is a mobile app that digitises informal rotating savings groups — known as ROSCAs (Rotating Savings and Credit Associations), or locally as Susu, Tanda, Chit Fund, Hui, Kye, or Tontine.

In a Pod, N members each contribute a fixed amount every month. One member receives the entire pot on a rotating basis until every member has received it once. The group then starts a new cycle.

This model moves roughly **$500 billion per year** globally. It fails when coordination breaks down — late payments, disputes, unfair payout ordering, and early exits with no clean resolution. Pod solves all of this with mathematical certainty from TigerBeetle's ledger invariants, real money movement through bunq, and social intelligence from Claude agents.

**Kitty** is Pod's built-in voice assistant — a conversational agent that answers member questions, explains rules, and guides users through the app.

---

## How it works

### Three-plane architecture

| Plane | Technology | Responsibility |
|-------|-----------|----------------|
| Money rails | bunq sandbox API | Real EUR movement — contributions, payouts, refunds |
| Accounting | TigerBeetle | Double-entry ledger with `debits_must_not_exceed_credits` on the pool account — mathematically impossible to overpay |
| Social coordination | Claude (Sonnet 4.6 + Haiku 4.5) | Charter drafting, trust scoring, reminders, dispute mediation, emergency exits, payout ordering |

### Agent cast

| Agent | Model | Role |
|-------|-------|------|
| **Router** | Haiku | Classifies incoming chat messages and routes to the right specialist |
| **Vetting** | Sonnet | Reads a new member's bunq transaction history and reputation passport; writes a trust score (0–100) |
| **Matchmaker** | Sonnet | Matches waitlisted users to open circles based on goal, amount, urgency, and cultural fit |
| **Constitution (Connie)** | Sonnet | Interactive multi-turn dialog with a circle founder; drafts and finalises the group charter |
| **Collector (Coby)** | Haiku | Sends tone-escalating, culturally-aware payment reminders to overdue members |
| **Mediator (Moti)** | Sonnet (vision) | Reads TigerBeetle state, bunq history, and uploaded receipt photos to resolve payment disputes |
| **Emergency (Ella)** | Sonnet | Computes a fair buyout for a member who needs to exit early; executes atomically on group consensus |
| **Payout Optimizer (Kalu)** | Sonnet | Uses an OR-tools CP-SAT solver to determine the fairest payout order given member urgency bids |
| **Kitty** | Voice (Gemini 2.5 Live) | Real-time voice assistant for help, onboarding, and Q&A |

Agents do not move money directly. Every state-mutating action goes through a declared tool. The backend audits every tool call — enabling the "agents propose, humans approve" model.

---

## Key flows

### Contribution (two-phase)
1. Member taps **Contribute** (FaceID-gated) → backend creates two linked PENDING TigerBeetle transfers and a bunq payment request.
2. Member authorises payment in bunq.
3. bunq webhook fires → backend posts both transfers atomically.
4. Ledger tape updates in real time on all members' phones; the pot animation fills.

### Dispute
Mediator reads TigerBeetle state + bunq history + receipt photo (vision OCR) → proposes resolution. If a corrective transfer is needed, it fires as an atomic linked batch.

### Emergency exit
Emergency agent computes net owed (contributions paid − payout received) → posts buyout proposal to the group → executes atomic refund transfer when all remaining members consent.

### Payout
Payout Optimizer ranks all members by urgency bids using CP-SAT → admin confirms order → atomic linked TigerBeetle batch fires, then bunq payment to winner's IBAN.

---

## Tech stack

| Layer | Technology |
|-------|-----------|
| Mobile (iOS + Android) | Flutter · GoRouter · Riverpod · Supabase Flutter · Dio |
| UI / motion | google_fonts · flutter_animate · flutter_svg |
| Biometrics | flutter local_auth (FaceID / fingerprint) |
| QR invites | mobile_scanner |
| Voice agent | record · flutter_pcm_sound · web_socket_channel → Gemini 2.5 Live |
| Backend | FastAPI (Python 3.12) · uvicorn |
| Ledger | TigerBeetle 0.16.30 (Docker) |
| Database / auth / realtime | Supabase (Postgres + Row-Level Security + Realtime publications) |
| LLM | Claude Sonnet 4.6 · Claude Haiku 4.5 (prompt caching enabled) |
| Banking | bunq sandbox HTTP API (async httpx) |
| Solver | OR-tools CP-SAT (payout ordering) |

---

## Screens

| Route | Screen |
|-------|--------|
| `/sign-in` | bunq identity selection |
| `/` | Wallet — balances and transaction history |
| `/circles` | Home — list of joined pods |
| `/find-circle` | Matchmaker — describe your goal, amount, timeline, cultural context |
| `/group/:id` | Pod detail — pot visualisation, ledger tape, action bar |
| `/group/:id/accept` | Accept circle invite |
| `/group/:id/cycle/:cycle/bid` | Urgency bid for cycle payout |
| `/admin` | Admin dashboard — create circles, manage waitlist |
| `/admin/pods/:id` | Per-pod admin — run payouts, view audit log |

---

## Quickstart

### Prerequisites

- Python 3.12+
- Flutter SDK 3.27.0+
- Docker (TigerBeetle + Supabase)
- Anthropic API key

### One command

```bash
cp .env.example .env
# Set ANTHROPIC_API_KEY in .env

make supabase-up
# Copy the printed SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_DB_URL into .env

./start.sh --mobile        # preflight → TigerBeetle → migrations → backend → Flutter
```

`./start.sh --check` runs preflight only. `./stop.sh` tears everything down cleanly.

### Manual setup

```bash
# 1. Configure environment
cp .env.example .env

# 2. Boot TigerBeetle
make tb

# 3. Install dependencies and start backend
make install
make backend

# 4. Apply Supabase schema
make db-migrate

# 5. Mint sandbox users and fund them
make bunq-bootstrap
make bunq-funds LABEL=asha AMOUNT=500

# 6. Run mobile (scan QR with your device or open in simulator)
make mobile

# 7. Seed demo data (optional)
make seed-demo
```

Local Supabase Studio: http://127.0.0.1:54323 or `make supabase-studio`.

### Useful commands

```bash
make test                  # pytest -x -q (backend)
make lint                  # ruff check + format
make seed-demo             # seed "Lagos Crew" group for demo
make reset-demo            # wipe and re-seed
make demo-beat CMD=contribute LABEL=asha    # trigger a demo action
```

---

## Repo layout

```
backend/
  app/
    agents/         Claude agent implementations (Router, Constitution, Collector, …)
    bunq/           Async httpx bunq client + webhook dispatcher
    config/         Pydantic settings
    db/             Supabase client
    ledger/         TigerBeetle client, two-phase and linked-batch helpers
    models/         Pydantic domain models
    routes/         FastAPI routers (groups, charter, contribute, payout, disputes, …)
    utils/          Safety (prompt-injection sanitiser), ID derivation, audit helpers

mobile/
  lib/
    features/       Screen widgets (wallet, circles, group detail, matchmaker, admin)
    shared/         Reusable components, theme tokens, API client

supabase/
  migrations/       SQL migrations (Postgres schema + RLS policies)

third_party/
  bunq_toolkit/     Vendored bunq hackathon toolkit — used by bunq_bootstrap.py
                    to mint sandbox users; session format is compatible with
                    the backend's get_bunq_client() loader.

scripts/            Demo seed and reset scripts
SANDBOX_USERS.md    Sandbox identity table — drives bunq-bootstrap
```

---

## Security notes

- **Prompt-injection hardening** — all user-authored text is sanitised through `utils/safety.py::sanitize_user_text` before being passed to an agent. Every agent system prompt instructs the model to ignore instructions embedded in user message tags.
- **Audit trail** — every agent tool call is written to `public.audit_log` (actor, action, resource, diff). The "agents propose, humans approve" story is fully auditable.
- **Biometric gate** — every money-moving button in the mobile app requires FaceID or fingerprint authentication before the API call is made.
- **RLS** — Supabase Row-Level Security ensures users can only read groups they belong to. All cross-user queries originate from the FastAPI service role.

---

## Reputation passport

At the end of each cycle, the Auditor agent issues a signed `reputation_event` for every member. Events are HMAC-signed and verifiable outside Pod, building a portable credit history that travels with the member across groups and cycles.

---

## bunq Hackathon 7.0

- API docs: https://doc.bunq.com/
- DevPost submission: https://bunq-hackathon-7-0.devpost.com/
- bunq hackathon toolkit: https://github.com/bunq/hackathon_toolkit
