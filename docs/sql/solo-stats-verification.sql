-- Solo stats: VERIFICATION of docs/sql/solo-stats.sql. READ-ONLY.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER docs/sql/solo-stats.sql.
-- STATUS: RUN in production on 2026-11-11: ALL SOLO STATS CHECKS PASSED.
-- The whole file is ONE DO block: run it as is. It only reads. It inserts,
-- updates and deletes nothing, and creates nothing, so it is safe on the
-- live database and can be run any time.
--
-- HOW IT ENDS: a PASS ends with a plain notice (no exception, nothing to roll
-- back -- nothing was written). Each check prints "ok [Sn] ...", then
--   ALL SOLO STATS CHECKS PASSED
-- A failure stops at the check that failed with an exception reading
-- "FAIL [Sn]" and the reason (the editor shows it as an error).
-- "skipped" on a line means there was nothing real to check yet (no hidden
-- accounts, say): that is a pass, and it says why.
--
-- CHECKS
--   S1  The three functions exist. get_solo_stats and get_solo_leaderboard
--       are security definer; _solo_results is not. All three are stable
--       with search_path=public.
--   S2  Grants: authenticated can execute get_solo_stats and
--       get_solo_leaderboard; anon and public cannot. Nobody (authenticated,
--       anon, public, service_role) can execute _solo_results.
--   S3  For a sample of up to 50 God winners: the God wins in
--       _solo_results, and get_solo_stats' 'hard' wins, both equal
--       get_god_wins.
--   S4  For every player get_leaderboard() lists (never hidden or computer
--       accounts): the God wins in _solo_results equal beat_god.
--   S5  Computer accounts: no row from _solo_results, get_solo_stats or any
--       level's get_solo_leaderboard.
--   S6  Hidden accounts: the same.
--   S7  An unknown level ('bogus', 'HARD', '', null) raises
--       "Unknown computer level."
--   S8  For every human who has played a computer: wins + losses across the
--       levels of get_solo_stats equal their finished computer games counted
--       an INDEPENDENT way (array_remove on games.players, no unnest, no
--       join through computer_accounts' level to the human), and wins equal
--       a plain count of winner_id.
--   S9  For each of the four levels, get_solo_leaderboard comes back ordered
--       wins desc, then losses asc, every row has a game, and every row's
--       numbers equal that player's get_solo_stats row for the level.
--   S10 Skunks: for each level, the total skunks + double skunks equal an
--       independent count from game_results (the computer's saved score at
--       90 or under in a game the human won), and total times_skunked the
--       same for the human's score in a game the computer won.

do $$
declare
  v_results constant regprocedure := to_regprocedure('public._solo_results()');
  v_stats constant regprocedure := to_regprocedure('public.get_solo_stats(uuid[])');
  v_board constant regprocedure := to_regprocedure('public.get_solo_leaderboard(text)');
  v_god constant regprocedure := to_regprocedure('public.get_god_wins(uuid[])');
  v_levels constant text[] := array['easy', 'casual', 'medium', 'hard'];
  v_level text;
  v_bad text;
  v_ids uuid[];
  v_id uuid;
  v_expected int;
  v_got int;
  v_got2 int;
  v_checked int;
  v_total int;
  v_raised boolean;
  v_prev_wins int;
  v_prev_losses int;
  v_row record;
  v_srow record;
begin
  -- [S1] PASS: all three exist with the settings above.
  if v_results is null then
    raise exception 'FAIL [S1] _solo_results() does not exist: run docs/sql/solo-stats.sql first.';
  end if;
  if v_stats is null then
    raise exception 'FAIL [S1] get_solo_stats(uuid[]) does not exist: run docs/sql/solo-stats.sql first.';
  end if;
  if v_board is null then
    raise exception 'FAIL [S1] get_solo_leaderboard(text) does not exist: run docs/sql/solo-stats.sql first.';
  end if;
  if not exists (
    select 1 from pg_proc p
    where p.oid = v_results
      and not p.prosecdef
      and p.provolatile = 's'
      and 'search_path=public' = any(p.proconfig)
  ) then
    raise exception 'FAIL [S1] _solo_results is not (invoker, stable, search_path=public).';
  end if;
  if not exists (
    select 1 from pg_proc p
    where p.oid = v_stats
      and p.prosecdef
      and p.provolatile = 's'
      and 'search_path=public' = any(p.proconfig)
  ) then
    raise exception 'FAIL [S1] get_solo_stats is not security definer, stable, with search_path=public.';
  end if;
  if not exists (
    select 1 from pg_proc p
    where p.oid = v_board
      and p.prosecdef
      and p.provolatile = 's'
      and 'search_path=public' = any(p.proconfig)
  ) then
    raise exception 'FAIL [S1] get_solo_leaderboard is not security definer, stable, with search_path=public.';
  end if;
  raise notice 'ok [S1] all three exist; the two public ones security definer, _solo_results invoker; all stable, search_path=public';

  -- [S2] PASS: true for authenticated on the two public functions; false
  -- everywhere else.
  if not has_function_privilege('authenticated', v_stats, 'execute') then
    raise exception 'FAIL [S2] authenticated cannot execute get_solo_stats.';
  end if;
  if not has_function_privilege('authenticated', v_board, 'execute') then
    raise exception 'FAIL [S2] authenticated cannot execute get_solo_leaderboard.';
  end if;
  if has_function_privilege('anon', v_stats, 'execute')
     or has_function_privilege('public', v_stats, 'execute') then
    raise exception 'FAIL [S2] anon or public can execute get_solo_stats.';
  end if;
  if has_function_privilege('anon', v_board, 'execute')
     or has_function_privilege('public', v_board, 'execute') then
    raise exception 'FAIL [S2] anon or public can execute get_solo_leaderboard.';
  end if;
  if has_function_privilege('authenticated', v_results, 'execute')
     or has_function_privilege('anon', v_results, 'execute')
     or has_function_privilege('public', v_results, 'execute') then
    raise exception 'FAIL [S2] a client role can execute _solo_results.';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role')
     and has_function_privilege('service_role', v_results, 'execute') then
    raise exception 'FAIL [S2] service_role can execute _solo_results.';
  end if;
  raise notice 'ok [S2] public functions: authenticated yes, anon no, public no; _solo_results: nobody';

  -- [S3] PASS: up to 50 human God winners (picked straight from games, the
  -- way god-wins-verification picks them), each with the same count three
  -- ways.
  if v_god is null then
    raise exception 'FAIL [S3] get_god_wins(uuid[]) does not exist: god-wins.sql should be live.';
  end if;
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
    limit 50
  ) x;
  if v_ids is null then
    raise notice 'ok [S3] skipped: no human has beaten God yet, so there is nothing to sample';
  else
    v_checked := 0;
    for v_row in select * from public.get_god_wins(v_ids) loop
      select count(*)::int into v_got
      from public._solo_results() s
      where s.user_id = v_row.user_id and s.level = 'hard' and s.won;
      select coalesce(max(st.wins), 0) into v_got2
      from public.get_solo_stats(array[v_row.user_id]) st
      where st.level = 'hard';
      if v_got is distinct from v_row.god_wins or v_got2 is distinct from v_row.god_wins then
        raise exception 'FAIL [S3] % has get_god_wins %, _solo_results %, get_solo_stats %.',
          v_row.user_id, v_row.god_wins, v_got, v_got2;
      end if;
      v_checked := v_checked + 1;
    end loop;
    if v_checked <> array_length(v_ids, 1) then
      raise exception 'FAIL [S3] sampled % players, get_god_wins returned %.', array_length(v_ids, 1), v_checked;
    end if;
    raise notice 'ok [S3] % sampled God winners: _solo_results = get_solo_stats = get_god_wins', v_checked;
  end if;

  -- [S4] PASS: every leaderboard player's beat_god equals their God wins in
  -- _solo_results.
  v_total := 0;
  for v_row in select l.user_id, l.beat_god from public.get_leaderboard() l loop
    select count(*)::int into v_got
    from public._solo_results() s
    where s.user_id = v_row.user_id and s.level = 'hard' and s.won;
    if v_got is distinct from v_row.beat_god then
      raise exception 'FAIL [S4] % has beat_god % but _solo_results gives %.', v_row.user_id, v_row.beat_god, v_got;
    end if;
    v_total := v_total + 1;
  end loop;
  raise notice 'ok [S4] % leaderboard players: beat_god matches', v_total;

  -- [S5] PASS: no computer account anywhere in the output.
  select array_agg(ca.user_id) into v_ids from public.computer_accounts ca;
  if v_ids is null then
    raise notice 'ok [S5] skipped: there are no computer accounts';
  else
    if exists (select 1 from public._solo_results() s where s.user_id = any(v_ids)) then
      raise exception 'FAIL [S5] _solo_results has a row for a computer account.';
    end if;
    if exists (select 1 from public.get_solo_stats(v_ids)) then
      raise exception 'FAIL [S5] get_solo_stats returned a row for a computer account.';
    end if;
    foreach v_level in array v_levels loop
      if exists (select 1 from public.get_solo_leaderboard(v_level) b where b.user_id = any(v_ids)) then
        raise exception 'FAIL [S5] a computer account is on the % solo leaderboard.', v_level;
      end if;
    end loop;
    raise notice 'ok [S5] % computer accounts: no row anywhere', array_length(v_ids, 1);
  end if;

  -- [S6] PASS: no hidden account anywhere in the output. Asked one at a
  -- time, because get_solo_stats reads only the first 50 ids of a call.
  select array_agg(h.user_id) into v_ids from public.leaderboard_hidden h;
  if v_ids is null then
    raise notice 'ok [S6] skipped: there are no hidden accounts';
  else
    if exists (select 1 from public._solo_results() s where s.user_id = any(v_ids)) then
      raise exception 'FAIL [S6] _solo_results has a row for a hidden account.';
    end if;
    foreach v_id in array v_ids loop
      if exists (select 1 from public.get_solo_stats(array[v_id])) then
        raise exception 'FAIL [S6] hidden account % returned a get_solo_stats row.', v_id;
      end if;
    end loop;
    foreach v_level in array v_levels loop
      if exists (select 1 from public.get_solo_leaderboard(v_level) b where b.user_id = any(v_ids)) then
        raise exception 'FAIL [S6] a hidden account is on the % solo leaderboard.', v_level;
      end if;
    end loop;
    raise notice 'ok [S6] % hidden accounts: no row anywhere', array_length(v_ids, 1);
  end if;

  -- [S7] PASS: each bad level raises exactly "Unknown computer level."
  foreach v_bad in array array['bogus', 'HARD', '', null] loop
    v_raised := false;
    begin
      perform 1 from public.get_solo_leaderboard(v_bad);
    exception when others then
      if sqlerrm <> 'Unknown computer level.' then
        raise exception 'FAIL [S7] level % raised a different error: %', coalesce(quote_literal(v_bad), 'null'), sqlerrm;
      end if;
      v_raised := true;
    end;
    if not v_raised then
      raise exception 'FAIL [S7] level % did not raise.', coalesce(quote_literal(v_bad), 'null');
    end if;
  end loop;
  raise notice 'ok [S7] bogus, HARD, empty and null all raise "Unknown computer level."';

  -- [S8] PASS: for every human who has been seated in a game with a
  -- computer, the totals match the independent count. The independent rule:
  -- a won, non-Muggins game with exactly two players, the human one of them,
  -- and the OTHER player (array_remove) being the computer whose level is
  -- the table's computer_level.
  v_total := 0;
  for v_id in
    select distinct p.uid
    from public.games g
    cross join lateral unnest(g.players) as p(uid)
    where exists (select 1 from public.computer_accounts ca where ca.user_id = any(g.players))
      and not exists (select 1 from public.computer_accounts ca where ca.user_id = p.uid)
      and not exists (select 1 from public.leaderboard_hidden h where h.user_id = p.uid)
  loop
    select count(*)::int,
           count(*) filter (where g.winner_id = v_id)::int
    into v_expected, v_got2
    from public.games g
    join public.tables t on t.id = g.table_id
    where g.ended_reason = 'won'
      and not t.is_muggins
      and v_id = any(g.players)
      and array_length(g.players, 1) = 2
      and g.winner_id = any(g.players)
      and (array_remove(g.players, v_id))[1] = (
        select ca.user_id from public.computer_accounts ca where ca.level = t.computer_level
      );
    select coalesce(sum(st.wins + st.losses), 0)::int,
           coalesce(sum(st.wins), 0)::int
    into v_got, v_checked
    from public.get_solo_stats(array[v_id]) st;
    if v_got is distinct from v_expected then
      raise exception 'FAIL [S8] % has % wins + losses in get_solo_stats, % finished computer games counted independently.',
        v_id, v_got, v_expected;
    end if;
    if v_checked is distinct from v_got2 then
      raise exception 'FAIL [S8] % has % wins in get_solo_stats, % by winner_id.', v_id, v_checked, v_got2;
    end if;
    v_total := v_total + 1;
  end loop;
  raise notice 'ok [S8] % players: wins + losses and wins match the independent count', v_total;

  -- [S9] PASS: each level's board is ordered, has no empty row, and agrees
  -- with get_solo_stats row by row.
  foreach v_level in array v_levels loop
    v_prev_wins := null;
    v_prev_losses := null;
    v_checked := 0;
    for v_row in
      select b.user_id, b.wins, b.losses, b.skunks, b.double_skunks, b.times_skunked, b.ord
      from public.get_solo_leaderboard(v_level) with ordinality
        as b(user_id, nickname, avatar_url, wins, losses, skunks, double_skunks,
             times_skunked, beat_god, skunk_tracking_since, ord)
      order by b.ord
    loop
      if v_row.wins + v_row.losses = 0 then
        raise exception 'FAIL [S9] % on the % board has no games.', v_row.user_id, v_level;
      end if;
      if v_prev_wins is not null
         and (v_row.wins > v_prev_wins
              or (v_row.wins = v_prev_wins and v_row.losses < v_prev_losses)) then
        raise exception 'FAIL [S9] the % board is out of order at row % (% - %, after % - %).',
          v_level, v_row.ord, v_row.wins, v_row.losses, v_prev_wins, v_prev_losses;
      end if;
      select * into v_srow
      from public.get_solo_stats(array[v_row.user_id]) st
      where st.level = v_level;
      if not found
         or v_srow.wins <> v_row.wins
         or v_srow.losses <> v_row.losses
         or v_srow.skunks <> v_row.skunks
         or v_srow.double_skunks <> v_row.double_skunks
         or v_srow.times_skunked <> v_row.times_skunked then
        raise exception 'FAIL [S9] % on the % board disagrees with get_solo_stats.', v_row.user_id, v_level;
      end if;
      v_prev_wins := v_row.wins;
      v_prev_losses := v_row.losses;
      v_checked := v_checked + 1;
    end loop;
    raise notice 'ok [S9] % board: % rows, ordered wins desc then losses asc, matching get_solo_stats', v_level, v_checked;
  end loop;

  -- [S10] PASS: per level, the board's skunk totals equal a count straight
  -- from game_results. Here the loser's row is found by POSITION (the seat
  -- that is not the winner's), not by user_id <> winner_id.
  foreach v_level in array v_levels loop
    select coalesce(sum(b.skunks + b.double_skunks), 0)::int,
           coalesce(sum(b.times_skunked), 0)::int
    into v_got, v_got2
    from public.get_solo_leaderboard(v_level) b;

    select count(*) filter (where g.winner_id <> ca.user_id)::int,
           count(*) filter (where g.winner_id = ca.user_id)::int
    into v_expected, v_checked
    from public.games g
    join public.tables t on t.id = g.table_id
    join public.computer_accounts ca on ca.level = t.computer_level
    join public.game_results r
      on r.game_id = g.id
     and r.position <> array_position(g.players, g.winner_id)
    join public.profiles pr
      on pr.id = (array_remove(g.players, ca.user_id))[1]
    where t.computer_level = v_level
      and g.ended_reason = 'won'
      and not t.is_muggins
      and array_length(g.players, 1) = 2
      and ca.user_id = any(g.players)
      and g.winner_id = any(g.players)
      and r.score is not null
      and r.score <= 90
      and btrim(coalesce(pr.nickname, '')) <> ''
      and not exists (select 1 from public.computer_accounts c2 where c2.user_id = pr.id)
      and not exists (select 1 from public.leaderboard_hidden h where h.user_id = pr.id);

    if v_got is distinct from v_expected or v_got2 is distinct from v_checked then
      raise exception 'FAIL [S10] % board: skunks % (expected %), times skunked % (expected %).',
        v_level, v_got, v_expected, v_got2, v_checked;
    end if;
    raise notice 'ok [S10] % board: % skunks given, % taken, matching game_results', v_level, v_got, v_got2;
  end loop;

  raise notice 'ALL SOLO STATS CHECKS PASSED';
end;
$$;
