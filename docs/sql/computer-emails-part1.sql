-- Computer accounts' login emails, yodawood.com -> raynewood.com: PART 1
-- (the only part). Run in the Supabase Dashboard -> SQL Editor. Kept here
-- for reference/history; this project has no Supabase CLI/migrations set up
-- yet.
--
-- STATUS: APPLIED on 2026-11-27 by Walt (the four accounts are on
-- raynewood.com in auth.users and identity_data). Afterwards
-- computer-emails-verification.sql: ALL 11 CHECKS PASSED, others
-- fingerprints matched the precheck; computer-normie-verification.sql 10
-- checks and computer-c2-verification.sql 81 checks passed. The rollback
-- has NOT been run.
--
-- DEPLOY ORDER:
--   1. docs/sql/computer-emails-precheck.sql      (read-only; no STOP rows,
--      state "before part 1"; keep its two "others" rows)
--   2. docs/sql/computer-emails-part1.sql         (THIS FILE)
--   3. docs/sql/computer-emails-verification.sql  ("ALL 11 CHECKS PASSED";
--      compare its two "others" fingerprints with the precheck's)
--   4. the computer regression suites, unchanged by this slice (none of
--      them reads an email): computer-normie-verification.sql (it uses the
--      REAL computer accounts) and computer-c2-verification.sql.
--   Rollback: docs/sql/computer-emails-part1-rollback.sql.
--   No app change: nothing in the app names these emails.
--
-- WHAT IT CHANGES, for exactly these four users and nothing else:
--
--   level   name      user id                               old -> new
--   easy    Shortbus  aa89a842-ecf7-407a-9581-a794968c3aa2  shortbus@yodawood.com -> shortbus@raynewood.com
--   casual  Normie    14fec049-681d-47c5-81de-a176f9c59ed1  normie@yodawood.com   -> normie@raynewood.com
--   medium  Rainman   740523b1-816f-4208-95c9-0d720238fd77  rainman@yodawood.com  -> rainman@raynewood.com
--   hard    God       3acbe000-f905-4e6a-9f5c-de22d87efd50  god@yodawood.com      -> god@raynewood.com
--
--   * auth.users.email;
--   * auth.users.raw_user_meta_data's "email" key -- ONLY where the key
--     exists (it is then the old email); a missing key stays missing;
--   * auth.identities.identity_data's "email" key, on each one's single
--     'email' identity. auth.identities.email is a GENERATED column (from
--     identity_data) and follows by itself; it is never written.
--   NOTHING ELSE: no id, no password, no confirmed status (email_confirmed_at
--   stays; confirmed_at is generated from it), no token, no updated_at, no
--   provider_id (the current format already holds the user id there), no
--   other column, no other user, nothing in public.
--   Direct SQL sends no email (Supabase's "secure email change" only runs
--   through the Auth API).
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold). The rows of both
--      tables are locked first (FOR UPDATE), then: the four users exist with
--      exactly their old emails, not SSO users; public.computer_accounts
--      holds exactly these four ids at easy, casual, medium, hard; no other
--      user or identity holds a new email (nor another user an old one);
--      nothing in flight on the four (email_change and its tokens, confirm
--      status and sent-at, confirmation/recovery/reauthentication tokens,
--      auth.one_time_tokens rows); no sessions or refresh tokens for them;
--      raw_user_meta_data's email absent or the old email; exactly one
--      identity each, provider 'email', provider_id the user id, its email
--      the old one; auth.identities.email generated (or absent); this role
--      may update both tables; no trigger on either fires on UPDATE.
--      NOT RE-RUNNABLE BY DESIGN: once the emails are new the guard STOPs
--      ("part 1 has already run"). A failed run changes nothing.
--   1. The three updates above, one row each per user, each counted.
--   2. AFTER-CHECKS (raise, rolling the whole file back, unless all hold):
--      the four have the new emails in all three places (and in the
--      generated column); for each of the four, every OTHER column of its
--      auth.users row and of its identity row, and the rest of its metadata
--      and identity_data, is byte-for-byte what it was; every OTHER user's
--      and identity's id and emails are exactly what they were.
--   3. Shows the four users' new emails (no secrets).

begin;

do $$
declare
  v_levels text[] := array['easy', 'casual', 'medium', 'hard'];
  v_ids uuid[] := array[
    'aa89a842-ecf7-407a-9581-a794968c3aa2',
    '14fec049-681d-47c5-81de-a176f9c59ed1',
    '740523b1-816f-4208-95c9-0d720238fd77',
    '3acbe000-f905-4e6a-9f5c-de22d87efd50']::uuid[];
  v_old text[] := array['shortbus@yodawood.com', 'normie@yodawood.com', 'rainman@yodawood.com', 'god@yodawood.com'];
  v_new text[] := array['shortbus@raynewood.com', 'normie@raynewood.com', 'rainman@raynewood.com', 'god@raynewood.com'];
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

  -- Not re-runnable.
  select count(*) into v_n from auth.users u
  where u.id = any (v_ids) and u.email = any (v_new);
  if v_n > 0 then
    raise exception 'STOP: part 1 has already run (% of the four already have a raynewood.com email). Not re-runnable; changed nothing.', v_n;
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
      raise exception 'STOP: another auth user has % (the rollback could not put it back). Changed nothing.', v_old[i];
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
      raise exception 'STOP: raw_user_meta_data''s email for % is neither absent nor the old email. Changed nothing.', v_old[i];
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
      raise exception 'STOP: %''s identity is not provider email / provider_id the user id / identity_data email the old one (an OLD-FORMAT row?). Changed nothing.', v_old[i];
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
    raise exception 'FAIL: another user''s or identity''s email changed during part 1. Rolled back.';
  end if;

  raise notice 'PART 1 DONE: the four computer accounts now sign in with raynewood.com emails.';
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
