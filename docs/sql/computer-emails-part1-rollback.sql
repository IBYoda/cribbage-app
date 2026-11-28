-- Computer accounts' login emails: ROLLBACK of
-- docs/sql/computer-emails-part1.sql. Run in the Supabase Dashboard -> SQL
-- Editor. Kept here for reference/history.
--
-- STATUS: NOT RUN -- kept for reference only. Part 1 was applied on
-- 2026-11-27 and verified (ALL 11 CHECKS PASSED).
--
-- WHAT IT DOES: puts the EXACT old emails back, for exactly these four
-- users, in the same three places part 1 changed, and nothing else:
--
--   level   name      user id                               now -> back to
--   easy    Shortbus  aa89a842-ecf7-407a-9581-a794968c3aa2  shortbus@raynewood.com -> shortbus@yodawood.com
--   casual  Normie    14fec049-681d-47c5-81de-a176f9c59ed1  normie@raynewood.com   -> normie@yodawood.com
--   medium  Rainman   740523b1-816f-4208-95c9-0d720238fd77  rainman@raynewood.com  -> rainman@yodawood.com
--   hard    God       3acbe000-f905-4e6a-9f5c-de22d87efd50  god@raynewood.com      -> god@yodawood.com
--
--   * auth.users.email;
--   * raw_user_meta_data's "email" key, only where it exists (part 1 set it
--     only where it already existed, so a key part 1 never wrote stays
--     missing);
--   * the 'email' identity's identity_data "email" (the generated
--     auth.identities.email follows).
--   No id, password, confirmed status, token or other column; no other user.
--
-- It is part 1's own transaction with the two email lists swapped: in the
-- code below "old" means part 1's raynewood.com email and "new" the
-- yodawood.com one it replaced. The same GUARD runs first (locks; the four
-- have exactly the raynewood.com emails; computer_accounts unchanged; the
-- yodawood.com emails held by no other user or identity; nothing in flight;
-- no sessions; metadata absent or part 1's email; one current-format
-- identity each; generated identities.email; UPDATE privilege; no UPDATE
-- trigger), then the updates (one row each, counted), then the same
-- after-checks (the old emails everywhere; every other column of the four
-- and of their identities untouched; every other user's emails untouched).
-- NOT RE-RUNNABLE: once the yodawood.com emails are back the guard STOPs.
-- A failed run changes nothing (one transaction).
--
-- Only worth running while yodawood.com is still yours: the whole point of
-- part 1 is that these accounts should not depend on it.
--
-- AFTER IT: computer-emails-precheck.sql should say "before part 1" with no
-- STOP rows, and its two "others" fingerprints should match the ones it
-- showed before part 1 (unless someone signed up in between).

begin;

do $$
declare
  v_levels text[] := array['easy', 'casual', 'medium', 'hard'];
  v_ids uuid[] := array[
    'aa89a842-ecf7-407a-9581-a794968c3aa2',
    '14fec049-681d-47c5-81de-a176f9c59ed1',
    '740523b1-816f-4208-95c9-0d720238fd77',
    '3acbe000-f905-4e6a-9f5c-de22d87efd50']::uuid[];
  -- In this file "old" is what part 1 wrote and "new" is what it replaced.
  v_old text[] := array['shortbus@raynewood.com', 'normie@raynewood.com', 'rainman@raynewood.com', 'god@raynewood.com'];
  v_new text[] := array['shortbus@yodawood.com', 'normie@yodawood.com', 'rainman@yodawood.com', 'god@yodawood.com'];
  v_n int;
  v_txt text;
  v_gen "char";
  v_four_before text;
  v_four_after text;
  v_others_before text;
  v_others_after text;
  i int;
begin
  -- ==== 0. GUARD =================================================================
  -- Lock the four users' rows and their identities first: nothing changes
  -- them between the checks and the updates.
  perform 1 from auth.users u where u.id = any (v_ids) for update;
  perform 1 from auth.identities ii where ii.user_id = any (v_ids) for update;

  -- Not re-runnable: once the yodawood.com emails are back, nothing to do.
  select count(*) into v_n from auth.users u
  where u.id = any (v_ids) and u.email = any (v_new);
  if v_n > 0 then
    raise exception 'STOP: the rollback has already run, or part 1 never did (% of the four have a yodawood.com email). Changed nothing.', v_n;
  end if;

  -- This role may update both tables.
  if not has_table_privilege(current_user, 'auth.users', 'UPDATE')
     or not has_table_privilege(current_user, 'auth.identities', 'UPDATE') then
    raise exception 'STOP: % may not UPDATE auth.users and auth.identities; use the Admin API instead. Changed nothing.', current_user;
  end if;

  -- No trigger on either table fires on UPDATE (or TRUNCATE).
  select string_agg(c.relname || '.' || tg.tgname, ', ') into v_txt
  from pg_trigger tg
  join pg_class c on c.oid = tg.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'auth' and c.relname in ('users', 'identities') and not tg.tgisinternal
    and ((tg.tgtype & 16) <> 0 or (tg.tgtype & 32) <> 0);
  if v_txt is not null then
    raise exception 'STOP: trigger(s) fire on UPDATE of auth.users or auth.identities: %. Part 1 does not account for them; changed nothing.', v_txt;
  end if;

  -- auth.identities.email: generated, or absent.
  select att.attgenerated into v_gen
  from pg_attribute att
  where att.attrelid = 'auth.identities'::regclass and att.attname = 'email' and not att.attisdropped;
  if found and v_gen is distinct from 's' then
    raise exception 'STOP: auth.identities.email is a plain column, not generated; part 1 does not account for it. Changed nothing.';
  end if;

  -- The computer accounts are exactly these four, at these levels.
  select count(*) into v_n from public.computer_accounts ca
  where (ca.level, ca.user_id) in (select l, u from unnest(v_levels, v_ids) as x(l, u));
  if v_n <> 4 or (select count(*) from public.computer_accounts) <> 4 then
    raise exception 'STOP: public.computer_accounts does not hold exactly these four ids at easy, casual, medium, hard. Changed nothing.';
  end if;

  for i in 1 .. 4 loop
    -- Present, with exactly the old email, not SSO.
    select count(*) into v_n from auth.users u
    where u.id = v_ids[i] and u.email = v_old[i] and not coalesce(u.is_sso_user, false);
    if v_n <> 1 then
      raise exception 'STOP: user % (%) is missing, an SSO user, or does not have exactly the email %. Changed nothing.',
        v_ids[i], v_levels[i], v_old[i];
    end if;

    -- The new email is free; the old one is nobody else's.
    if exists (select 1 from auth.users u where lower(u.email) = v_new[i] and u.id <> v_ids[i]) then
      raise exception 'STOP: another auth user already has %. Changed nothing.', v_new[i];
    end if;
    if exists (select 1 from auth.identities ii where ii.user_id <> v_ids[i]
                 and (lower(ii.identity_data ->> 'email') = v_new[i] or lower(ii.provider_id) = v_new[i])) then
      raise exception 'STOP: another identity already names %. Changed nothing.', v_new[i];
    end if;
    if exists (select 1 from auth.users u where lower(u.email) = v_old[i] and u.id <> v_ids[i]) then
      raise exception 'STOP: another auth user has % (part 1 could not be run again afterwards). Changed nothing.', v_old[i];
    end if;

    -- Nothing in flight.
    select count(*) into v_n from auth.users u
    where u.id = v_ids[i]
      and coalesce(u.email_change, '') = ''
      and coalesce(u.email_change_token_new, '') = ''
      and coalesce(u.email_change_token_current, '') = ''
      and coalesce(u.email_change_confirm_status, 0) = 0
      and u.email_change_sent_at is null
      and coalesce(u.confirmation_token, '') = ''
      and coalesce(u.recovery_token, '') = ''
      and coalesce(u.reauthentication_token, '') = '';
    if v_n <> 1 then
      raise exception 'STOP: something is in flight for % (an email change, or a confirmation, recovery or reauthentication token). Changed nothing.', v_old[i];
    end if;

    -- Metadata email: absent, or the old email.
    select count(*) into v_n from auth.users u
    where u.id = v_ids[i]
      and (u.raw_user_meta_data is null or not (u.raw_user_meta_data ? 'email') or u.raw_user_meta_data ->> 'email' = v_old[i]);
    if v_n <> 1 then
      raise exception 'STOP: raw_user_meta_data''s email for % is neither absent nor part 1''s email. Changed nothing.', v_old[i];
    end if;

    -- Exactly one identity, provider email, current format, old email.
    select count(*) into v_n from auth.identities ii where ii.user_id = v_ids[i];
    if v_n <> 1 then
      raise exception 'STOP: % has % identities; expected exactly one. Changed nothing.', v_old[i], v_n;
    end if;
    select count(*) into v_n from auth.identities ii
    where ii.user_id = v_ids[i] and ii.provider = 'email' and ii.provider_id = v_ids[i]::text
      and ii.identity_data ->> 'email' = v_old[i]
      and (ii.identity_data ->> 'sub' is null or ii.identity_data ->> 'sub' = v_ids[i]::text);
    if v_n <> 1 then
      raise exception 'STOP: %''s identity is not provider email / provider_id the user id / identity_data email part 1''s one. Changed nothing.', v_old[i];
    end if;
  end loop;

  -- One-time tokens (a table only on newer schemas).
  if to_regclass('auth.one_time_tokens') is not null then
    execute 'select count(*) from auth.one_time_tokens t where t.user_id = any ($1)' into v_n using v_ids;
    if v_n > 0 then
      raise exception 'STOP: % one-time token(s) (reset or confirmation links) exist for the four. Changed nothing.', v_n;
    end if;
  end if;

  -- Nobody signed in as a computer.
  if exists (select 1 from auth.sessions s where s.user_id = any (v_ids))
     or exists (select 1 from auth.refresh_tokens rt where rt.user_id in (select x::text from unnest(v_ids) x)) then
    raise exception 'STOP: sessions or refresh tokens exist for a computer account. Changed nothing.';
  end if;

  -- ---- Fingerprints, before ------------------------------------------------
  -- The four: every column but the email ones, and the rest of the jsonb.
  select string_agg(md5((to_jsonb(u) - 'email' - 'raw_user_meta_data')::text)
                    || md5(coalesce((u.raw_user_meta_data - 'email')::text, '')), ',' order by u.id)
         || ';' ||
         (select string_agg(md5((to_jsonb(ii) - 'identity_data' - 'email')::text)
                            || md5((ii.identity_data - 'email')::text), ',' order by ii.id)
          from auth.identities ii where ii.user_id = any (v_ids))
  into v_four_before
  from auth.users u where u.id = any (v_ids);
  -- Everyone else: ids and emails only (a sign-in elsewhere may change other
  -- columns at any moment; it never changes an email).
  select md5(coalesce(string_agg(u.id::text || '|' || coalesce(u.email, '') || '|' || coalesce(u.raw_user_meta_data ->> 'email', ''), E'\n' order by u.id), ''))
         || ';' ||
         (select md5(coalesce(string_agg(ii.id::text || '|' || ii.user_id::text || '|' || ii.provider || '|' || coalesce(ii.provider_id, '') || '|' || coalesce(ii.identity_data ->> 'email', ''), E'\n' order by ii.id), ''))
          from auth.identities ii where ii.user_id <> all (v_ids))
  into v_others_before
  from auth.users u where u.id <> all (v_ids);

  -- ==== 1. The updates ===========================================================
  for i in 1 .. 4 loop
    update auth.users u
    set email = v_new[i],
        raw_user_meta_data = case when u.raw_user_meta_data ? 'email'
                                  then jsonb_set(u.raw_user_meta_data, '{email}', to_jsonb(v_new[i]))
                                  else u.raw_user_meta_data end
    where u.id = v_ids[i] and u.email = v_old[i];
    get diagnostics v_n = row_count;
    if v_n <> 1 then
      raise exception 'FAIL: auth.users update for % changed % rows; expected 1. Rolled back.', v_old[i], v_n;
    end if;

    update auth.identities ii
    set identity_data = jsonb_set(ii.identity_data, '{email}', to_jsonb(v_new[i]))
    where ii.user_id = v_ids[i] and ii.provider = 'email' and ii.identity_data ->> 'email' = v_old[i];
    get diagnostics v_n = row_count;
    if v_n <> 1 then
      raise exception 'FAIL: auth.identities update for % changed % rows; expected 1. Rolled back.', v_old[i], v_n;
    end if;
  end loop;

  -- ==== 2. AFTER-CHECKS ==========================================================
  for i in 1 .. 4 loop
    select count(*) into v_n from auth.users u
    where u.id = v_ids[i] and u.email = v_new[i]
      and (u.raw_user_meta_data is null or not (u.raw_user_meta_data ? 'email') or u.raw_user_meta_data ->> 'email' = v_new[i]);
    if v_n <> 1 then
      raise exception 'FAIL: % does not have % in auth.users (email and metadata). Rolled back.', v_ids[i], v_new[i];
    end if;
    select count(*) into v_n from auth.identities ii
    where ii.user_id = v_ids[i] and ii.provider = 'email' and ii.identity_data ->> 'email' = v_new[i];
    if v_n <> 1 then
      raise exception 'FAIL: %''s identity_data email is not %. Rolled back.', v_ids[i], v_new[i];
    end if;
    if v_gen = 's' then
      execute 'select count(*) from auth.identities ii where ii.user_id = $1 and ii.email = $2' into v_n using v_ids[i], v_new[i];
      if v_n <> 1 then
        raise exception 'FAIL: the generated auth.identities.email for % is not %. Rolled back.', v_ids[i], v_new[i];
      end if;
    end if;
  end loop;

  select string_agg(md5((to_jsonb(u) - 'email' - 'raw_user_meta_data')::text)
                    || md5(coalesce((u.raw_user_meta_data - 'email')::text, '')), ',' order by u.id)
         || ';' ||
         (select string_agg(md5((to_jsonb(ii) - 'identity_data' - 'email')::text)
                            || md5((ii.identity_data - 'email')::text), ',' order by ii.id)
          from auth.identities ii where ii.user_id = any (v_ids))
  into v_four_after
  from auth.users u where u.id = any (v_ids);
  if v_four_after is distinct from v_four_before then
    raise exception 'FAIL: something other than the email changed on the four users or their identities. Rolled back.';
  end if;

  select md5(coalesce(string_agg(u.id::text || '|' || coalesce(u.email, '') || '|' || coalesce(u.raw_user_meta_data ->> 'email', ''), E'\n' order by u.id), ''))
         || ';' ||
         (select md5(coalesce(string_agg(ii.id::text || '|' || ii.user_id::text || '|' || ii.provider || '|' || coalesce(ii.provider_id, '') || '|' || coalesce(ii.identity_data ->> 'email', ''), E'\n' order by ii.id), ''))
          from auth.identities ii where ii.user_id <> all (v_ids))
  into v_others_after
  from auth.users u where u.id <> all (v_ids);
  if v_others_after is distinct from v_others_before then
    raise exception 'FAIL: another user''s or identity''s email changed during the rollback. Rolled back.';
  end if;

  raise notice 'ROLLBACK DONE: the four computer accounts have their yodawood.com emails back.';
end
$$;

commit;

-- ==== 3. Show the result (no secrets) =============================================
select ca.level, u.id, u.email, u.raw_user_meta_data ->> 'email' as metadata_email,
       ii.identity_data ->> 'email' as identity_email
from public.computer_accounts ca
join auth.users u on u.id = ca.user_id
left join auth.identities ii on ii.user_id = u.id and ii.provider = 'email'
order by case ca.level when 'easy' then 1 when 'casual' then 2 when 'medium' then 3 when 'hard' then 4 end;
