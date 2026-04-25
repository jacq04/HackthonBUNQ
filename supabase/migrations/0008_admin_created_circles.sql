-- 0008 — admin-created circles with full matchmaking parameters.
-- Adds the columns the Matchmaker uses to filter circles for a candidate
-- (theme, cultural fit, minimum trust). All optional/defaulted so existing
-- rows stay valid.
alter table public.groups
    add column if not exists theme            text,
    add column if not exists cultural_hint    text,
    add column if not exists min_trust_score  int  not null default 50,
    add column if not exists max_members      int,
    add column if not exists payout_strategy  text not null default 'rotation'
        check (payout_strategy in ('rotation','bidding','hybrid')),
    add column if not exists description      text;

-- An index that makes "list open circles for a candidate" fast.
create index if not exists groups_recruiting_idx
    on public.groups(status, min_trust_score)
    where status in ('recruiting','awaiting_accepts','active');
