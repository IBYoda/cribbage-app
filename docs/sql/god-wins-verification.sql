-- Wings: VERIFICATION of get_god_wins(). READ-ONLY.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER docs/sql/god-wins.sql. The
-- whole file is ONE DO block: run it as is. It only reads. It inserts, updates
-- and deletes nothing, and creates nothing, so it is safe on the live database
-- and can be run any time.
--
-- A PASS looks like this: a line "ok [V1]" and so on for each check, then
--   ALL GOD WINS CHECKS PASSED
-- A failure stops at the check that failed, with "FAIL [Vn]" and the reason.
-- "skipped" on a line means there was nothing real to check yet (no hidden
-- accounts, say): that is a pass, and it says why.
--
-- CHECKS
--   V1  The function exists, is security definer and stable, and its
--       search_path is public.
--   V2  authenticated can execute it; anon and public cannot.
--   V3  A sample of real human players returns sensible counts.
--   V4  Every player on the leaderboard: get_god_wins matches beat_god.
--   V5  Computer accounts return no row.
--   V6  Hidden accounts return no row.

do $$
declare
  v_fn constant regprocedure := to_regprocedure('public.get_god_wins(uuid[])');
  v_ids uuid[];
  v_id uuid;
  v_expected int;
  v_got int;
  v_checked int := 0;
  v_total int;
  v_row record;
begin
  -- [V1] PASS: the function is there, runs as its owner, is marked stable, and
  -- has search_path=public in its settings.
  if v_fn is null then
    raise exception 'FAIL [V1] get_god_wins(uuid[]) does not exist: run docs/sql/god-wins.sql first.';
  end if;
  if not exists (
    select 1 from pg_proc p
    where p.oid = v_fn
      and p.prosecdef
      and p.provolatile = 's'
      and 'search_path=public' = any(p.proconfig)
  ) then
    raise exception 'FAIL [V1] not security definer, stable, with search_path=public.';
  end if;
  raise notice 'ok [V1] exists, security definer, stable, search_path=public';

  -- [V2] PASS: true for authenticated, false for anon and for public.
  if not has_function_privilege('authenticated', v_fn, 'execute') then
    raise exception 'FAIL [V2] authenticated cannot execute get_god_wins.';
  end if;
  if has_function_privilege('anon', v_fn, 'execute') then
    raise exception 'FAIL [V2] anon can execute get_god_wins.';
  end if;
  if has_function_privilege('public', v_fn, 'execute') then
    raise exception 'FAIL [V2] public can execute get_god_wins.';
  end if;
  raise notice 'ok [V2] authenticated yes, anon no, public no';

  -- [V3] PASS: up to five human players who have beaten God are printed with
  -- their counts; each count is above 0, equals a direct count of their won
  -- games at God's table, and only ids that were asked for come back.
  select array_agg(x.winner_id) into v_ids
  from (
    select g.winner_id
    from public.games g
    join public.tables t on t.id = g.table_id
    where g.ended_reason = 'won'
      and t.computer_level = 'hard'
      and g.winner_id is not null
      and not exists (select 1 from public.computer_accounts ca where ca.user_id = g.winner_id)
      and not exists (select 1 from public.leaderboard_hidden h where h.user_id = g.winner_id)
    group by g.winner_id
    order by count(*) desc, g.winner_id
    limit 5
  ) x;
  if v_ids is null then
    raise notice 'ok [V3] skipped: no human has beaten God yet, so there is nothing to sample';
  else
    for v_row in select * from public.get_god_wins(v_ids) loop
      if not (v_row.user_id = any(v_ids)) then
        raise exception 'FAIL [V3] % was returned without being asked for.', v_row.user_id;
      end if;
      select count(*)::int into v_expected
      from public.games g
      join public.tables t on t.id = g.table_id
      where g.ended_reason = 'won'
        and t.computer_level = 'hard'
        and g.winner_id = v_row.user_id;
      if v_row.god_wins <= 0 or v_row.god_wins is distinct from v_expected then
        raise exception 'FAIL [V3] % has %, but a direct count gives %.', v_row.user_id, v_row.god_wins, v_expected;
      end if;
      raise notice 'sample [V3] % has % God wins', v_row.user_id, v_row.god_wins;
      v_checked := v_checked + 1;
    end loop;
    if v_checked <> array_length(v_ids, 1) then
      raise exception 'FAIL [V3] asked for % players, got %.', array_length(v_ids, 1), v_checked;
    end if;
    raise notice 'ok [V3] % sampled players, counts match the games table', v_checked;
  end if;

  -- [V4] PASS: for every player get_leaderboard() lists (it never lists hidden
  -- or computer accounts), get_god_wins returns the same number as beat_god,
  -- and no row at all where beat_god is 0.
  v_total := 0;
  for v_row in select l.user_id, l.beat_god from public.get_leaderboard() l loop
    select r.god_wins into v_got from public.get_god_wins(array[v_row.user_id]) r;
    if coalesce(v_got, 0) is distinct from v_row.beat_god then
      raise exception 'FAIL [V4] % has beat_god % but get_god_wins %.', v_row.user_id, v_row.beat_god, coalesce(v_got, 0);
    end if;
    if v_row.beat_god = 0 and v_got is not null then
      raise exception 'FAIL [V4] % has no God wins but got a row.', v_row.user_id;
    end if;
    v_total := v_total + 1;
  end loop;
  raise notice 'ok [V4] % leaderboard players match beat_god', v_total;

  -- [V5] PASS: no row for any computer account, God included, though God has
  -- won games at its own tables.
  select array_agg(ca.user_id) into v_ids from public.computer_accounts ca;
  if v_ids is null then
    raise notice 'ok [V5] skipped: there are no computer accounts';
  elsif exists (select 1 from public.get_god_wins(v_ids)) then
    raise exception 'FAIL [V5] a computer account returned a row.';
  else
    raise notice 'ok [V5] % computer accounts return no row', array_length(v_ids, 1);
  end if;

  -- [V6] PASS: no row for any hidden account, whatever they have won. Asked one
  -- at a time, because the function reads only the first 50 ids of a call.
  select array_agg(h.user_id) into v_ids from public.leaderboard_hidden h;
  if v_ids is null then
    raise notice 'ok [V6] skipped: there are no hidden accounts';
  else
    for v_id in select unnest(v_ids) loop
      if exists (select 1 from public.get_god_wins(array[v_id])) then
        raise exception 'FAIL [V6] hidden account % returned a row.', v_id;
      end if;
    end loop;
    raise notice 'ok [V6] % hidden accounts return no row', array_length(v_ids, 1);
  end if;

  raise notice 'ALL GOD WINS CHECKS PASSED';
end;
$$;
