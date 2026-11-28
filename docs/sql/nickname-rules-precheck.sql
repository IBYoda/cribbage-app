-- NICKNAME RULES: PRECHECK (READ-ONLY). Run in the Supabase Dashboard ->
-- SQL Editor before docs/sql/nickname-rules-part1.sql, and again after it.
-- ONE statement; it only reads the catalog and the profiles. Paste the whole
-- result back.
--
-- STATUS: RUN 2026-11-28 (before and after part 1).
--
-- Every row has a section, an item, a value and a note. A note starting
-- "STOP" means: do not run the next file; paste the result back. The first
-- row ("state") says where the slice stands:
--   before part 1   -> run nickname-rules-part1.sql next
--   part 1 present  -> the rules are in (part 1 is the only part); run
--                      nickname-rules-verification.sql
--   a mixed state   -> STOP
--
-- SECTIONS
--   state     the summary above.
--   fp        profiles_nickname_lock: md5 215515390acc9b410afbd71b210d31e0
--             (LF: carriage returns removed) in BOTH states -- part 1 must
--             not touch it -- and an enabled BEFORE INSERT OR UPDATE ROW
--             trigger; profiles_nickname_rules(): absent before, part 1's
--             body (f3782effb78974e2ef65f1d8db04aa5a) after, security invoker,
--             search_path '', executable by no role.
--   trigger   every trigger on public.profiles: profiles_nickname_lock
--             alone before; plus profiles_nickname_rules after (which sorts
--             after the lock, so the lock fires first). Anything else: STOP.
--   owner     the owner of public.profiles and the role running this (part
--             1 must run as the owner).
--   table     profiles.nickname is text not null; profiles_nickname_unique_idx
--             (a valid unique index on lower(btrim(nickname))); the SELECT
--             policies (exactly one, by meaning not name: a permissive SELECT
--             policy using auth.role() = 'authenticated' -- live, "Profiles
--             are viewable by authenticated users"; the
--             trigger reads every profile as the signed-in caller).
--   computer  get_computer_profiles(): security definer, executable by
--             authenticated (the computer exemption calls it), and it returns
--             every computer account (listed).
--   grants    functions authenticated may execute in public (distinct
--             names): INFO, the same number before and after part 1 (part 1
--             adds none; 61 today; slice-e-grants-verification.sql X1 checks
--             the exact list). profiles_nickname_rules for no role: STOP if
--             not.
--   data      INFO (existing nicknames are never changed; these are only
--             the facts): every nickname that breaks the new character /
--             length / spacing rule (expected: only D$,
--             61c4672c-18f3-45b6-b6bf-a8c014a59142), every reserved-word hit,
--             every pair of profiles with the same strict skeleton, and D$'s
--             row. Computer accounts are marked.

