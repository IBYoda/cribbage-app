-- Computer opponents, Normie/Rainman: the PRE-CHECK (read-only)
-- Run this in the Supabase Dashboard -> SQL Editor BEFORE
-- computer-normie.sql. It reads only; it changes nothing.
--
-- WHAT TO LOOK FOR:
--   Query 1: two rows. computer_accounts' level check must be named
--            computer_accounts_level_check, and tables' must be named
--            tables_computer_level_check, each listing 'easy', 'medium' and
--            'hard'. A different name means computer-normie.sql needs that
--            name before it is run.
--   Query 2: exactly three rows -- easy Shortbus, medium Normie, hard God --
--            and no 'casual' row yet.
--   Query 3: at most one row, the medium computer as "Normie". Any other
--            holder of "Normie", or anyone holding "Rainman", makes the
--            rename fail (safely); sort that out first.
--   Query 4: how many tables each level has, for the record (none 'casual').

-- 1. The level check constraints.
select c.conrelid::regclass as on_table,
       c.conname,
       pg_get_constraintdef(c.oid) as definition
from pg_constraint c
where c.conrelid in ('public.computer_accounts'::regclass, 'public.tables'::regclass)
  and c.contype = 'c'
  and pg_get_constraintdef(c.oid) ilike '%level%'
order by 1, 2;

-- 2. The computer accounts today, with their profiles.
select ca.level, ca.user_id, p.nickname, p.avatar_url
from public.computer_accounts ca
left join public.profiles p on p.id = ca.user_id
order by array_position(array['easy', 'casual', 'medium', 'hard'], ca.level);

-- 3. Who holds the two names (case-insensitive, trimmed, as the unique
--    index compares them), and whether each holder is a computer.
select p.id,
       p.nickname,
       ca.level as computer_level
from public.profiles p
left join public.computer_accounts ca on ca.user_id = p.id
where lower(btrim(p.nickname)) in ('normie', 'rainman')
order by 2;

-- 4. Computer tables per level (all time).
select t.computer_level, count(*) as tables, count(*) filter (where t.status = 'open') as open_tables
from public.tables t
where t.computer_level is not null
group by t.computer_level
order by array_position(array['easy', 'casual', 'medium', 'hard'], t.computer_level);
