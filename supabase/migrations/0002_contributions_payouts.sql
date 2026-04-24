-- Kitty — contribution + payout state tracking
-- Bridges bunq payment IDs to TigerBeetle pending-transfer IDs so webhooks
-- can commit (post) or void the right pending batch.

set search_path = public;

create table if not exists public.contributions (
    id                         uuid primary key default gen_random_uuid(),
    group_id                   uuid not null references public.groups(id) on delete cascade,
    user_id                    uuid not null references public.users(id),
    cycle_month                int  not null,
    amount_cents               bigint not null,
    bunq_request_inquiry_id    text,
    bunq_payment_id            text,
    tb_pending_pool_id         numeric(39,0),   -- uint128 as decimal
    tb_pending_member_id       numeric(39,0),
    status                     text not null default 'pending',   -- pending | posted | voided
    created_at                 timestamptz not null default now(),
    posted_at                  timestamptz
);

create index if not exists contributions_group_status_idx
    on public.contributions(group_id, status);
create index if not exists contributions_bunq_request_idx
    on public.contributions(bunq_request_inquiry_id);
create index if not exists contributions_bunq_payment_idx
    on public.contributions(bunq_payment_id);

create table if not exists public.payouts (
    id                 uuid primary key default gen_random_uuid(),
    group_id           uuid not null references public.groups(id) on delete cascade,
    recipient_user_id  uuid not null references public.users(id),
    cycle_month        int  not null,
    amount_cents       bigint not null,
    tb_transfer_ids    text[] not null default '{}',
    bunq_payment_id    text,
    status             text not null default 'pending',   -- pending | committed | failed
    created_at         timestamptz not null default now(),
    committed_at       timestamptz
);

create index if not exists payouts_group_cycle_idx
    on public.payouts(group_id, cycle_month);

alter table public.contributions enable row level security;
alter table public.payouts       enable row level security;

create policy contributions_member_read on public.contributions
    for select using (
        group_id in (select group_id from public.members where user_id = auth.uid())
    );

create policy payouts_member_read on public.payouts
    for select using (
        group_id in (select group_id from public.members where user_id = auth.uid())
    );

alter publication supabase_realtime add table public.contributions;
alter publication supabase_realtime add table public.payouts;
