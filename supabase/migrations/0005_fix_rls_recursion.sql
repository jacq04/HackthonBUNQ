-- Fix infinite recursion in RLS policies that filter by "am I a member of
-- this group?". The old policy read from public.members to decide visibility,
-- but the policy itself runs ON public.members — so every lookup re-triggers
-- the policy and blows the stack.
--
-- Solution: a SECURITY DEFINER helper that reads membership with RLS bypassed.
-- Policies call the helper instead of sub-selecting against the same table.

set search_path = public;

-- ─── Helper ──────────────────────────────────────────────────────────────
create or replace function public.current_user_is_group_member(gid uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
    select exists (
        select 1 from public.members
        where group_id = gid and user_id = auth.uid()
    );
$$;

grant execute on function public.current_user_is_group_member(uuid) to anon, authenticated;

-- ─── Rebuild every recursive policy ──────────────────────────────────────
drop policy if exists members_read on public.members;
create policy members_read on public.members
    for select using (
        user_id = auth.uid()
        or public.current_user_is_group_member(group_id)
    );

drop policy if exists groups_member_read on public.groups;
create policy groups_member_read on public.groups
    for select using (
        created_by = auth.uid()
        or public.current_user_is_group_member(id)
    );

drop policy if exists charters_member_read on public.charters;
create policy charters_member_read on public.charters
    for select using (public.current_user_is_group_member(group_id));

drop policy if exists messages_member_read on public.messages;
create policy messages_member_read on public.messages
    for select using (
        public.current_user_is_group_member(group_id)
        and (channel = 'group' or recipient_user_id = auth.uid() or sender_user_id = auth.uid())
    );

drop policy if exists messages_member_insert on public.messages;
create policy messages_member_insert on public.messages
    for insert with check (
        sender_user_id = auth.uid()
        and public.current_user_is_group_member(group_id)
    );

drop policy if exists events_member_read on public.events;
create policy events_member_read on public.events
    for select using (public.current_user_is_group_member(group_id));

drop policy if exists disputes_member_read on public.disputes;
create policy disputes_member_read on public.disputes
    for select using (public.current_user_is_group_member(group_id));

drop policy if exists disputes_claimant_insert on public.disputes;
create policy disputes_claimant_insert on public.disputes
    for insert with check (
        claimant_user_id = auth.uid()
        and public.current_user_is_group_member(group_id)
    );

drop policy if exists emergencies_member_read on public.emergencies;
create policy emergencies_member_read on public.emergencies
    for select using (public.current_user_is_group_member(group_id));

drop policy if exists emergencies_self_insert on public.emergencies;
create policy emergencies_self_insert on public.emergencies
    for insert with check (
        user_id = auth.uid()
        and public.current_user_is_group_member(group_id)
    );

drop policy if exists contributions_member_read on public.contributions;
create policy contributions_member_read on public.contributions
    for select using (public.current_user_is_group_member(group_id));

drop policy if exists payouts_member_read on public.payouts;
create policy payouts_member_read on public.payouts
    for select using (public.current_user_is_group_member(group_id));
