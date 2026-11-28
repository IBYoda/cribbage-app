-- Computer accounts' login emails, yodawood.com -> raynewood.com: PRECHECK
-- (READ-ONLY).
-- Run in the Supabase Dashboard -> SQL Editor before
-- docs/sql/computer-emails-part1.sql. ONE statement; it only reads the
-- catalog and the auth tables and counts rows. Paste the whole result back.
--
-- STATUS: RUN on 2026-11-27 by Walt: clean (state "before part 1", no STOP
-- rows); its two "others" rows matched the verification's fingerprints.
--
-- WHY (Walt, 2026-11-27): Nobs! moved to raynewood.com and yodawood.com is
-- being dropped. The four computer players still sign in (nobody ever does)
-- with yodawood.com emails; if that domain lapsed, a stranger could register
-- it and reset a computer account's password. Part 1 changes ONLY the email,
-- in the three places it is kept, for these four users; ids, passwords,
-- confirmed status and tokens stay as they are:
--
--   level   name      user id                               old -> new
--   easy    Shortbus  aa89a842-ecf7-407a-9581-a794968c3aa2  shortbus@yodawood.com -> shortbus@raynewood.com
--   casual  Normie    14fec049-681d-47c5-81de-a176f9c59ed1  normie@yodawood.com   -> normie@raynewood.com
--   medium  Rainman   740523b1-816f-4208-95c9-0d720238fd77  rainman@yodawood.com  -> rainman@raynewood.com
--   hard    God       3acbe000-f905-4e6a-9f5c-de22d87efd50  god@yodawood.com      -> god@raynewood.com
--
-- NOTHING FINDS THESE ACCOUNTS BY EMAIL (checked 2026-11-27): the game
-- functions reach them through public.computer_accounts (level -> user_id),
-- and every verification suite picks accounts by id or created_at. No
-- function, test or seed script names these emails; only comments in
-- computer-normie.sql and the PRD do (fixed after this slice is reviewed).
--
-- Every row has a section, an item, a value and a note. A note starting
-- "STOP" means: do not run the next file; paste the result back. The first
-- row ("state") says where the slice stands:
--   before part 1   all four have their old emails  -> run part 1 next
--   part 1 present  all four have their new emails  -> part 1 is in
--   mixed           anything else                   -> STOP
-- An ERROR instead of a result (for example "column ... does not exist")
-- means this project's auth schema is not the one this slice was written
-- for: that is a STOP too; paste the error back.
--
-- SECTIONS
--   state     the summary above.
--   account   each of the four: present, its email now, SSO or not.
--   mapping   public.computer_accounts holds exactly these four ids at
--             these levels (the verification starts a game at each level).
--   free      each new email is held by no OTHER user (auth.users, whose
--             email is unique among non-SSO users) and by no other identity;
--             each old email by no other user either.
--   pending   nothing in flight on the four: email_change, its two tokens,
--             its confirm status and sent-at, the confirmation, recovery
--             and reauthentication tokens all empty; auth.one_time_tokens
--             has no row for them.
--   signin    no auth.sessions row and no auth.refresh_tokens row for the
--             four (nobody signs in as a computer).
--   confirmed email_confirmed_at, for the record (part 1 leaves it as it
--             is; not a STOP either way).
--   metadata  raw_user_meta_data's "email" key: absent (nothing to change)
--             or the old email (part 1 changes it); anything else STOPs.
--   identity  exactly one identity each: provider 'email', provider_id the
--             user id (the current format; an OLD-FORMAT row, whose
--             provider_id is the email, STOPs), identity_data's email the
--             old one (sub, when present, the user id); auth.identities.email
--             is a GENERATED column (derived from identity_data, so part 1
--             never writes it), or absent on an older schema.
--   access    this role may SELECT and UPDATE auth.users and
--             auth.identities, and row-level security cannot hide rows
--             from it.
--   triggers  every user trigger on auth.users and auth.identities. One that
--             fires on UPDATE (or TRUNCATE) STOPs: part 1 does not account
--             for any. One that fires only on INSERT or DELETE is listed,
--             not a STOP: part 1 only updates. (The repo's SQL creates no
--             trigger on either table.)
--   others    for the record: how many OTHER users and identities there
--             are, and an md5 of only their ids and emails (auth.users.email,
--             raw_user_meta_data's email; identities' provider, provider_id
--             and identity_data's email). The verification prints the same
--             two fingerprints: equal means no other account's email was
--             touched (they also change if someone signs up, or changes
--             their own email, in between -- then compare by hand).
--   domain    for the record: other users still on a yodawood.com email
--             (not this slice's job; a note, never a STOP).

with accts(o, level, nick, id, old_email, new_email) as (
  values
    (1, 'easy',   'Shortbus', 'aa89a842-ecf7-407a-9581-a794968c3aa2'::uuid, 'shortbus@yodawood.com', 'shortbus@raynewood.com'),
    (2, 'casual', 'Normie',   '14fec049-681d-47c5-81de-a176f9c59ed1'::uuid, 'normie@yodawood.com',   'normie@raynewood.com'),
    (3, 'medium', 'Rainman',  '740523b1-816f-4208-95c9-0d720238fd77'::uuid, 'rainman@yodawood.com',  'rainman@raynewood.com'),
    (4, 'hard',   'God',      '3acbe000-f905-4e6a-9f5c-de22d87efd50'::uuid, 'god@yodawood.com',      'god@raynewood.com')
),
cur as (
  select a.o, a.level, a.nick, a.id, a.old_email, a.new_email,
         u.id is not null as present,
         u.email,
         u.is_sso_user,
         coalesce(u.email_change, '') as email_change,
         coalesce(u.email_change_token_new, '') as tok_new,
         coalesce(u.email_change_token_current, '') as tok_current,
         coalesce(u.email_change_confirm_status, 0) as change_status,
         u.email_change_sent_at,
         coalesce(u.confirmation_token, '') as tok_confirm,
         coalesce(u.recovery_token, '') as tok_recovery,
         coalesce(u.reauthentication_token, '') as tok_reauth,
         u.email_confirmed_at,
         u.raw_user_meta_data
  from accts a
  left join auth.users u on u.id = a.id
),
st as (
  select case
           when (select count(*) from cur c where c.present and c.email = c.old_email) = 4 then 'before'
           when (select count(*) from cur c where c.present and c.email = c.new_email) = 4 then 'after'
           else 'mixed' end as s
),
idn as (
  select a.o, a.id, a.old_email, a.new_email,
         (select count(*) from auth.identities i where i.user_id = a.id) as n_all,
         (select count(*) from auth.identities i where i.user_id = a.id and i.provider = 'email') as n_email,
         (select string_agg(i.provider, ', ' order by i.provider) from auth.identities i where i.user_id = a.id) as providers,
         (select i.provider_id from auth.identities i where i.user_id = a.id and i.provider = 'email' order by i.id limit 1) as provider_id,
         (select i.identity_data ->> 'email' from auth.identities i where i.user_id = a.id and i.provider = 'email' order by i.id limit 1) as id_email,
         (select i.identity_data ->> 'sub' from auth.identities i where i.user_id = a.id and i.provider = 'email' order by i.id limit 1) as id_sub
  from accts a
),
gen as (
  select att.attgenerated as g
  from pg_attribute att
  where att.attrelid = 'auth.identities'::regclass and att.attname = 'email' and not att.attisdropped
),
trig as (
  select c.relname, tg.tgname, pn.nspname || '.' || p.proname as fn,
         (tg.tgtype & 16) <> 0 or (tg.tgtype & 32) <> 0 as on_update,
         concat_ws('/',
           case when (tg.tgtype & 4) <> 0 then 'insert' end,
           case when (tg.tgtype & 8) <> 0 then 'delete' end,
           case when (tg.tgtype & 16) <> 0 then 'update' end,
           case when (tg.tgtype & 32) <> 0 then 'truncate' end) as events
  from pg_trigger tg
  join pg_class c on c.oid = tg.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  join pg_proc p on p.oid = tg.tgfoid
  join pg_namespace pn on pn.oid = p.pronamespace
  where n.nspname = 'auth' and c.relname in ('users', 'identities') and not tg.tgisinternal
),
rls as (
  select c.relname, c.relrowsecurity,
         pg_has_role(current_user, c.relowner, 'USAGE') as owner_role,
         (select r.rolbypassrls from pg_roles r where r.rolname = current_user) as bypass
  from pg_class c
  where c.oid in ('auth.users'::regclass, 'auth.identities'::regclass)
),
others_u as (
  select count(*) as n,
         md5(coalesce(string_agg(u.id::text || '|' || coalesce(u.email, '') || '|' || coalesce(u.raw_user_meta_data ->> 'email', ''),
                                 E'\n' order by u.id), '')) as m
  from auth.users u
  where u.id not in (select a.id from accts a)
),
others_i as (
  select count(*) as n,
         md5(coalesce(string_agg(i.id::text || '|' || i.user_id::text || '|' || i.provider || '|' || coalesce(i.provider_id, '') || '|' || coalesce(i.identity_data ->> 'email', ''),
                                 E'\n' order by i.id), '')) as m
  from auth.identities i
  where i.user_id not in (select a.id from accts a)
)
select z.section, z.item, z.value, z.note
from (
  -- ==== state ======================================================================
  select 0 as s, 0 as o, 'state' as section, 'where the slice stands' as item,
         (select st.s from st) as value,
         case (select st.s from st)
           when 'before' then 'before part 1: run computer-emails-part1.sql next (if no row below says STOP)'
           when 'after' then 'part 1 present: all four have their raynewood.com emails'
           else 'STOP: mixed -- neither all four old emails nor all four new ones (see the account rows)' end as note

  union all
  -- ==== account ====================================================================
  select 1, c.o, 'account', c.level || ' ' || c.nick || ' ' || c.id::text,
         case when not c.present then '(no such user)' else c.email || case when c.is_sso_user then ' (SSO user)' else '' end end,
         case
           when not c.present then 'STOP: this user id does not exist'
           when c.is_sso_user then 'STOP: an SSO user (its email is not covered by the unique index part 1 relies on)'
           when c.email = c.old_email then 'old email, as expected before part 1'
           when c.email = c.new_email then 'new email (part 1 present)'
           else 'STOP: neither ' || c.old_email || ' nor ' || c.new_email end
  from cur c

  union all
  -- ==== mapping ====================================================================
  select 2, 1, 'mapping', 'public.computer_accounts (level = user id)',
         coalesce((select string_agg(ca.level || ' = ' || ca.user_id::text, ', ' order by ca.level) from public.computer_accounts ca), '(empty)'),
         case when (select count(*) from public.computer_accounts) = 4
                   and (select count(*) from public.computer_accounts ca join accts a on a.level = ca.level and a.id = ca.user_id) = 4
                then 'as expected: the four ids at easy, casual, medium, hard'
              else 'STOP: computer_accounts does not hold exactly these four ids at these levels' end
  union all
  select 2, 2, 'mapping', 'profiles nicknames (for the record)',
         (select string_agg(a.level || ' ' || coalesce(p.nickname, '(no profile)'), ', ' order by a.o)
          from accts a left join public.profiles p on p.id = a.id),
         'expected Shortbus, Normie, Rainman, God; not a STOP (part 1 does not touch profiles)'

  union all
  -- ==== free =======================================================================
  select 3, c.o, 'free', c.new_email || ' / ' || c.old_email,
         'other users ' || (select count(*) from auth.users u where lower(u.email) = c.new_email and u.id <> c.id)::text
         || ', other identities ' || (select count(*) from auth.identities i
                                       where i.user_id <> c.id
                                         and (lower(i.identity_data ->> 'email') = c.new_email or lower(i.provider_id) = c.new_email))::text
         || ' / old email elsewhere ' || (select count(*) from auth.users u where lower(u.email) = c.old_email and u.id <> c.id)::text,
         case when exists (select 1 from auth.users u where lower(u.email) = c.new_email and u.id <> c.id)
                then 'STOP: another auth user already has ' || c.new_email
              when exists (select 1 from auth.identities i where i.user_id <> c.id
                             and (lower(i.identity_data ->> 'email') = c.new_email or lower(i.provider_id) = c.new_email))
                then 'STOP: another identity already names ' || c.new_email
              when exists (select 1 from auth.users u where lower(u.email) = c.old_email and u.id <> c.id)
                then 'STOP: another auth user has ' || c.old_email || ' (the rollback could not put it back)'
              else 'free: no other user or identity holds it' end
  from cur c

  union all
  -- ==== pending ====================================================================
  select 4, c.o, 'pending', c.nick || ': email_change, change tokens, confirm status, sent at, confirmation/recovery/reauth tokens',
         case when c.email_change = '' and c.tok_new = '' and c.tok_current = '' and c.change_status = 0
                   and c.email_change_sent_at is null and c.tok_confirm = '' and c.tok_recovery = '' and c.tok_reauth = ''
                then 'all empty'
              else concat_ws(', ',
                     case when c.email_change <> '' then 'email_change set' end,
                     case when c.tok_new <> '' then 'email_change_token_new set' end,
                     case when c.tok_current <> '' then 'email_change_token_current set' end,
                     case when c.change_status <> 0 then 'email_change_confirm_status ' || c.change_status end,
                     case when c.email_change_sent_at is not null then 'email_change_sent_at ' || c.email_change_sent_at end,
                     case when c.tok_confirm <> '' then 'confirmation_token set' end,
                     case when c.tok_recovery <> '' then 'recovery_token set' end,
                     case when c.tok_reauth <> '' then 'reauthentication_token set' end) end,
         case when not c.present then 'STOP: no such user'
              when c.email_change = '' and c.tok_new = '' and c.tok_current = '' and c.change_status = 0
                   and c.email_change_sent_at is null and c.tok_confirm = '' and c.tok_recovery = '' and c.tok_reauth = ''
                then 'nothing in flight'
              else 'STOP: something is in flight for this account (part 1 changes the email under it)' end
  from cur c
  union all
  select 4, 5, 'pending', 'auth.one_time_tokens rows for the four',
         -- Through query_to_xml, so the statement still parses on a schema
         -- without the table (the text runs only when the table is there).
         case when to_regclass('auth.one_time_tokens') is null then '(no such table)'
              else (xpath('/row/n/text()', query_to_xml(
                     'select count(*) as n from auth.one_time_tokens t where t.user_id in ('
                     || (select string_agg(quote_literal(a.id::text) || '::uuid', ', ') from accts a) || ')',
                     false, true, '')))[1]::text end,
         case when to_regclass('auth.one_time_tokens') is null then 'no table on this schema: nothing to check'
              when (xpath('/row/n/text()', query_to_xml(
                     'select count(*) as n from auth.one_time_tokens t where t.user_id in ('
                     || (select string_agg(quote_literal(a.id::text) || '::uuid', ', ') from accts a) || ')',
                     false, true, '')))[1]::text = '0'
                then 'none, as expected'
              else 'STOP: a one-time token (a reset or confirmation link) exists for one of the four' end

  union all
  -- ==== signin =====================================================================
  select 5, 1, 'signin', 'auth.sessions / auth.refresh_tokens rows for the four',
         (select count(*) from auth.sessions s where s.user_id in (select a.id from accts a))::text
         || ' / ' || (select count(*) from auth.refresh_tokens rt where rt.user_id in (select a.id::text from accts a))::text,
         case when exists (select 1 from auth.sessions s where s.user_id in (select a.id from accts a))
                   or exists (select 1 from auth.refresh_tokens rt where rt.user_id in (select a.id::text from accts a))
                then 'STOP: someone has signed in as a computer account (sessions or refresh tokens exist)'
              else 'none, as expected (nobody signs in as a computer)' end

  union all
  -- ==== confirmed ==================================================================
  select 6, c.o, 'confirmed', c.nick || ': email_confirmed_at',
         coalesce(c.email_confirmed_at::text, '(null)'),
         case when c.email_confirmed_at is not null then 'confirmed; part 1 leaves it as it is'
              else 'not confirmed; not a STOP (part 1 leaves it as it is)' end
  from cur c

  union all
  -- ==== metadata ===================================================================
  select 7, c.o, 'metadata', c.nick || ': raw_user_meta_data email',
         case when c.raw_user_meta_data is null then '(no metadata)'
              when not (c.raw_user_meta_data ? 'email') then '(no email key)'
              else coalesce(c.raw_user_meta_data ->> 'email', '(null)') end,
         case when c.raw_user_meta_data is null or not (c.raw_user_meta_data ? 'email')
                then 'absent: part 1 leaves the metadata as it is'
              when c.raw_user_meta_data ->> 'email' = c.old_email then 'the old email: part 1 changes this key only'
              when c.raw_user_meta_data ->> 'email' = c.new_email then 'the new email (part 1 present)'
              else 'STOP: an email key that is neither the old nor the new email' end
  from cur c

  union all
  -- ==== identity ===================================================================
  select 8, d.o, 'identity', 'identities of ' || d.id::text,
         d.n_all::text || ' (' || coalesce(d.providers, 'none') || '); email provider_id '
         || coalesce(case when d.provider_id = d.id::text then '= the user id' else d.provider_id end, '(none)')
         || '; identity_data email ' || coalesce(d.id_email, '(none)')
         || '; sub ' || coalesce(case when d.id_sub = d.id::text then '= the user id' else d.id_sub end, '(none)'),
         case
           when d.n_all <> 1 or d.n_email <> 1 then 'STOP: expected exactly one identity, provider email'
           when d.provider_id is distinct from d.id::text then 'STOP: an OLD-FORMAT identity (provider_id is not the user id)'
           when d.id_sub is not null and d.id_sub <> d.id::text then 'STOP: identity_data sub is not the user id'
           when d.id_email = d.old_email then 'current format, old email: part 1 changes identity_data''s email only'
           when d.id_email = d.new_email then 'current format, new email (part 1 present)'
           else 'STOP: identity_data''s email is neither the old nor the new email' end
  from idn d
  union all
  select 8, 5, 'identity', 'auth.identities.email column',
         case when not exists (select 1 from gen) then '(absent)'
              when (select g.g from gen g) = 's' then 'generated'
              else 'a plain column' end,
         case when not exists (select 1 from gen) then 'absent on this schema: nothing to change there'
              when (select g.g from gen g) = 's' then 'generated from identity_data: follows part 1''s change by itself'
              else 'STOP: a plain (writable) email column: part 1 does not account for it' end

  union all
  -- ==== access =====================================================================
  select 9, 1, 'access', 'this role (' || current_user || ') may SELECT / UPDATE auth.users',
         has_table_privilege(current_user, 'auth.users', 'SELECT')::text || ' / ' || has_table_privilege(current_user, 'auth.users', 'UPDATE')::text,
         case when has_table_privilege(current_user, 'auth.users', 'SELECT') and has_table_privilege(current_user, 'auth.users', 'UPDATE')
                then 'as needed' else 'STOP: part 1 cannot update auth.users as this role (use the Admin API instead)' end
  union all
  select 9, 2, 'access', 'this role may SELECT / UPDATE auth.identities',
         has_table_privilege(current_user, 'auth.identities', 'SELECT')::text || ' / ' || has_table_privilege(current_user, 'auth.identities', 'UPDATE')::text,
         case when has_table_privilege(current_user, 'auth.identities', 'SELECT') and has_table_privilege(current_user, 'auth.identities', 'UPDATE')
                then 'as needed' else 'STOP: part 1 cannot update auth.identities as this role (use the Admin API instead)' end
  union all
  select 9, 3, 'access', 'row-level security on auth.users / auth.identities',
         (select string_agg(r.relname || ' ' || case when r.relrowsecurity then 'on' else 'off' end, ', ' order by r.relname) from rls r),
         case when exists (select 1 from rls r where r.relrowsecurity and not r.owner_role and not coalesce(r.bypass, false))
                then 'STOP: RLS is on and this role neither owns the table nor bypasses RLS (part 1 could see no rows)'
              else 'cannot hide rows from this role' end

  union all
  -- ==== triggers ===================================================================
  select 10, 1, 'triggers', 'user triggers on auth.users / auth.identities',
         coalesce((select string_agg(t.relname || '.' || t.tgname || ' (' || t.events || ', ' || t.fn || ')', '; ' order by t.relname, t.tgname) from trig t), '(none)'),
         case when exists (select 1 from trig t where t.on_update)
                then 'STOP: a trigger fires on UPDATE (or TRUNCATE): part 1 does not account for it'
              when exists (select 1 from trig t)
                then 'only INSERT/DELETE triggers: they do not fire on part 1''s updates; not a STOP'
              else 'none, as expected' end

  union all
  -- ==== others =====================================================================
  select 11, 1, 'others', 'other users: count / md5 of ids and emails',
         (select o.n::text || ' / ' || o.m from others_u o),
         'for the record: the verification prints the same; equal = no other user''s email touched'
  union all
  select 11, 2, 'others', 'other identities: count / md5 of ids, providers and emails',
         (select o.n::text || ' / ' || o.m from others_i o),
         'for the record: the verification prints the same'

  union all
  -- ==== domain =====================================================================
  select 12, 1, 'domain', 'other users still on a yodawood.com email',
         (select count(*) from auth.users u
          where u.id not in (select a.id from accts a)
            and (lower(u.email) like '%@yodawood.com' or lower(u.email) like '%.yodawood.com'))::text,
         'for the record: not this slice''s job; never a STOP'
) z
order by z.s, z.o;
