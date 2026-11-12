-- Friends, F1: the PRE-CHECK (read-only)
-- Run this in the Supabase Dashboard -> SQL Editor BEFORE follows.sql. It
-- reads only; it changes nothing.
--
-- STATUS: RUN in production on 2026-11-11, before follows.sql.
--
-- ONE query, so the editor shows every line in one result (it shows only the
-- last result of a multi-statement run). Columns: section, item, value, note.
--
-- WHAT TO LOOK FOR:
--   needs      profiles, computer_accounts, leaderboard_hidden: each "exists"
--              with its row count. If one is missing, the whole query fails
--              instead with 'relation "public.<name>" does not exist' (later
--              sections read those tables directly): stop.
--   clear      follows (table) and the five function names: each "absent".
--              "PRESENT" means something by that name exists already: stop
--              and look before running follows.sql.
--   realtime   supabase_realtime: "does not take every table" and follows
--              "not in it". "TAKES EVERY TABLE" means a new table would be
--              broadcast automatically: stop (follows.sql never adds it).
--   defaults   the default privileges this project gives NEW tables and
--              functions in public (pg_default_acl), for the record.
--              follows.sql revokes everything from the client roles
--              explicitly, so the result is the same whatever they say.
--   accounts   for the verification: how many followable accounts (a
--              nickname, not a computer, not hidden), hidden accounts and
--              nameless profiles exist. The verification needs at least four
--              followable accounts (one acting, three targets) for every
--              line; with fewer, or no hidden or nameless account, those
--              lines say "skipped" rather than pass.

with needs(item, ord) as (
  values ('profiles', 1), ('computer_accounts', 2), ('leaderboard_hidden', 3)
),
fn(item, ord) as (
  values ('_followable', 1), ('_follow_user_as', 2), ('follow_user', 3), ('unfollow_user', 4), ('get_my_follows', 5)
)
select section, item, value, note
from (
  -- The tables follows.sql reads, and their row counts.
  select 1 as s, n.ord as o, 'needs' as section, n.item,
         case when to_regclass('public.' || n.item) is null then null
              else (xpath('/row/c/text()',
                          query_to_xml('select count(*) as c from public.' || n.item, false, true, '')))[1]::text::bigint
         end as value,
         case when to_regclass('public.' || n.item) is null then 'MISSING' else 'exists (rows)' end as note
  from needs n

  union all
  -- Nothing called follows yet.
  select 2, 0, 'clear', 'follows (table)', null,
         case when to_regclass('public.follows') is null then 'absent' else 'PRESENT' end

  union all
  select 2, f.ord, 'clear', f.item || '()',
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public' and p.proname = f.item),
         case when exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                           where ns.nspname = 'public' and p.proname = f.item)
              then 'PRESENT' else 'absent' end
  from fn f

  union all
  -- The Realtime publication: not FOR ALL TABLES, and follows not in it.
  select 3, 1, 'realtime', 'supabase_realtime', null,
         coalesce((select case when pb.puballtables then 'TAKES EVERY TABLE' else 'does not take every table' end
                   from pg_publication pb where pb.pubname = 'supabase_realtime'),
                  'no such publication (fine: nothing is broadcast)')

  union all
  select 3, 2, 'realtime', 'follows in supabase_realtime',
         (select count(*) from pg_publication_tables pt
          where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = 'follows'),
         case when exists (select 1 from pg_publication_tables pt
                           where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public'
                             and pt.tablename = 'follows')
              then 'IN IT' else 'not in it' end

  union all
  -- Default privileges for new objects in public (r = tables, f = functions).
  select 4, row_number() over (order by d.defaclrole::regrole::text, d.defaclobjtype)::int, 'defaults',
         d.defaclrole::regrole::text || ' / ' ||
           case d.defaclobjtype when 'r' then 'tables' when 'f' then 'functions'
                                when 'S' then 'sequences' when 'T' then 'types' else d.defaclobjtype::text end,
         null,
         coalesce(d.defaclacl::text, '(none)')
  from pg_default_acl d
  join pg_namespace ns on ns.oid = d.defaclnamespace
  where ns.nspname = 'public'
    and d.defaclobjtype in ('r', 'f')

  union all
  -- Accounts the verification can use.
  select 5, 1, 'accounts', 'followable (nickname, not computer, not hidden)',
         (select count(*) from public.profiles p
          where btrim(coalesce(p.nickname, '')) <> ''
            and not exists (select 1 from public.computer_accounts ca where ca.user_id = p.id)
            and not exists (select 1 from public.leaderboard_hidden h where h.user_id = p.id)),
         'the verification needs 4 for every line'

  union all
  select 5, 2, 'accounts', 'hidden (leaderboard_hidden)',
         (select count(*) from public.leaderboard_hidden),
         'none: the hidden-account lines are skipped'

  union all
  select 5, 3, 'accounts', 'nameless (profile with a blank nickname, not a computer)',
         (select count(*) from public.profiles p
          where btrim(coalesce(p.nickname, '')) = ''
            and not exists (select 1 from public.computer_accounts ca where ca.user_id = p.id)),
         'none: the nameless line is skipped'
) x
order by s, o;