with
fns(o, name, sig, before_lf, after_lf) as (
  values
    (1, 'profiles_nickname_lock', 'public.profiles_nickname_lock()', '215515390acc9b410afbd71b210d31e0', '215515390acc9b410afbd71b210d31e0'),
    (2, 'profiles_nickname_rules', 'public.profiles_nickname_rules()', null, 'f3782effb78974e2ef65f1d8db04aa5a')
),
fn_state as (
  select f.o, f.name, f.sig, f.before_lf, f.after_lf,
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public' and p.proname = f.name) as overloads,
         p.oid as fn_oid,
         md5(replace(p.prosrc, E'\r', '')) as m,
         p.prosecdef as definer,
         coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path='''''] as empty_path,
         case when p.oid is null then null else has_function_privilege('authenticated', p.oid, 'EXECUTE') end as auth_x,
         case when p.oid is null then null else has_function_privilege('anon', p.oid, 'EXECUTE') end as anon_x,
         case when p.oid is null then null
              else exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) end as public_x,
         case when p.oid is null or not exists (select 1 from pg_roles r where r.rolname = 'service_role') then false
              else has_function_privilege('service_role', p.oid, 'EXECUTE') end as service_x
  from fns f
  left join pg_proc p on p.oid = to_regprocedure(f.sig)
),
trg as (
  select tg.tgname::text as name,
         tg.tgenabled,
         tg.tgfoid,
         (tg.tgtype & 1) = 1 and (tg.tgtype & 2) = 2 and (tg.tgtype & 28) = 4 + 16 as before_ins_upd_row
  from pg_trigger tg
  where tg.tgrelid = 'public.profiles'::regclass and not tg.tgisinternal
),
client_fns as (
  select distinct p.proname::text as name
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.prokind in ('f', 'p')
    and not exists (select 1 from pg_depend d
                    where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
    and has_function_privilege('authenticated', p.oid, 'EXECUTE')
),
flags as (
  select
    (select f.fn_oid is not null from fn_state f where f.o = 2) as rules_fn,
    (select f.m from fn_state f where f.o = 2) as rules_m,
    exists (select 1 from trg t where t.name = 'profiles_nickname_rules') as rules_trg
),
-- The nicknames, with the strict skeleton (as part 1 and
-- nickname-rules-audit.sql) and the loose one (i -> l) before and after the
-- rn / vv step.
nick as (
  select pr.id, pr.nickname, btrim(pr.nickname) as t,
         exists (select 1 from public.computer_accounts ca where ca.user_id = pr.id) as is_computer,
         translate(translate(lower(translate(btrim(pr.nickname), 'I|1!', 'llll')), ' .-_''', ''), '0', 'o') as pre
  from public.profiles pr
  where btrim(coalesce(pr.nickname, '')) <> ''
),
sk as (
  select n.*, replace(replace(n.pre, 'rn', 'm'), 'vv', 'w') as skel
  from nick n
),
bad as (
  select s.*,
         concat_ws('; ',
           case when translate(s.nickname, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .-_''!', '') <> ''
                then 'characters outside the set' end,
           case when char_length(s.nickname) > 30 then 'over 30 characters' end,
           case when s.nickname <> s.t or strpos(s.nickname, '  ') > 0 then 'leading, trailing or double space' end,
           case when translate(s.nickname, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .-_''!', '') = ''
                     and translate(s.nickname, ' .-_''!', '') = '' then 'no letter or digit' end) as why
  from sk s
),
reserved_hits as (
  select s.id, s.nickname, s.is_computer,
         string_agg(w.word, ', ' order by w.word) as words
  from sk s
  join unnest(array['admln', 'admlnlstrator', 'moderator', 'support', 'staff', 'offlclal', 'raynewood']) as w(word)
    on strpos(translate(s.skel, 'i', 'l'), w.word) > 0 or strpos(translate(s.pre, 'i', 'l'), w.word) > 0
  group by s.id, s.nickname, s.is_computer
),
pairs as (
  select a.nickname as a_nick, a.id as a_id, a.is_computer as a_comp,
         b.nickname as b_nick, b.id as b_id, b.is_computer as b_comp, a.skel
  from sk a
  join sk b on b.skel = a.skel and a.id < b.id
  where a.skel <> ''
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== state ====================================================================
  select 0 as s, 0 as o, 'state'::text as section, 'nickname rules state'::text as item,
         ('function ' || case when f.rules_fn then 'present' else 'absent' end
          || ' | trigger ' || case when f.rules_trg then 'present' else 'absent' end
          || ' | body ' || case when f.rules_m is null then '-' when f.rules_m = 'f3782effb78974e2ef65f1d8db04aa5a' then 'part 1''s' else 'other' end)::text as value,
         (case
            when not f.rules_fn and not f.rules_trg
              then 'before part 1: run docs/sql/nickname-rules-part1.sql next (if no other row says STOP)'
            when f.rules_fn and f.rules_trg and f.rules_m = 'f3782effb78974e2ef65f1d8db04aa5a'
              then 'part 1 present: the rules are in; run docs/sql/nickname-rules-verification.sql'
            else 'STOP: a mixed state (the function without the trigger, or a body that is not part 1''s); paste the whole result back'
          end)::text as note
  from flags f

  union all
  -- ==== fp =======================================================================
  select 1, f.o, 'fp', f.sig,
         case when f.fn_oid is null then '(absent)'
              else 'md5 ' || f.m || ', definer ' || f.definer::text || ', search_path '''' ' || f.empty_path::text
                   || ', authenticated ' || f.auth_x::text || ', anon ' || f.anon_x::text
                   || ', PUBLIC ' || f.public_x::text || ', service_role ' || f.service_x::text end,
         case
           when f.overloads > 1 or (f.overloads = 1 and f.fn_oid is null) then 'STOP: another function by that name exists'
           when f.fn_oid is null and f.before_lf is null then 'before part 1: absent, as expected'
           when f.fn_oid is null then 'STOP: missing (slice E part 2 must be in)'
           when f.definer or not f.empty_path or f.auth_x or f.anon_x or f.public_x or f.service_x
             then 'STOP: must be security invoker with search_path '''' and executable by no role'
           when f.m = f.before_lf and f.m = f.after_lf then 'as expected (unchanged in both states)'
           when f.m = f.after_lf then 'after part 1: part 1''s body'
           else 'STOP: not the expected body. Capture it first: select pg_get_functiondef(''' || f.sig || '''::regprocedure);' end
  from fn_state f

  union all
  -- ==== trigger ==================================================================
  select 2, row_number() over (order by t.name)::int, 'trigger', 'profiles trigger ' || t.name,
         'enabled ' || t.tgenabled::text || ', BEFORE INSERT OR UPDATE ROW ' || t.before_ins_upd_row::text
           || ', function ' || t.tgfoid::regprocedure::text,
         case
           when t.name = 'profiles_nickname_lock' and t.tgenabled = 'O' and t.before_ins_upd_row
                and t.tgfoid = to_regprocedure('public.profiles_nickname_lock()')
             then 'as expected (slice E''s lock; fires first)'
           when t.name = 'profiles_nickname_rules' and t.tgenabled = 'O' and t.before_ins_upd_row
                and t.tgfoid = to_regprocedure('public.profiles_nickname_rules()')
             then 'after part 1: as expected (sorts after the lock)'
           else 'STOP: a trigger on profiles this slice does not know, or not as expected' end
  from trg t

  union all
  select 2, 99, 'trigger', 'profiles triggers (names)',
         coalesce((select string_agg(t.name, ', ' order by t.name) from trg t), '(none)'),
         case coalesce((select string_agg(t.name, ', ' order by t.name) from trg t), '')
           when 'profiles_nickname_lock' then 'before part 1: the lock alone'
           when 'profiles_nickname_lock, profiles_nickname_rules' then 'after part 1: the lock, then the rules'
           else 'STOP: expected profiles_nickname_lock (before) or profiles_nickname_lock, profiles_nickname_rules (after)' end

  union all
  -- ==== owner ====================================================================
  select 3, 1, 'owner', 'owner of public.profiles / this session''s role',
         (select pg_get_userbyid(c.relowner)::text from pg_class c where c.oid = 'public.profiles'::regclass) || ' / ' || current_user,
         case when (select pg_get_userbyid(c.relowner)::text from pg_class c where c.oid = 'public.profiles'::regclass) = current_user
              then 'as expected (part 1 creates the trigger as the owner)'
              else 'STOP: run part 1 as the owner of public.profiles' end

  union all
  -- ==== table ====================================================================
  select 4, 1, 'table', 'profiles.nickname',
         coalesce((select format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else '' end
                   || ' default ' || coalesce(pg_get_expr(d.adbin, d.adrelid), '(none)')
                   from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                   where a.attrelid = 'public.profiles'::regclass and a.attname = 'nickname' and not a.attisdropped), '(missing)'),
         case when (select format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else '' end
                    from pg_attribute a where a.attrelid = 'public.profiles'::regclass and a.attname = 'nickname' and not a.attisdropped) = 'text not null'
              then 'as expected' else 'STOP: expected text not null' end

  union all
  select 4, 2, 'table', 'profiles_nickname_unique_idx',
         coalesce((select pg_get_indexdef(i.indexrelid) || ' (valid ' || i.indisvalid::text || ')'
                   from pg_index i where i.indexrelid = to_regclass('public.profiles_nickname_unique_idx')), '(missing)'),
         case when exists (select 1 from pg_index i where i.indexrelid = to_regclass('public.profiles_nickname_unique_idx')
                             and i.indisunique and i.indisvalid and strpos(pg_get_indexdef(i.indexrelid), 'lower(btrim(nickname))') > 0)
              then 'as expected (kept: the backstop for exact duplicates, 23505; block_player relies on it)'
              else 'STOP: expected a valid unique index on lower(btrim(nickname))' end

  union all
  select 4, 3, 'table', 'profiles SELECT policies (name | cmd | permissive | roles | using)',
         coalesce((select string_agg(pol.policyname || ' | ' || pol.cmd || ' | ' || pol.permissive || ' | ' || array_to_string(pol.roles, ',') || ' | ' || coalesce(pol.qual, '-'), '; ')
                   from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'profiles' and pol.cmd in ('SELECT', 'ALL')), '(none)'),
         case when (select count(*) from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'profiles' and pol.cmd in ('SELECT', 'ALL')) = 1
                   and exists (select 1 from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'profiles'
                                 and pol.cmd = 'SELECT' and pol.permissive = 'PERMISSIVE'
                                 and strpos(pol.qual, 'auth.role()') > 0 and strpos(pol.qual, '''authenticated''') > 0)
              then 'as expected (any signed-in player reads every profile: the look-alike lookup sees them all)'
              else 'STOP: part 1''s guard expects exactly one SELECT/ALL policy: a permissive SELECT using auth.role() = ''authenticated''' end

  union all
  -- ==== computer =================================================================
  select 5, 1, 'computer', 'get_computer_profiles(): definer / authenticated EXECUTE',
         case when to_regprocedure('public.get_computer_profiles()') is null then '(missing)'
              else (select p.prosecdef::text from pg_proc p where p.oid = to_regprocedure('public.get_computer_profiles()'))
                   || ' / ' || has_function_privilege('authenticated', 'public.get_computer_profiles()', 'EXECUTE')::text end,
         case when to_regprocedure('public.get_computer_profiles()') is not null
                   and (select p.prosecdef from pg_proc p where p.oid = to_regprocedure('public.get_computer_profiles()'))
                   and has_function_privilege('authenticated', 'public.get_computer_profiles()', 'EXECUTE')
              then 'as expected (the computer exemption calls it as the signed-in caller)'
              else 'STOP: the computer exemption needs it, security definer and executable by authenticated' end

  union all
  select 5, 2, 'computer', 'computer accounts: in computer_accounts / returned by get_computer_profiles() / their nicknames',
         (select count(*) from public.computer_accounts)::text || ' / '
           || (select count(*) from public.get_computer_profiles() g where g.user_id in (select ca.user_id from public.computer_accounts ca))::text || ' / '
           || coalesce((select string_agg(g.nickname, ', ' order by g.nickname) from public.get_computer_profiles() g), '-'),
         case when (select count(*) from public.computer_accounts) > 0
                   and (select count(*) from public.computer_accounts)
                       = (select count(*) from public.get_computer_profiles() g where g.user_id in (select ca.user_id from public.computer_accounts ca))
              then 'as expected (expected Shortbus, Normie, Rainman, God)'
              else 'STOP: get_computer_profiles() does not return every computer account' end

  union all
  -- ==== grants ===================================================================
  select 6, 1, 'grants', 'functions authenticated may execute in public (distinct names)',
         (select count(*) from client_fns)::text,
         case when exists (select 1 from client_fns c where c.name = 'profiles_nickname_rules')
              then 'STOP: profiles_nickname_rules must be executable by no role'
              else 'INFO: the same before and after part 1 (part 1 adds none); 61 since moderation M7. slice-e-grants-verification.sql X1 checks the exact list' end

  union all
  -- ==== data =====================================================================
  select 7, 1, 'data', 'nicknames breaking the character / length / spacing rule (count)',
         (select count(*) from bad b where b.why <> '')::text,
         'INFO: expected 1 (D$). They are never changed and keep working; only a new or changed nickname is checked'

  union all
  select 7, 10 + row_number() over (order by b.nickname)::int, 'data',
         'breaks the rule: ' || b.nickname || case when b.is_computer then ' (COMPUTER)' else '' end,
         b.id::text || ': ' || b.why,
         case when b.id = '61c4672c-18f3-45b6-b6bf-a8c014a59142' then 'INFO: D$, the known one' else 'INFO: not D$; tell Walt (still left alone)' end
  from bad b
  where b.why <> ''

  union all
  select 7, 200, 'data', 'nicknames containing a reserved word (count)',
         (select count(*) from reserved_hits)::text,
         'INFO: expected 0; left alone if any'

  union all
  select 7, 200 + row_number() over (order by r.nickname)::int, 'data',
         'reserved: ' || r.nickname || case when r.is_computer then ' (COMPUTER)' else '' end,
         r.id::text || ': contains ' || r.words,
         'INFO: left alone'
  from reserved_hits r

  union all
  select 7, 400, 'data', 'pairs of profiles with the same strict skeleton (count)',
         (select count(*) from pairs)::text,
         'INFO: expected 0; both keep their names, and either may re-save it'

  union all
  select 7, 400 + row_number() over (order by p.a_nick, p.b_nick)::int, 'data',
         'look-alike pair: ' || p.a_nick || case when p.a_comp then ' (COMPUTER)' else '' end
           || ' / ' || p.b_nick || case when p.b_comp then ' (COMPUTER)' else '' end,
         p.a_id::text || ' / ' || p.b_id::text || ': skeleton ' || p.skel,
         'INFO: left alone'
  from pairs p

  union all
  select 7, 600, 'data', 'D$ (61c4672c-18f3-45b6-b6bf-a8c014a59142): nickname / changed_at',
         coalesce((select '"' || pr.nickname || '" / ' || coalesce(pr.nickname_changed_at::text, 'null')
                   from public.profiles pr where pr.id = '61c4672c-18f3-45b6-b6bf-a8c014a59142'), '(no profile)'),
         case when exists (select 1 from public.profiles pr where pr.id = '61c4672c-18f3-45b6-b6bf-a8c014a59142' and pr.nickname = 'D$')
              then 'INFO: as expected; the verification re-saves it (rolled back)'
              else 'INFO: D$ is not as expected; the verification''s D$ check (C11) will stop at SETUP' end
) z
order by z.s, z.o;
