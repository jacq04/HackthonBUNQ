# Kitty — Demo Day Runbook

A 90-second pitch on the iOS Simulator + one terminal window. Driven by
`backend/scripts/demo.py`. Every beat is idempotent and reproducible.

## The agent cast

Circles are **platform-formed**, never user-created. The user describes what
they want; agents do the rest.

| Agent | When | What it does |
|---|---|---|
| **Vetting** | on first match request | Reads bunq tx history → trust_score 0–100 with rationale |
| **Matchmaker** | on match request | Decides JOIN / FORM / WAITLIST; forms new circles via service-role |
| **Constitution** | after a new circle is formed | Drafts the charter (rules) with the founder |
| **Collector** | contribution window | Tone-calibrated reminders; escalates to Mediator |
| **Mediator** | on dispute | Reads TB + bunq + evidence → verdict (+ corrective TB transfer) |
| **Emergency** | on exit request | Computes fair buyout → group consent → atomic TB unwind |
| **Payout Optimizer** | cycle boundary | Interviews members → OR-tools CSP → orders payouts |
| **Post-Payout Coach** | on payout land | Routes pot into the goal sub-account |
| **Auditor** | end of cycle | Issues signed reputation_events → passport |
| **Cultural Translator** | cross-culture groups | Rewrites agent messages in native idiom (future) |

## 0. Pre-flight (5 min before stage)

```bash
# 1. Full stack up
./start.sh                        # TB + Supabase + backend on :8000
make supabase-up                  # if not already running
make bunq-bootstrap               # mints 6 sandbox users if missing

# 2. Seed the demo state: Lagos Crew · 6 members · €250/cycle · 3 cycles paid
make seed-demo

# 3. Show the simulator
make mobile-ios                   # expo auto-opens iPhone 16 Pro

# 4. Verify
make demo-status                  # pool ~€4500, Tunde has a pending cycle 4
```

**Simulator sign-in:** tap "🐝 sign in with bunq" → pick **Amie Stewart** (asha).
You'll land on Home with Lagos Crew visible.

Keep these side-by-side on your laptop:
- **Simulator** (airplay mirrored to the projector)
- **Terminal** running `watch -n 2 make demo-status` so the pool balance updates live
- **Supabase Studio** at http://127.0.0.1:54323 — `events` table (tape) can be visible as a backup

## 1. The script (90 s)

> Numbered beats map 1:1 to terminal commands.

### 0:00 — Hook (10 s, narrated)
> "60% of informal savings groups fail. Not because people are dishonest — because the math and the social coordination break. And on existing fintech you have to *find* six people you trust to even start. Meet Kitty — circles form themselves."

Open the app (already signed in as Asha). Lagos Crew at the top of Home.
Optional: tap **find a circle** first to show the Matchmaker flow, then back out
to Lagos Crew for the rest of the beats.

### 0:10 — Live contribution (15 s)
Tap the group → you're on the Pot screen with pot filled at ~50% + the ledger tape scrolling past 3 cycles of posts.

In terminal:
```bash
make demo-beat CMD=contribute LABEL=tunde
```
Pot animates up €250. New ledger row slides in. Haptic thunk.

### 0:25 — Live dispute (25 s)
> "Malik says he paid cycle 3. Pool says no."

In terminal:
```bash
make demo-beat CMD=dispute LABEL=malik
```

Watch:
- Dispute row appears in the Disputes pill on the group detail screen.
- Chat tab shows `Moti · Mediator` deliberating (3–5 tool calls: reads TB ledger, reads bunq history, proposes resolution).
- Verdict card renders — purple accent. Usually `verified_paid` for cycle 3 because the seed posted his contribution correctly.

### 0:50 — Live emergency buyout (20 s)
> "Priya's mom needs surgery. She has to pull out now."

```bash
make demo-beat CMD=emergency LABEL=priya
```

