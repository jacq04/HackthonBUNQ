-- Circle Lifecycle v2 — explicit state machine, invite/accept flow, mandates, cycles, bids.
-- Net-additive: adds columns and new tables. Legacy status values are kept in the CHECK
-- constraints so the existing Lagos Crew / demo seed data keeps working.

set search_path = public;

-- ────────────────────────────────────────────────────────────────────────────
-- groups — circle state machine
-- ────────────────────────────────────────────────────────────────────────────
alter table public.groups
    add column if not exists invite_buffer int default 0,
    add column if not exists accept_deadline timestamptz,
    add column if not exists starts_at date,
    add column if not exists debit_day int check (debit_day is null or (debit_day between 1 and 28));

alter table public.groups drop constraint if exists groups_status_check;
alter table public.groups add constraint groups_status_check check (
    status in (
        'recruiting', 'awaiting_accepts', 'forming_failed',
        'chartered', 'active', 'completed', 'dissolved',
        'charter', 'closed'  -- legacy values tolerated
    )
);

-- ────────────────────────────────────────────────────────────────────────────
-- members — per-member state + mandate attachment
-- ────────────────────────────────────────────────────────────────────────────
alter table public.members
    add column if not exists invited_at timestamptz default now(),
    add column if not exists accepted_charter_at timestamptz,
    add column if not exists declined_at timestamptz,
    add column if not exists mandate_id uuid,
    add column if not exists debit_day int check (debit_day is null or (debit_day between 1 and 28)),
    add column if not exists received_at timestamptz;

alter table public.members drop constraint if exists members_status_check;
alter table public.members add constraint members_status_check check (
    status in (
        'invited', 'accepted', 'active', 'received',
        'defaulted', 'exited_clean', 'emergency_exited', 'declined',
        'pending'  -- legacy
    )
);

-- ────────────────────────────────────────────────────────────────────────────
-- mandates — SEPA-style auto-debit authorization, one per user×group
-- ────────────────────────────────────────────────────────────────────────────
create table if not exists public.mandates (
    id                uuid primary key default gen_random_uuid(),
    user_id           uuid not null references public.users(id) on delete cascade,
    group_id          uuid not null references public.groups(id) on delete cascade,
    bunq_mandate_id   text,
    iban              text,
    debit_day         int not null check (debit_day between 1 and 28),
    monthly_cap_cents bigint not null check (monthly_cap_cents > 0),
    terms_version     int  not null,
    signed_at         timestamptz not null default now(),
    revoked_at        timestamptz,
    status            text not null default 'active'
                      check (status in ('active', 'revoked')),
    unique (user_id, group_id, status) deferrable initially deferred
);

-- foreign key from members.mandate_id → mandates.id (added after the table exists)
do $$ begin
    alter table public.members
        add constraint members_mandate_fk foreign key (mandate_id) references public.mandates(id)
        on delete set null;
exception
    when duplicate_object then null;
end $$;

-- ────────────────────────────────────────────────────────────────────────────
-- cycles — one row per (group, cycle_month); replaces the previous implicit use of cycle_month
-- ────────────────────────────────────────────────────────────────────────────
create table if not exists public.cycles (
    id                      uuid primary key default gen_random_uuid(),
    group_id                uuid not null references public.groups(id) on delete cascade,
    cycle_month             int not null,
    contribution_opens_at   timestamptz,
    bid_opens_at            timestamptz,
    bid_closes_at           timestamptz,
    payout_at               timestamptz,
    winner_user_id          uuid references public.users(id),
    winner_source           text check (winner_source in ('bid', 'fallback', 'scheduled')),
    winner_rationale        text,
    status                  text not null default 'scheduled'
                            check (status in ('scheduled', 'contribution_window', 'bid_window',
                                              'resolving', 'paid', 'fallback')),
    unique (group_id, cycle_month)
);

create index if not exists cycles_group_status_idx on public.cycles(group_id, status);

-- ────────────────────────────────────────────────────────────────────────────
-- bids — one bid per member per cycle
-- ────────────────────────────────────────────────────────────────────────────
create table if not exists public.bids (
    id           uuid primary key default gen_random_uuid(),
    cycle_id     uuid not null references public.cycles(id) on delete cascade,
    user_id      uuid not null references public.users(id) on delete cascade,
    urgency      text not null check (urgency in ('low', 'medium', 'high', 'critical')),
    reason       text not null,
    reason_score int  check (reason_score is null or (reason_score between 0 and 100)),
    weight       numeric(10, 4),              -- populated by Bidding agent for audit
    withdrawn_at timestamptz,
    created_at   timestamptz not null default now(),
    unique (cycle_id, user_id)
);

create index if not exists bids_cycle_idx on public.bids(cycle_id);

-- ────────────────────────────────────────────────────────────────────────────
-- RLS
-- ────────────────────────────────────────────────────────────────────────────
alter table public.mandates enable row level security;
alter table public.cycles   enable row level security;
alter table public.bids     enable row level security;

-- Reuses current_user_is_group_member(uuid) from 0005_fix_rls_recursion.sql

drop policy if exists mandates_self_read on public.mandates;
create policy mandates_self_read on public.mandates
    for select using (user_id = auth.uid());

drop policy if exists cycles_member_read on public.cycles;
create policy cycles_member_read on public.cycles
    for select using (public.current_user_is_group_member(group_id));

drop policy if exists bids_member_read on public.bids;
create policy bids_member_read on public.bids
    for select using (
        public.current_user_is_group_member(
            (select group_id from public.cycles where id = cycle_id)
        )
    );

drop policy if exists bids_self_insert on public.bids;
create policy bids_self_insert on public.bids
    for insert with check (user_id = auth.uid());

drop policy if exists bids_self_update on public.bids;
create policy bids_self_update on public.bids
    for update using (user_id = auth.uid());

-- ────────────────────────────────────────────────────────────────────────────
-- Realtime
-- ────────────────────────────────────────────────────────────────────────────
alter publication supabase_realtime add table public.mandates;
alter publication supabase_realtime add table public.cycles;
alter publication supabase_realtime add table public.bids;
