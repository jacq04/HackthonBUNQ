-- 0007 — admin role for the operator control-room.
-- Hackathon-grade: a single is_admin bit on public.users gates /admin/*
-- in the backend. Service-role writes only; users see their own bit via the
-- existing users_self_read policy.
alter table public.users
    add column if not exists is_admin boolean not null default false;

create index if not exists users_is_admin_idx
    on public.users(is_admin) where is_admin = true;