Watch:
- Emergency card appears — red accent.
- Agent computes buyout = contributed − received = €750.
- Group consent is auto-simulated (the 5 others approve).
- Atomic TB linked batch fires — pool shrinks by €750, Priya's received_account registers the refund.
- Ledger tape emits `emergency.executed`.

### 1:10 — Cycle payout (15 s)
> "Cycle 4 payout day. Tunde is next."

```bash
make demo-beat CMD=payout
```

Watch:
- Linked batch: pool → gateway + pool → member_received for Tunde — all atomic.
- Pot empties visibly.
- Payout event in ledger tape.
- In production this would also fire a real bunq payment to Tunde's IBAN.

### 1:30 — Close (8 s)
> "Grandmothers on paper — 60% failure. Us on TigerBeetle + bunq + a crew of agents — zero math mistakes, full audit trail, every decision traceable."

Tap **Passport** tab → show Asha's reputation card.

## 2. Cut-list (if behind schedule on stage)

Cut in this order:
1. Passport close shot (just say the line)
2. Emergency beat (say "we also support early exits" and show Auditor slide)
3. Dispute verdict card (show terminal output instead)

Never cut contribution + payout — those demonstrate the atomic TB linked batch.

## 3. Failure modes + mitigations

| Symptom | Fix |
|---|---|
| Terminal command hangs on Anthropic call | Corporate TLS issue — make sure `SSL_CERT_FILE=$NODE_EXTRA_CA_CERTS` is exported in your shell (already done by `./start.sh`) |
| Pot doesn't animate after beat | Supabase realtime subscription lost — pull down on the Pot screen to refresh |
| Mediator verdict looks confused | Re-run the beat — Sonnet 4.6 is deterministic under prompt cache, usually recovers |
| Need to restart demo cold | `make reset-demo && make seed-demo` — <10s |
| Simulator frozen | Cmd+Shift+H to home, relaunch Expo Go from home screen |

## 4. Cheat-sheet (print this)

```
SETUP     ./start.sh  ·  make supabase-up  ·  make bunq-bootstrap  ·  make seed-demo  ·  make mobile-ios
STATUS    make demo-status
BEAT 1    make demo-beat CMD=contribute LABEL=tunde
BEAT 2    make demo-beat CMD=dispute LABEL=malik
BEAT 3    make demo-beat CMD=emergency LABEL=priya
BEAT 4    make demo-beat CMD=payout
RESET     make reset-demo
```

## 5. Matchmaker demo (alternate / extended pitch)

If you want to show circle-formation instead of (or before) Lagos Crew:

```bash
make reset-demo                              # wipe Lagos Crew
# Seed just waitlisted users (no groups), then invoke matchmaker.
# Currently done manually; a `demo waitlist` helper can be added.
```

On the app, from sign-in:
1. Sign in with bunq → pick Asha
2. Home is empty → tap **find a circle**
3. Fill: "tuition deposit", €250, 6 cycles, high urgency, "Tanda"
4. Tap **ask the matchmaker** →
   - Vetting runs (~5s) → score shown in the reply
   - Matchmaker chooses: with empty state, WAITLIST
5. Sign out. Sign in as Malik, Priya, … with similar prefs.
6. On the 6th user, Matchmaker switches to **FORM** → circle is created with
   all 6 as members. Constitution picks up from there.

## 6. What to emphasize to judges

- **TigerBeetle invariant** — `debits_must_not_exceed_credits` on the pool means it's impossible to pay out more than was contributed. Say that line.
- **Agents propose, humans approve** — every money-touching action has a tool-call audit trail in `public.audit_log`. Show a few rows if asked.
- **bunq = bank, TB = accountant, Claude = organizer** — the one-line architecture.
- **Cultural context** — "Our bunq identities are Asha, Malik, Priya, Tunde, Fatou, Raj. This product exists because ROSCAs (Susu / Chit fund / Kye / Tanda / Tontine / Hui) move $500B a year informally and fail too often."
