-- Computer opponent: the three computer accounts (TEMPLATE)
-- Run this in the Supabase Dashboard -> SQL Editor, AFTER
-- computer-c2-engine.sql and its verification. Kept here for
-- reference/history.
--
-- ===========================================================================
-- BEFORE YOU RUN THIS -- do these first, in order:
--
--   1. In the dashboard: Authentication -> Users -> Add user -> Create new
--      user, THREE times, one per level. For each:
--        * an email address you control (or a plus-address of one), e.g.
--          you+nobs-easy@..., you+nobs-medium@..., you+nobs-hard@...;
--        * a long random password that you do not keep -- nobody ever signs
--          in as a computer;
--        * tick "Auto Confirm User".
--   2. Copy each new user's id (the UID column) and paste it below, in
--      place of PASTE-EASY-USER-ID, PASTE-MEDIUM-USER-ID and
--      PASTE-HARD-USER-ID. Keep the quotes.
--   3. Make sure none of the three is an admin, or seated at any table.
--
-- WHAT IT DOES (one transaction; re-runnable):
--   * checks the three ids: pasted in, real auth users, all different, not
--     admins, and not seated anywhere (unless already a computer account,
--     on a re-run); anything else stops it with a clear message and changes
--     nothing;
--   * writes each account's profile: nickname "Shortbus" (easy),
--     "Normie" (medium), "God" (hard), avatar left null (the app
--     shows its usual fallback); an existing profile row is overwritten;
--   * records the three in public.computer_accounts (a level already
--     recorded is pointed at the new id).
-- ===========================================================================

begin;

do $$
declare
  -- PASTE THE THREE USER IDS HERE (keep the quotes):
  v_easy_txt   text := 'PASTE-EASY-USER-ID';
  v_medium_txt text := 'PASTE-MEDIUM-USER-ID';
  v_hard_txt   text := 'PASTE-HARD-USER-ID';

  v_ids uuid[];
  v_levels text[] := array['easy', 'medium', 'hard'];
  v_names text[] := array['Shortbus', 'Normie', 'God'];
  v_txt text;
  i int;
begin
  -- Pasted in, and real uuids.
  foreach v_txt in array array[v_easy_txt, v_medium_txt, v_hard_txt] loop
    if v_txt like 'PASTE-%' then
      raise exception 'SETUP: replace the PASTE-...-USER-ID placeholders with the three user ids first.';
    end if;
    if v_txt !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'SETUP: "%" is not a user id (expected the UID from Authentication -> Users).', v_txt;
    end if;
  end loop;
  v_ids := array[v_easy_txt::uuid, v_medium_txt::uuid, v_hard_txt::uuid];

  -- All different.
  if v_ids[1] = v_ids[2] or v_ids[1] = v_ids[3] or v_ids[2] = v_ids[3] then
    raise exception 'SETUP: the three user ids must all be different.';
  end if;

  for i in 1 .. 3 loop
    -- A real auth user.
    if not exists (select 1 from auth.users u where u.id = v_ids[i]) then
      raise exception 'SETUP: no auth user has the % id %.', v_levels[i], v_ids[i];
    end if;
    -- Not an admin.
    if exists (select 1 from public.admin_users ad where ad.user_id = v_ids[i]) then
      raise exception 'SETUP: the % account % is an admin; use a fresh user.', v_levels[i], v_ids[i];
    end if;
    -- Not seated anywhere yet -- unless it is already a computer account
    -- (a re-run, once the computers have been playing).
    if exists (select 1 from public.table_members tm where tm.user_id = v_ids[i])
       and not exists (select 1 from public.computer_accounts ca where ca.user_id = v_ids[i]) then
      raise exception 'SETUP: the % account % is seated at a table; use a fresh user.', v_levels[i], v_ids[i];
    end if;
  end loop;

  for i in 1 .. 3 loop
    insert into public.profiles (id, nickname, avatar_url, updated_at)
    values (v_ids[i], v_names[i], null, now())
    on conflict (id) do update
      set nickname = excluded.nickname,
          avatar_url = null,
          updated_at = now();

    insert into public.computer_accounts (level, user_id)
    values (v_levels[i], v_ids[i])
    on conflict (level) do update
      set user_id = excluded.user_id;
  end loop;
end;
$$;

commit;

-- Afterwards (read-only): the three, with their profiles.
-- select ca.level, ca.user_id, p.nickname, p.avatar_url
-- from public.computer_accounts ca
-- left join public.profiles p on p.id = ca.user_id
-- order by array_position(array['easy', 'medium', 'hard'], ca.level);
