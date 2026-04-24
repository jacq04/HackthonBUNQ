-- Link each Kitty user to the bunq sandbox label they authenticated with.
-- At runtime `get_bunq_client(user.bunq_label)` loads the right cached session
-- so the backend can act on that user's behalf against bunq.

set search_path = public;

alter table public.users add column if not exists bunq_label text;

-- Only one Supabase user per bunq label — prevents two accounts claiming asha.
create unique index if not exists users_bunq_label_uniq_idx
    on public.users(bunq_label)
    where bunq_label is not null;
