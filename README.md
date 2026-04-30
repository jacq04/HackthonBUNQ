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

## Full flow

Pod's lifecycle runs in six stages. A different agent (or set of agents) handles each one. None of them move money directly — every state-mutating action goes through a declared tool call that the backend validates and writes to the audit log.

---

### Stage 1 — Onboarding and trust scoring

When a user opens Pod for the first time and tries to find a circle, the **Vetting agent** runs automatically to assign them a trust score between 0 and 100.

The agent calls three tools in sequence:

1. **`read_bunq_tx_summary`** — fetches aggregate stats from the user's bunq account: total inflow, total outflow, transaction count, and number of distinct counterparties over the past 90 days.
2. **`read_reputation_history`** — reads any signed reputation events from previous Pod cycles (see Stage 6).
3. **`record_trust_score`** — writes the final score and a short rationale back to the user's record.

Scoring anchors:
- **90–100** — strong income, clean history, known network
- **70–89** — stable cashflow, neutral Pod history
- **50–69** — unknown or first circle (new users start here)
- **30–49** — erratic cashflow or prior late payments
- **0–29** — significant concerns

If the user already has a score above 50 from a previous cycle, vetting is skipped and the existing score is used.

---

### Stage 2 — Matchmaking

The user tells Pod their goal, monthly contribution amount, number of cycles, urgency level, and optionally a cultural context (Susu, Tanda, Chit Fund, etc.). The **Matchmaker agent** then decides what to do.

Circles are created by admins, not by users. The Matchmaker only places people into circles that already exist. It applies three hard filters before even presenting a circle as an option:

- The user's trust score must be **≥ the circle's minimum trust score**
- The contribution amount must be **within ±15%** of the circle's target
- The cycle count must **match exactly**

After filtering, the agent calls `list_open_circles` and `list_waitlist` and picks exactly one of three actions:

- **FILL** — if the waiting users on the waitlist plus the current user together exactly fill the circle's remaining seats, and all of them meet the filters, the agent calls `propose_fill_circle`. All of them are batch-invited at once and the circle moves to `awaiting_accepts`.
- **JOIN** — if there is a single open seat and no waitlist match is needed, the agent calls `propose_join_existing` to add the user directly.
- **WAITLIST** — if no circle fits, the agent calls `add_to_waitlist` with a rationale. The admin sees this in the dashboard and can open a new circle if there is enough demand.

---

### Stage 3 — Charter drafting

Before any money moves, every circle needs a written charter. The **Constitution agent (Connie)** conducts a multi-turn interview with the circle's founder to produce one.

Connie asks short, direct questions — one per turn — and works through the following topics in order:

1. Contribution amount, currency, and frequency (monthly / biweekly / weekly)
2. Total number of cycles (which equals the number of members)
3. Grace period before a contribution is considered late
4. Late-payment penalty (in basis points, e.g. 200 = 2%)
5. Payout ordering policy: **agent_optimized** (the Payout Optimizer decides), **lots** (random draw), or **fixed** (set upfront)
6. What happens on a missed contribution
7. What happens if a member joins or leaves mid-cycle
8. Early-exit and hardship rules
9. Dispute escalation path

As agreement is reached on each section, Connie calls `draft_charter` to save progress incrementally. Once all terms are confirmed, she calls `finalize_charter`, which writes the final JSON to the database, flips the group status to **active**, and emits a `charter.finalized` event that every member's phone receives in real time.

---

### Stage 4 — Monthly contributions

Each month, every member pays in their fixed amount. The contribution flow is split into two phases to keep the TigerBeetle ledger and bunq in sync even if one side is temporarily unavailable.

**Phase 1 — Member taps Contribute (FaceID-gated)**

The backend creates two linked PENDING transfers in TigerBeetle atomically:
- Gateway → Pool (mirrors the incoming bunq payment)
- Gateway → Member_Contrib (records that this member has contributed)

