-- Matchmaker / Vetting / Auditor supporting schema.
-- Circles are no longer user-created; they're formed by the Matchmaker agent
-- (or the platform). Users describe what they want; the agent matches or builds.

set search_path = public;

-- ─── per-user matching state ──────────────────────────────────────────────
alter table public.users add column if not exists trust_score int default 50 check (trust_score between 0 and 100);
alter table public.users add column if not exists trust_rationale text;
alter table public.users add column if not exists match_preferences jsonb default '{}'::jsonb;
alter table public.users add column if not exists goal text;
alter table public.users add column if not exists waitlist_status text default 'none'
    check (waitlist_status in ('none', 'waiting', 'matched'));
alter table public.users add column if not exists waitlist_since timestamptz;

-- ─── group provenance ──────────────────────────────────────────────────────
alter table public.groups add column if not exists created_by_agent text;  -- 'matchmaker' | 'platform' | null (user-created legacy)

-- ─── reputation passport (audit-issued) ───────────────────────────────────
create table if not exists public.reputation_events (
    id           uuid primary key default gen_random_uuid(),
    user_id      uuid not null references public.users(id) on delete cascade,
    kind         text not null,                  -- 'cycle_complete' | 'dispute_resolved' | 'emergency_granted' | 'late_payment' | 'early_exit'
    score_delta  int  not null,                  -- +5 / -10 etc
    issued_by    text not null,                  -- 'agent:auditor' | 'agent:mediator' | ...
    group_id     uuid references public.groups(id) on delete set null,
    cycle_month  int,
    note         text,
    hmac         text,                           -- signed by PASSPORT_HMAC_SECRET → verifiable outside Kitty
    created_at   timestamptz not null default now()
);

create index if not exists reputation_events_user_idx on public.reputation_events(user_id, created_at desc);

alter table public.reputation_events enable row level security;
create policy reputation_self_read on public.reputation_events
    for select using (user_id = auth.uid());

alter publication supabase_realtime add table public.reputation_events;
