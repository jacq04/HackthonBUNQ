-- Kitty initial schema
-- Supabase Postgres. Uses built-in auth.users as the identity source.

set search_path = public;

create extension if not exists "pgcrypto";
create extension if not exists "uuid-ossp";

-- =============================================================================
-- users  (extends auth.users with app-specific profile fields)
-- =============================================================================
create table if not exists public.users (
    id             uuid primary key references auth.users(id) on delete cascade,
    display_name   text        not null default '',
    bunq_user_id   text,
    push_token     text,
    language       text        not null default 'en',
    culture_hint   text,                           -- e.g. 'susu', 'chitfund', 'tanda'
    face_id_verified_at timestamptz,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now()
);

-- =============================================================================
-- groups
-- =============================================================================
create table if not exists public.groups (
    id                     uuid primary key default gen_random_uuid(),
    name                   text not null,
    currency               text not null default 'EUR',         -- ISO 4217
    contribution_amount_cents bigint not null,
    cycle_count            int  not null,                       -- e.g. 6 members -> 6 cycles
    grace_period_days      int  not null default 3,
    penalty_bps            int  not null default 200,           -- 2%
    bunq_account_id        text,                                -- bunq monetary-account id
    tb_pool_account_id     numeric(39,0) not null,              -- TigerBeetle uint128 as decimal
    tb_gateway_account_id  numeric(39,0) not null,
    tb_penalty_account_id  numeric(39,0) not null,
    status                 text not null default 'charter',     -- charter | active | closed
    created_by             uuid references public.users(id),
    created_at             timestamptz not null default now()
);

create index if not exists groups_status_idx on public.groups(status);

-- =============================================================================
-- members
-- =============================================================================
create table if not exists public.members (
    group_id     uuid not null references public.groups(id) on delete cascade,
    user_id      uuid not null references public.users(id) on delete cascade,
    role         text not null default 'member',            -- member | admin
    status       text not null default 'pending',           -- pending | active | emergency_exited
    payout_cycle int,                                       -- which cycle this member receives
    joined_at    timestamptz not null default now(),
    tb_contrib_account_id  numeric(39,0) not null,
    tb_received_account_id numeric(39,0) not null,
    primary key (group_id, user_id)
);

-- =============================================================================
-- charters (versioned; latest is current)
-- =============================================================================
create table if not exists public.charters (
    id          uuid primary key default gen_random_uuid(),
    group_id    uuid not null references public.groups(id) on delete cascade,
    version     int  not null,
    content     jsonb not null,                             -- full rules JSON
    signed_by   uuid[] not null default '{}',
    finalized_at timestamptz,
    created_at  timestamptz not null default now(),
    unique (group_id, version)
);

-- =============================================================================
-- messages (agent + user chat in a group)
-- =============================================================================
create table if not exists public.messages (
    id          uuid primary key default gen_random_uuid(),
    group_id    uuid not null references public.groups(id) on delete cascade,
    sender_user_id uuid references public.users(id),       -- null if agent
    agent_name  text,                                       -- null if human
    channel     text not null default 'group',              -- group | private
    recipient_user_id uuid references public.users(id),    -- for private
    text        text not null,
    metadata    jsonb not null default '{}',                -- tool_calls, attachments, etc.
    created_at  timestamptz not null default now(),
    constraint chk_sender check (
        (sender_user_id is not null and agent_name is null)
     or (sender_user_id is null and agent_name is not null)
    )
);

create index if not exists messages_group_idx on public.messages(group_id, created_at desc);

-- =============================================================================
-- agent_memory (per-agent per-scope kv)
-- =============================================================================
create table if not exists public.agent_memory (
    scope_type  text not null,                              -- 'user' | 'group'
    scope_id    uuid not null,
    agent_name  text not null,
    key         text not null,
    value       jsonb not null,
    updated_at  timestamptz not null default now(),
    primary key (scope_type, scope_id, agent_name, key)
);

-- =============================================================================
-- events (source for the ledger tape; denormalized fast-read)
-- =============================================================================
create table if not exists public.events (
    id          uuid primary key default gen_random_uuid(),
    group_id    uuid not null references public.groups(id) on delete cascade,
    type        text not null,                              -- contribution.pending/posted/voided, payout.*, penalty.*, dispute.*, emergency.*
    payload     jsonb not null,
    created_at  timestamptz not null default now()
);

create index if not exists events_group_idx on public.events(group_id, created_at desc);

