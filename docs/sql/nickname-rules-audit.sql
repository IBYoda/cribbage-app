-- NICKNAME RULES -- read-only audit (design step; NOT run by Claude).
-- One SELECT, writes nothing. Paste into the Supabase SQL Editor.
--
-- Lists, for every profile with a non-empty nickname:
--   1 char_rule        nicknames that would fail the PROPOSED character rule
--                      (A-Z a-z 0-9 space . - _ ' ! only; 1-30 after trim; no
--                      leading/trailing/double spaces; at least one letter or
--                      digit). detail = what is wrong, with the code points
--                      of any character outside the set.
--   2 reserved_hit     nicknames whose LOOSE skeleton contains a reserved
--                      word's loose skeleton (Admin, Administrator,
--                      Moderator, Support, Staff, Official, Raynewood).
--   3 lookalike_pair   pairs of profiles whose STRICT skeletons are equal
--                      (would refuse each other as "That nickname is taken.").
--   4 loose_only_pair  pairs equal ONLY if lower-case i also counted as l
--                      (e.g. Wait / Walt). Informational: the cost of the
--                      looser rule, which the proposal does NOT use for
--                      uniqueness.
-- Computer accounts are shown and marked (computer_a / computer_b).
-- Existing names are never changed by the proposal; this only tells us what
-- is out there before building.
--
-- STRICT skeleton, in this order:
--   1. trim; then, case-sensitively, I (capital) | 1 ! -> l
--   2. lower-case
--   3. remove space . - _ '
--   4. 0 -> o
--   5. rn -> m, then vv -> w (single left-to-right pass each)
-- LOOSE skeleton (reserved words only): the strict skeleton with i -> l.
-- To test Walt's original "remove !" variant instead: take '!' out of the
-- first translate (and its matching 'l') and add it to the separator list.

with
p as (
  select pr.id,
         pr.nickname,
         btrim(pr.nickname) as t,
         exists (select 1 from public.computer_accounts ca where ca.user_id = pr.id) as is_computer
  from public.profiles pr
  where btrim(coalesce(pr.nickname, '')) <> ''
),
s as (
  select p.*,
         replace(replace(
           translate(
             translate(
               lower(translate(p.t, 'I|1!', 'llll')),
               ' .-_''', ''),
             '0', 'o'),
           'rn', 'm'), 'vv', 'w') as skel
  from p
),
k as (
  select s.*, translate(s.skel, 'i', 'l') as loose
  from s
),
reserved(word) as (
  values ('Admin'), ('Administrator'), ('Moderator'), ('Support'),
         ('Staff'), ('Official'), ('Raynewood')
),
reserved_k as (
  select r.word,
         translate(replace(replace(
           translate(
             translate(
               lower(translate(r.word, 'I|1!', 'llll')),
               ' .-_''', ''),
             '0', 'o'),
           'rn', 'm'), 'vv', 'w'), 'i', 'l') as loose
  from reserved r
),
char_rule as (
  select k.*,
         translate(k.t,
           'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .-_''!',
           '') as leftover
  from k
)
select 1 as kind_order, 'char_rule' as kind,
       c.nickname as nickname_a, c.id as id_a, c.is_computer as computer_a,
       null::text as nickname_b, null::uuid as id_b, null::boolean as computer_b,
       concat_ws('; ',
         case when c.leftover <> '' then
           'characters outside the set: ' || (
             select string_agg(distinct 'U+' || upper(lpad(to_hex(ascii(ch)), greatest(4, length(to_hex(ascii(ch)))), '0')), ' ')
             from regexp_split_to_table(c.leftover, '') as ch)
         end,
         case when c.nickname <> c.t then 'leading/trailing space' end,
         case when position('  ' in c.t) > 0 then 'double space' end,
         case when char_length(c.t) > 30 then 'over 30 characters (' || char_length(c.t) || ')' end,
         case when c.t !~ '[A-Za-z0-9]' then 'no letter or digit' end
       ) as detail
from char_rule c
where c.leftover <> ''
   or c.nickname <> c.t
   or position('  ' in c.t) > 0
   or char_length(c.t) > 30
   or c.t !~ '[A-Za-z0-9]'

union all

select 2, 'reserved_hit',
       k.nickname, k.id, k.is_computer,
       null, null, null,
       'contains ' || string_agg(r.word, ', ' order by r.word) || ' (loose skeleton ' || k.loose || ')'
from k
join reserved_k r on position(r.loose in k.loose) > 0
group by k.nickname, k.id, k.is_computer, k.loose

union all

select 3, 'lookalike_pair',
       a.nickname, a.id, a.is_computer,
       b.nickname, b.id, b.is_computer,
       'strict skeleton ' || a.skel
from k a
join k b on b.skel = a.skel and a.id < b.id
where a.skel <> ''

union all

select 4, 'loose_only_pair',
       a.nickname, a.id, a.is_computer,
       b.nickname, b.id, b.is_computer,
       'loose skeleton ' || a.loose || ' (strict ' || a.skel || ' / ' || b.skel || ')'
from k a
join k b on b.loose = a.loose and b.skel <> a.skel and a.id < b.id
where a.loose <> ''

order by kind_order, nickname_a, nickname_b;