Both debit the gateway account, which acts as the unconstrained counterparty. The pool account carries a `debits_must_not_exceed_credits` constraint — it is mathematically impossible to pay out more than has been received. A bunq payment request is sent to the member. The mobile app shows a `contribution.pending` event on the ledger tape immediately.

**Phase 2 — bunq webhook fires**

When the member authorises the payment in bunq, bunq sends a `PAYMENT.CREATED` webhook to the backend. The backend finds the pending record, posts both TigerBeetle transfers atomically, and emits a `contribution.posted` event. Every member's app updates in real time and the pot animation fills.

If the bunq webhook flakes during a demo, `POST /webhooks/bunq/replay` force-commits the pending contribution without it.

---

### Stage 5 — In-cycle agent activity

Several agents run continuously throughout a cycle's lifetime.

#### Router

Every message a member sends in the group chat passes through the **Router agent** first. The Router classifies it into one of seven intents — `contribute`, `dispute`, `emergency`, `charter_question`, `payout_preference`, `chat`, or `unknown` — and returns a routing decision with a confidence score. The backend uses this to decide which specialist agent, if any, to invoke next.

#### Collector (Coby)

The Collector runs on a cron schedule and checks for overdue contributions. For each member who is past their grace period, Coby composes a nudge and sends it via push notification and in-app message. The tone escalates automatically based on how many days overdue the member is:

- **Day 0 (due today)** — warm and friendly
- **Days 1–3** — firm, clear ask
- **Days 4–7** — serious tone, mentions that mediation may follow
- **Day 8+** — Coby stops sending reminders and calls `escalate_to_mediator` instead, handing off to the Mediator agent

Coby is culturally aware. If the member's language setting is non-English, the message is written in that language. If a cultural context is set (e.g. "susu" or "tanda"), the framing reflects that idiom. Messages are capped at two sentences plus one short actionable line.

#### Mediator (Moti)

When a member raises a dispute — typically "I paid but the pool says I didn't" — the **Mediator agent** investigates. It reads three sources of evidence in parallel:

- **`read_tb_ledger`** — the member's TigerBeetle contribution balance and recent transfers
- **`read_bunq_tx_history`** — the last 50 payments on the group's bunq account
- **`read_evidence`** — the member's uploaded receipt photo, analysed via Claude's vision capability

Moti then calls `propose_resolution` with one of five verdicts:

| Verdict | Meaning |
|---------|---------|
| `verified_paid` | bunq shows the payment and TB shows the credit — dispute closed |
| `corrective_transfer` | bunq shows the payment but TB is missing the credit — Moti fires a corrective linked batch atomically |
| `missing_payment` | no bunq payment found — member still owes |
| `investigate_resubmit` | evidence points to a different account or reference — member needs to investigate |
| `flag_fraud` | duplicate descriptions across multiple disputes — escalated to a human |

The verdict and a public-facing message (under 80 words) are posted to the group chat and the dispute record is updated.

#### Bidding agent

If multiple members want the same payout cycle, the **Bidding agent** runs a weighted-random selection. Each member declares an urgency level (critical / high / medium / low) and a reason. The agent:

1. Calls `list_bids` — retrieves every bid for the cycle plus each bidder's trust score and prior bid/win history in this group
2. Calls `evaluate_bid` for each bid — assigns a `reason_score` (0–100) for how time-sensitive the reason is, then computes `weight = emergency_weight × (reason_score / 100)`
3. Applies a **gaming guard** — halves the weight of any member who has already received a pot in this group or has declared "critical" in two or more previous cycles
4. Calls `select_winner` using `weighted_random`, seeded from the cycle's close timestamp so the result is deterministic for audit replay

If only one member bids, they win automatically without the agent running. If nobody bids, the Payout Optimizer's pre-computed slot order is used.

#### Payout Optimizer (Kalu)

