-- Solo stats: the PRE-CHECK (read-only)
-- Run this in the Supabase Dashboard -> SQL Editor BEFORE solo-stats.sql. It
-- reads only; it changes nothing.
--
-- ONE query, so the editor shows every line in one result (it shows only the
-- last result of a multi-statement run). Columns: section, item, value, note.
--
-- WHAT TO LOOK FOR:
--   tables     three rows -- leaderboard_hidden, game_results,
--              computer_accounts -- each "exists" with its row count. If
--              one is missing the whole query instead fails with
--              'relation "public.<name>" does not exist' (later sections read
--              those tables directly): that names the dependency never run,
--              so stop.
--   computers  four rows, easy / casual / medium / hard, each with its
--              account's nickname (Shortbus, Normie, Rainman, God). A missing
--              level means computer-normie.sql is not live: stop.
--   function   get_god_wins "exists" (the verification compares against it).
--   games      per level: finished computer games (ended_reason 'won', not
--              Muggins), how many the human won, and how many have saved
--              scores (game_results, so skunks can count). For the record;
--              any number, zero included, is fine.
--   skunks     the first saved game result: skunk stats count from here.

with t(item) as (
  values ('leaderboard_hidden'), ('game_results'), ('computer_accounts')
),
lv(level, ord) as (
  values ('easy', 1), ('casual', 2), ('medium', 3), ('hard', 4)
)
select section, item, value, note
from (
  -- The three tables, and their row counts (counted only if the table exists).
  select 1 as s, 0 as o, 'tables' as section, t.item,
         case when to_regclass('public.' || t.item) is null then null
              else (xpath('/row/c/text()',
                          query_to_xml('select count(*) as c from public.' || t.item, false, true, '')))[1]::text::bigint
         end as value,
         case when to_regclass('public.' || t.item) is null then 'MISSING' else 'exists (rows)' end as note
  from t

  union all
  -- The computer accounts, one per level.
  select 2, lv.ord, 'computers', lv.level,
         null,
         coalesce((select coalesce(p.nickname, '(no profile)')
                   from public.computer_accounts ca
                   left join public.profiles p on p.id = ca.user_id
                   where ca.level = lv.level), 'MISSING')
  from lv

  union all
  select 3, 0, 'function', 'get_god_wins(uuid[])',
         null,
         case when to_regprocedure('public.get_god_wins(uuid[])') is null then 'MISSING' else 'exists' end

  union all
  -- Finished computer games per level.
  select 4, lv.ord, 'games', lv.level,
         (select count(*)
          from public.games g
          join public.tables tb on tb.id = g.table_id
          where g.ended_reason = 'won'
            and tb.computer_level = lv.level
            and not tb.is_muggins),
         (select format('human won %s; with saved scores %s',
                        count(*) filter (where g.winner_id <> ca.user_id),
                        count(*) filter (where exists (select 1 from public.game_results r where r.game_id = g.id)))
          from public.games g
          join public.tables tb on tb.id = g.table_id
          left join public.computer_accounts ca on ca.level = tb.computer_level
          where g.ended_reason = 'won'
            and tb.computer_level = lv.level
            and not tb.is_muggins)
  from lv

  union all
  select 5, 0, 'skunks', 'tracking since',
         null,
         coalesce((select min(r.created_at)::text from public.game_results r), 'no saved results yet')
) x
order by s, o;