-- =============================================================================
-- disputes
-- =============================================================================
create table if not exists public.disputes (
    id              uuid primary key default gen_random_uuid(),
    group_id        uuid not null references public.groups(id) on delete cascade,
    claimant_user_id uuid not null references public.users(id),
    respondent_user_id uuid references public.users(id),
    amount_cents    bigint,
    status          text not null default 'open',          -- open | resolved | escalated
    evidence_urls   text[] not null default '{}',
    mediator_verdict jsonb,
    resolved_at     timestamptz,
    created_at      timestamptz not null default now()
);

-- =============================================================================
-- emergencies
-- =============================================================================
create table if not exists public.emergencies (
    id                     uuid primary key default gen_random_uuid(),
    group_id               uuid not null references public.groups(id) on delete cascade,
    user_id                uuid not null references public.users(id),
    reason                 text,
    buyout_amount_proposed_cents bigint,
    group_consent_user_ids uuid[] not null default '{}',
    status                 text not null default 'open',   -- open | approved | executed | rejected
    created_at             timestamptz not null default now(),
    resolved_at            timestamptz
);

-- =============================================================================
-- audit_log (every tool call an agent makes)
-- =============================================================================
create table if not exists public.audit_log (
    id            uuid primary key default gen_random_uuid(),
    actor         text not null,                            -- user:<uuid> | agent:<name>
    action        text not null,                            -- e.g. 'tb.transfer.post'
    resource_type text,
    resource_id   text,
    diff          jsonb not null default '{}',
    created_at    timestamptz not null default now()
);

create index if not exists audit_log_actor_idx on public.audit_log(actor, created_at desc);

-- =============================================================================
-- Row Level Security
-- =============================================================================
alter table public.users      enable row level security;
alter table public.groups     enable row level security;
alter table public.members    enable row level security;
alter table public.charters   enable row level security;
alter table public.messages   enable row level security;
alter table public.agent_memory enable row level security;
alter table public.events     enable row level security;
alter table public.disputes   enable row level security;
alter table public.emergencies enable row level security;
alter table public.audit_log  enable row level security;

-- Users: self-read, self-update
create policy users_self_read on public.users
    for select using (id = auth.uid());
create policy users_self_update on public.users
    for update using (id = auth.uid());

-- Groups: members can read
create policy groups_member_read on public.groups
    for select using (
        id in (select group_id from public.members where user_id = auth.uid())
        or created_by = auth.uid()
    );

-- Members: self + group-peers can see members of groups they're in
create policy members_read on public.members
    for select using (
        user_id = auth.uid()
        or group_id in (select group_id from public.members where user_id = auth.uid())
    );

-- Charters: visible to group members
create policy charters_member_read on public.charters
    for select using (
        group_id in (select group_id from public.members where user_id = auth.uid())
    );

-- Messages: visible to group members; private channel checks recipient
create policy messages_member_read on public.messages
    for select using (
        group_id in (select group_id from public.members where user_id = auth.uid())
        and (channel = 'group' or recipient_user_id = auth.uid() or sender_user_id = auth.uid())
    );

create policy messages_member_insert on public.messages
    for insert with check (
        sender_user_id = auth.uid()
        and group_id in (select group_id from public.members where user_id = auth.uid())
    );

-- Events: group members can read
create policy events_member_read on public.events
    for select using (
        group_id in (select group_id from public.members where user_id = auth.uid())
    );

-- Disputes: group members can read; claimant can insert
create policy disputes_member_read on public.disputes
    for select using (
        group_id in (select group_id from public.members where user_id = auth.uid())
    );
create policy disputes_claimant_insert on public.disputes
    for insert with check (
        claimant_user_id = auth.uid()
        and group_id in (select group_id from public.members where user_id = auth.uid())
    );

-- Emergencies: group members can read; self can insert
create policy emergencies_member_read on public.emergencies
    for select using (
        group_id in (select group_id from public.members where user_id = auth.uid())
    );
create policy emergencies_self_insert on public.emergencies
    for insert with check (
        user_id = auth.uid()
        and group_id in (select group_id from public.members where user_id = auth.uid())
    );

-- Service role bypasses RLS — writes from FastAPI use the service key.
-- Agent_memory + audit_log have no user-facing policies; only service role touches them.

-- =============================================================================
-- Realtime
-- =============================================================================
-- Enable realtime for the ledger tape and agent messages.
alter publication supabase_realtime add table public.events;
alter publication supabase_realtime add table public.messages;

-- =============================================================================
-- Helper: trigger to keep users.updated_at fresh
-- =============================================================================
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
    new.updated_at := now();
    return new;
end $$;

drop trigger if exists users_touch_updated on public.users;
create trigger users_touch_updated
    before update on public.users
    for each row execute procedure public.touch_updated_at();