When payout ordering mode is set to `agent_optimized`, the **Payout Optimizer** uses an OR-tools CP-SAT solver to assign each member to a unique monthly slot (1 through N). The solver minimises the sum of weighted deviations between each member's preferred month and their assigned month. Members with no stated preference are treated as fully flexible. The solver caps at a 3-second time limit. The resulting order is presented to the admin for confirmation before any money moves.

---

### Stage 6 — Payout and reputation

At the end of each cycle, two things happen.

**Payout**

The backend fires an atomic linked TigerBeetle batch:
- Pool → Gateway (releases the pool constraint)
- Pool → Member_Received (records the payout on the winner's account)

A bunq payment is then sent to the winner's IBAN. If bunq fails, the TB ledger remains as the source of truth and the event is logged as `payout.ledger_only`.

**Reputation passport — Auditor agent**

After each successful payout, the **Auditor agent** issues a signed `reputation_event` for every member in the group. Score deltas are based on the member's behaviour that cycle:

| Behaviour | Score delta |
|-----------|-------------|
| All contributions on time | +5 |
| One contribution late | 0 |
| Two contributions late | −5 |
| Contribution missed entirely | −15 |
| Raised a dispute that was verified | +2 |
| Raised a dispute that was not verified | −3 |
| Mediator had to fire a corrective transfer | −5 |
| Emergency exit granted | 0 (system worked as intended) |
| Unresponsive during emergency consent | −10 |
| Received payout and completed cycle | +3 |

Each event is HMAC-signed with a secret key and written to the `reputation_events` table. The Auditor also updates the member's live trust score in the `users` table so it is ready for the next matchmaking run.

---

### Emergency exits

If a member needs to leave before their payout cycle, they request an emergency exit. The **Emergency agent (Ella)** handles the full flow in three steps:

1. **`compute_buyout`** — reads TigerBeetle to calculate contributions paid minus any payout already received. The result is the proposed refund. If the member has already received the pot, the refund is zero — they owe nothing further but leave cleanly.
2. **`post_proposal`** — posts a compassionate message to the group explaining what the exiting member will receive and what it means for the remaining members. All remaining active members must consent.
3. **`execute_buyout`** — once consensus is reached, fires an atomic linked TigerBeetle batch (Pool → Gateway + Pool → Member_Received) to record the refund. The member's status is set to `emergency_exited`.

---

### Kitty — voice assistant

**Kitty** is the voice layer of Pod, powered by Gemini 2.5 Live over a WebSocket connection proxied through Cloudflare Pages so the API key never reaches the device.

When a member opens the voice sheet, Kitty greets them and invites questions about how a pod works. During the call, Kitty has two tools available:

- **`navigateTo`** — navigates the app to a specific screen (wallet, circles, matchmaker, or admin) in response to voice commands
- **`endCall`** — closes the session when the user is done

Audio is streamed in both directions at the same time: the microphone sends 16 kHz PCM to the model, the model returns 24 kHz PCM to the speaker. A live transcript is shown on screen as the conversation progresses.

---

### How the three planes work together

| Plane | Technology | Role |
|-------|-----------|------|
| Money rails | bunq sandbox API | Moves real EUR — contributions, payouts, refunds |
| Accounting | TigerBeetle | Double-entry ledger with hard invariants — overpayment is impossible at the protocol level |
| Social coordination | Claude (Sonnet 4.6 + Haiku 4.5) | Trust scoring, matchmaking, charter drafting, reminders, dispute mediation, emergency exits, payout ordering |

Every agent action that changes state goes through an explicit tool call. The backend validates it, the `audit_log` table records it. This is what makes "agents propose, humans approve" real — every decision is traceable.

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

## bunq Hackathon 7.0

- API docs: https://doc.bunq.com/
- DevPost submission: https://bunq-hackathon-7-0.devpost.com/
- bunq hackathon toolkit: https://github.com/bunq/hackathon_toolkit
