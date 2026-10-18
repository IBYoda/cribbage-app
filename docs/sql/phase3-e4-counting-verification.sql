-- Phase 3, step E4: VERIFICATION.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER
-- docs/sql/phase3-e4-counting.sql. The whole file is ONE DO block: run it as
-- is.
--
-- It WRITES -- it creates tables, seats players, starts games, counts whole
-- hands, deals next hands, pegs, wins and rematches, and (for the 2-player
-- proof) creates temporary copies of the OLD award_points, confirm_count and
-- show_crib plus two small read-only helpers -- and then deliberately raises
-- an exception at the very end, which rolls every write back, the temporary
-- functions included. It always "fails": the message is the verdict. "ALL n
-- CHECKS PASSED (rolled back) ..." is a pass; anything starting "FAIL" or
-- "SETUP" is not. Re-runnable, because nothing it does survives. (Same
-- pattern as phase3-e3-pegging-verification.sql.)
--
-- Same impersonation as before: request.jwt.claims plus "set local role
-- authenticated" to act as a player, "reset role" to act as the owner.
--
-- PLAYERS: A and B are the two OLDEST accounts that are NOT admins; C, D
-- and E are TEMPORARY accounts created in auth.users inside this
-- transaction, as in E1 to E3. E never sits at a table (the non-member).
--
-- THE TABLES (each started for real by A, its creator and host), seats in
-- join order, so seat 1 A, 2 B, 3 C, 4 D:
--   t2 / t2o    2 players, team_mode 'teams' (the default every live table
--               has), and its twin for the old functions
--   t2s / t2so  2 players, team_mode 'solo'
--   tm / tmo    2 players, Muggins
--   t3 / t3o    3 players
--   t4s / t4so  4 players, team_mode 'solo'
--   t4          4 players, Teams (A and C against B and D)
-- Game gX is the game at table tX.
--
-- KNOWN CARDS: every scripted hand is SET BY THE OWNER -- the dealer, each
-- player's four kept cards, the crib, the starter, the scores -- with every
-- leftover reset (status, winner, win claim, ready_by, revealed_by,
-- crib_revealed, count_step, counts, plays), at phase 'counting', count_step
-- 0 and the dealer's left to count, exactly the state play_card leaves.
-- Then each tap is made by the REAL player (the one whose turn it is, or the
-- one the script names), as that player.
--
-- THE 2-PLAYER PROOF: award_points_old (the muggins-mode.sql body,
-- verbatim), confirm_count_old and show_crib_old (the
-- phase2-batch2a-counting.sql bodies, verbatim except ONE substitution:
-- confirm_count_old calls award_points_old) are created inside this
-- transaction, and their md5s are checked against the source (S9). So the
-- old side is the whole old stack. confirm_count's body holds two non-ASCII
-- characters (a middle dot and an em dash); to keep this file ASCII they are
-- spelt {MIDDOT} and {EMDASH} below and put back with chr() before the
-- function is created -- S9's md5 proves the body is exact.
--   * W1-W5: the same award_points calls on twin tables of five kinds,
--     through the new and the old award_points, compared after EVERY call:
--     every player's score, last_points, last_reason, last_awarded_at, the
--     game's status, ended_reason and winner, and every refusal.
--   * D1-D6: the same scripted 2-player counts on twin games through the new
--     and the old confirm_count / show_crib, compared after EVERY call: the
--     games row (status, ended_reason, winner_id, phase, count_step,
--     current_player, revealed_by, crib_revealed), every table_members row,
--     and every refusal.
--   * Q1: the crib read policies, old rule against what the live policies
--     return, for both players in all 96 states of a 2-player game.
-- No scripted hand can pass vacuously: its refusals must be exactly the
-- ones it names, and it must end where it says (counted to 'done', or won).
--
-- WHAT IT CHECKS
--   S  catalog: the three new bodies (md5); every other function unchanged
--      (md5), play_card (E3) and E1-E3 included; 14 client functions, none
--      for anon; the crib policy changed exactly as described, every other
--      game_hands / game_cribs policy still there; the old copies exact.
--   W  award_points, old vs new, on five kinds of table.
--   Q  the crib read policy, old vs new, 2 players.
--   D  2-player counting, old vs new.
--   T  3 players: the order, every step, the crib's privacy, a win mid-count.
--   F  4 players, Teams: the order, the crib to the dealer's team, partners
--      equal, a win mid-count, his heels and a pegging win to the team, a
--      partner's hand private until the count, next hand, the rematch.
--   P  confirm_count / show_crib refusals with 3 and 4 players.
--
-- Expected message:
--   ALL 51 CHECKS PASSED (rolled back). A=... B=...

do $$
declare
  v_a uuid;
  v_b uuid;
  v_c uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid();
  v_e uuid := gen_random_uuid();
  v_codes text[];
  v_letters jsonb;
  v_names jsonb;
  v_spec jsonb;
  v_tables jsonb := '{}'::jsonb;
  v_games jsonb := '{}'::jsonb;
  v_scenarios jsonb;
  v_calls jsonb;
  v_sc jsonb;
  v_act jsonb;
  v_key text;
  v_val jsonb;
  v_t uuid;
  v_tw uuid;
  v_g uuid;
  v_g2 uuid;
  v_g3 uuid;
  v_g4 uuid;
  v_t3 uuid;
  v_t4 uuid;
  v_gid uuid;
  v_twin uuid;
  v_new uuid;
  v_pl uuid[];
  v_player uuid;
  v_who uuid;
  v_dealer uuid;
  v_op text;
  v_stepi int;
  v_label text;
  v_err text;
  v_err2 text;
  v_trace text;
  v_readers text;
  v_hs text;
  v_state text;
  v_state2 text;
  v_scores text;
  v_scores2 text;
  v_rec record;
  v_n int;
  v_n2 int;
  v_hand int;
  v_msg text;
  v_msg2 text;
  v_kind text;
  v_flag boolean;
  v_exp boolean;
  v_fn text;
  v_bad text;
  v_md5 text;
  v_expected jsonb;
  v_client text[] := array[
    'public.start_game_with_deal(uuid)', 'public.draw_cut_card(uuid)', 'public.acknowledge_deal_cut(uuid)',
    'public.discard_to_crib(uuid, text[])', 'public.play_card(uuid, text)', 'public.leave_table(uuid)',
    'public.show_hand(uuid)', 'public.show_crib(uuid)', 'public.confirm_count(uuid, int)',
    'public.next_hand(uuid, int)', 'public.claim_win(uuid)', 'public.clear_win_claim(uuid)',
    'public.confirm_win(uuid)', 'public.set_seat(uuid, uuid, int)'
  ];
  v_checks int := 0;
begin
  -- ---- Setup, as the owner ------------------------------------------------
  select u.id into v_a from auth.users u
  where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
  order by u.created_at limit 1;
  select u.id into v_b from auth.users u
  where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
  order by u.created_at offset 1 limit 1;
  if v_a is null or v_b is null then
    raise exception 'SETUP: the project needs at least two accounts that are not admins.';
  end if;

  begin
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
      (v_c, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e4-c-' || v_c || '@verification.invalid', now(), now()),
      (v_d, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e4-d-' || v_d || '@verification.invalid', now(), now()),
      (v_e, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e4-e-' || v_e || '@verification.invalid', now(), now());
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts C, D and E in auth.users: % (%).', sqlerrm, sqlstate;
  end;

  -- Letters for the readable strings.
  v_letters := jsonb_build_object('A', v_a, 'B', v_b, 'C', v_c, 'D', v_d, 'E', v_e);
  v_names := jsonb_build_object(v_a::text, 'A', v_b::text, 'B', v_c::text, 'C', v_d::text, 'D', v_e::text, 'E');

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0'))
    order by n
    limit 11
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 11 then
    raise exception 'SETUP: fewer than eleven unused table codes.';
  end if;

  -- ==== S: catalog, as the owner ==============================================
  -- [S1]-[S3] The three E4 bodies (md5 of the body between the dollar
  -- quotes, line endings normalised).
  select md5(replace(p.prosrc, E'\r', '')) into v_md5
  from pg_proc p where p.oid = 'public.award_points(uuid, uuid, int, text)'::regprocedure;
  if v_md5 is distinct from '5da5163549f3c69f71aeec461fc49a73' then
    raise exception 'FAIL [S1] award_points has md5 %, expected the phase3-e4-counting.sql version 5da5163549f3c69f71aeec461fc49a73.', v_md5;
  end if;
  v_checks := v_checks + 1;

  select md5(replace(p.prosrc, E'\r', '')) into v_md5
  from pg_proc p where p.oid = 'public.confirm_count(uuid, int)'::regprocedure;
  if v_md5 is distinct from 'cc85c25a2a25fe4f91ab8ea39f3aab94' then
    raise exception 'FAIL [S2] confirm_count has md5 %, expected the phase3-e4-counting.sql version cc85c25a2a25fe4f91ab8ea39f3aab94.', v_md5;
  end if;
  v_checks := v_checks + 1;

  select md5(replace(p.prosrc, E'\r', '')) into v_md5
  from pg_proc p where p.oid = 'public.show_crib(uuid)'::regprocedure;
  if v_md5 is distinct from '0005309db8568708bac13aa169bd91b3' then
    raise exception 'FAIL [S3] show_crib has md5 %, expected the phase3-e4-counting.sql version 0005309db8568708bac13aa169bd91b3.', v_md5;
  end if;
  v_checks := v_checks + 1;

  -- [S4] Every other function is unchanged: its newest docs/sql body.
  v_expected := jsonb_build_object(
    'public.play_card(uuid, text)',                  'cad9e43a7803fdb50eb4d3dd6b5c7210',  -- phase3-e3-pegging.sql
    'public.start_game_with_deal(uuid)',             '3feaa7508cf434b4a3f8d78a8ad9896a',  -- phase3-e2-dealing.sql
    'public.deal_cards_for_game(uuid)',              '1da0902352ffe6729ec663e6265374a2',  -- phase3-e2-dealing.sql
    'public.discard_to_crib(uuid, text[])',          '69ab74268ce6c799c40777436a8cfafd',  -- phase3-e2-dealing.sql
    'public.next_hand(uuid, int)',                   '9007931d5f4cc4ac127c9c2dfd7c1178',  -- phase3-e2-dealing.sql
    'public.draw_cut_card(uuid)',                    '2ca8d114de4e45861e21c23b2e4b65f8',  -- phase2-slice-5-cut-before-deal.sql
    'public.acknowledge_deal_cut(uuid)',             '5b06eec819234121db1bf802ea462c02',  -- phase2-slice-5-cut-before-deal.sql
    'public.has_legal_play(uuid, uuid, int)',        'a269d55520a89d4a8af9aff2a112aa4e',  -- phase2-slice-7-pegging-turns.sql
    'public.score_pegging(text[])',                  'f5259ad8cc24026bddeeda88b20b3b09',  -- phase2-batch1-scoring-engines.sql
    'public.card_play_value(text)',                  '50e1fc5f0404084b38fd6c9636e1fe2d',  -- phase2-slice-7-pegging-turns.sql
    'public.card_rank_value(text)',                  'e4d19acb78fef56594c4998e20bc1090',  -- phase2-slice-4-cut-for-starter.sql
    'public.score_hand(text[], text, boolean)',      '302855ebab0a54717110043ddff8564b',  -- phase2-batch1-scoring-engines.sql
    'public.shuffled_deck()',                        'edcf96f4c9cc19f59e9606b5867bc733',  -- phase2-slice-4-cut-for-starter.sql
    'public.show_hand(uuid)',                        'ae5bd9553c21de7a395504f9d39977b6',  -- phase2-batch2a-counting.sql
    'public.leave_table(uuid)',                      '9c15b86bd236e9ffb108e9318251c5b8',  -- phase2-slice-5-cut-before-deal.sql
    'public.end_timed_out_sessions()',               'd46b95e2f27b93f2707d050de560720f',  -- phase2-slice-5-cut-before-deal.sql
    'public.claim_win(uuid)',                        'd95da0d7dc9477a460955749a36164bb',  -- muggins-mode.sql
    'public.clear_win_claim(uuid)',                  '0c4500259a1bb0fed638dce79944fab5',  -- muggins-mode.sql
    'public.confirm_win(uuid)',                      'ea2ec622a2cef0fffcc255257c816d94',  -- muggins-mode.sql
    'public.set_seat(uuid, uuid, int)',              '9839026aa3f3b5d8d72281aeeac499d6',  -- phase3-e1-seating.sql
    'public.seat_team(int)',                         '497c9983cf20d23e52da11ea79768605',  -- phase3-e1-seating.sql
    'public.table_host(uuid)',                       'fca691d91d3aadf74972906e75019646',  -- phase3-e1-seating.sql
    'public.assign_table_seat()',                    '5f2ea7a318c9f3a6dc7552f6bf7e0380'   -- phase3-e1-seating.sql
  );
  v_bad := null;
  for v_rec in select key, value #>> '{}' as md5 from jsonb_each(v_expected) loop
    select md5(replace(p.prosrc, E'\r', '')) into v_md5
    from pg_proc p where p.oid = to_regprocedure(v_rec.key);
    if v_md5 is distinct from v_rec.md5 then
      v_bad := coalesce(v_bad || '; ', '') || v_rec.key || ' has ' || coalesce(v_md5, '(missing)');
    end if;
  end loop;
  if v_bad is not null then
    raise exception 'FAIL [S4] function bodies differ from docs/sql: %.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [S5] The fourteen client functions: authenticated can execute, anon can't.
  v_n := 0;
  foreach v_fn in array v_client loop
    if to_regprocedure(v_fn) is null or not has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'FAIL [S5] authenticated cannot execute %.', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'FAIL [S5] anon CAN execute %.', v_fn;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 14 then raise exception 'FAIL [S5] checked % client functions, expected 14.', v_n; end if;
  v_checks := v_checks + 1;

  -- [S6] Of every function this project defines, exactly those fourteen are
  -- client-callable (award_points included: still not callable).
  select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text) into v_bad
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in (
      'acknowledge_deal_cut', 'award_points', 'card_play_value', 'card_rank_value', 'claim_win',
      'clear_win_claim', 'confirm_count', 'confirm_win', 'deal_cards_for_game', 'discard_to_crib',
      'draw_cut_card', 'end_timed_out_sessions', 'has_legal_play', 'leave_table', 'next_hand',
      'play_card', 'score_hand', 'score_pegging', 'show_crib', 'show_hand', 'shuffled_deck',
      'start_game_with_deal', 'assign_table_seat', 'seat_team', 'table_host', 'set_seat'
    )
    and (has_function_privilege('authenticated', p.oid, 'execute')
         or has_function_privilege('anon', p.oid, 'execute'))
    and p.oid not in (select to_regprocedure(x)::oid from unnest(v_client) x);
  if v_bad is not null then
    raise exception 'FAIL [S6] these functions are client-callable but should not be: %.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [S7] The crib policy: same name, still a permissive SELECT policy for
  -- everyone (RLS narrows it), its step condition now the table's size.
  select pol.qual into v_msg
  from pg_policies pol
  where pol.schemaname = 'public' and pol.tablename = 'game_cribs'
    and pol.policyname = 'Players read the crib once it is up for counting'
    and pol.cmd = 'SELECT' and pol.permissive = 'PERMISSIVE' and pol.roles = '{public}'::name[];
  if v_msg is null
     or position('count_step = array_length(g.players, 1)' in v_msg) = 0
     or position('count_step = 2' in v_msg) > 0 then
    raise exception 'FAIL [S7] the crib policy is not the E4 one: %.', coalesce(v_msg, '(missing)');
  end if;
  v_checks := v_checks + 1;

  -- [S8] Every other game_hands / game_cribs policy is still there, by name,
  -- as a SELECT policy, and nothing else reads the table's size.
  select string_agg(pol.tablename || ': ' || pol.policyname || ' (' || pol.cmd || ')', '; ' order by pol.tablename, pol.policyname)
  into v_msg
  from pg_policies pol
  where pol.schemaname = 'public' and pol.tablename in ('game_hands', 'game_cribs');
  if v_msg is distinct from
       'game_cribs: Players at the table read a shown crib (SELECT); '
    || 'game_cribs: Players of a won game read its crib (SELECT); '
    || 'game_cribs: Players read the crib once it is up for counting (SELECT); '
    || 'game_hands: Players of a won game read its hands (SELECT); '
    || 'game_hands: Players read every hand once pegging is over (SELECT); '
    || 'game_hands: Players read their own hand, or a hand shown at their table (SELECT)'
     or exists (
       select 1 from pg_policies pol
       where pol.schemaname = 'public' and pol.tablename in ('game_hands', 'game_cribs')
         and pol.policyname <> 'Players read the crib once it is up for counting'
         and position('array_length' in coalesce(pol.qual, '')) > 0
     ) then
    raise exception 'FAIL [S8] the game_hands / game_cribs policies changed: %.', v_msg;
  end if;
  v_checks := v_checks + 1;

  -- ---- The OLD functions, for the 2-player proof (rolled back) -------------
  create function public.award_points_old(
    p_table_id uuid,
    p_user_id uuid,
    p_points int,
    p_reason text
  )
  returns void
  language plpgsql
  set search_path = public
  as $old_body$
-- ===== (W1) CHANGED FROM SLICE 6 (start) =====
declare
  v_new_score int;
-- ===== (W1) CHANGED FROM SLICE 6 (end) =====
begin
  if p_points is null then
    raise exception 'award_points requires a point value (0 is allowed, null is not).';
  end if;

  update public.table_members
  -- ===== (W2) CHANGED FROM SLICE 6 (start) =====
  -- Capped at 121 -- see THE CAP note above the function.
  set score = least(score + p_points, 121),
  -- ===== (W2) CHANGED FROM SLICE 6 (end) =====
      last_points = p_points,
      last_reason = p_reason,
      last_awarded_at = now()
  where table_id = p_table_id
  -- ===== (W3) CHANGED FROM SLICE 6 (start) =====
    and user_id = p_user_id
  returning score into v_new_score;
  -- ===== (W3) CHANGED FROM SLICE 6 (end) =====

  -- Fails loudly rather than silently scoring nobody. A future scoring slice
  -- passing a stale user id is a bug worth surfacing immediately.
  if not found then
    raise exception 'No player % at table %.', p_user_id, p_table_id;
  end if;

  -- ===== (W4) CHANGED FROM SLICE 6 (start) =====
  -- THE WIN. First to 121 ends the game on the spot -- mid-pegging, mid-count,
  -- or on his heels -- because nothing after the winning point counts.
  --
  -- Filtered to status = 'active', so it is a no-op when called from the SQL
  -- Editor against a table with no live game, and it can never re-end (or
  -- re-attribute) a game that has already ended. 'cutting' never reaches
  -- here: no points are awarded during the cut for deal.
  if v_new_score >= 121 then
    update public.games
    set status = 'ended',
        ended_reason = 'won',
        winner_id = p_user_id
    where table_id = p_table_id
      and status = 'active'
      -- ===== (X1) CHANGED FOR MUGGINS (start) =====
      -- A Muggins table is never won by a score: the points above are still
      -- recorded (and still capped at 121), but the game stays live, so 121
      -- -- or any later award -- never ends it.
      and not exists (
        select 1
        from public.tables t
        where t.id = p_table_id
          and t.is_muggins
      )
      -- ===== (X1) CHANGED FOR MUGGINS (end) =====
      ;
  end if;
  -- ===== (W4) CHANGED FROM SLICE 6 (end) =====
end;
$old_body$;

  create function public.show_crib_old(p_game_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = public
  as $old_body$
declare
  v_caller uuid := auth.uid();
  v_game record;
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to show the crib.';
  end if;

  -- THE ROW LOCK.
  select g.id, g.table_id, g.status, g.phase, g.players, g.dealer_id,
         g.count_step, g.crib_revealed
  into v_game
  from public.games g
  where g.id = p_game_id
  for update;

  if not found then
    raise exception 'Game not found.';
  end if;

  -- Guard 2: the game must still be live.
  if v_game.status <> 'active' then
    raise exception 'This game is no longer active.';
  end if;

  -- Guard 3 (membership).
  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = v_game.table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not a member of this table.';
  end if;

  if v_game.players is null or not (v_caller = any(v_game.players)) then
    raise exception 'You are not a player in this game.';
  end if;

  -- Guard 4: the crib is the dealer's to show. Before the idempotency return,
  -- so a non-dealer gets a real error rather than a silent no-op.
  if v_game.dealer_id is distinct from v_caller then
    raise exception 'Only the dealer can show the crib.';
  end if;

  -- Idempotent.
  if v_game.crib_revealed then
    return;
  end if;

  -- Guard 5: only after both hands are counted.
  if v_game.phase <> 'counting' or v_game.count_step <> 2 then
    raise exception 'The crib is shown after both hands have been counted.';
  end if;

  update public.games
  set crib_revealed = true
  where id = p_game_id;
end;
$old_body$;
  grant execute on function public.show_crib_old(uuid) to authenticated;

  execute replace(replace($old_body$create function public.confirm_count_old(p_game_id uuid, p_step int)
returns void
language plpgsql
security definer
set search_path = public
as $cc_body$
declare
  v_caller uuid := auth.uid();
  v_game record;
  v_current_step int;
  v_is_crib boolean;
  v_cards text[];
  v_score jsonb;
  v_points int;
  v_parts text[] := '{}';
  v_reason text;
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to confirm a count.';
  end if;

  -- Guard 2: a step that cannot exist in a 2-player hand. Whether it is
  -- behind or ahead is judged later, against the locked row.
  if p_step is null or p_step < 0 or p_step > 2 then
    raise exception 'Invalid count step %.', p_step;
  end if;

  -- THE ROW LOCK. Both players could act at once (the pone confirming while
  -- the dealer taps Show Crib, a double tap from either), and every check
  -- below reads state the update at the end depends on.
  select g.id, g.table_id, g.status, g.phase, g.players, g.dealer_id,
         g.starter_card, g.current_player, g.count_step, g.revealed_by,
         g.crib_revealed
  into v_game
  from public.games g
  where g.id = p_game_id
  for update;

  if not found then
    raise exception 'Game not found.';
  end if;

  -- Guard 3: the game must still be live.
  if v_game.status <> 'active' then
    raise exception 'This game is no longer active.';
  end if;

  -- Guard 4 (membership).
  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = v_game.table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not a member of this table.';
  end if;

  if v_game.players is null or not (v_caller = any(v_game.players)) then
    raise exception 'You are not a player in this game.';
  end if;

  -- Guard 5: phase and step. 'done' counts as step 3 -- past every step -- so
  -- a late duplicate of the crib confirm is quiet, not an error.
  if v_game.phase = 'counting' then
    v_current_step := v_game.count_step;
  elsif v_game.phase = 'done' then
    v_current_step := 3;
  else
    raise exception 'This game is not in the counting phase.';
  end if;

  if p_step < v_current_step then
    return;
  end if;

  if p_step > v_current_step then
    raise exception 'That count is not up yet.';
  end if;

  -- From here on: phase = 'counting' and p_step = count_step.

  -- Guard 6 (turn enforcement): only the player whose count is up.
  if v_game.current_player is distinct from v_caller then
    raise exception 'It is not your turn to count.';
  end if;

  -- Guard 7 (defensive): current_player must agree with the 2-player order --
  -- step 0 the pone, steps 1 and 2 the dealer. Cannot fail if only these
  -- functions write the row; it is here to catch a bad backfill or a
  -- hand-edited test row before it scores the wrong cards.
  if (v_game.count_step = 0 and v_caller = v_game.dealer_id)
     or (v_game.count_step > 0 and v_caller is distinct from v_game.dealer_id) then
    raise exception 'Counting state is inconsistent: step % does not belong to this player.',
      v_game.count_step;
  end if;

  -- Guard 8: a count needs the starter.
  if v_game.starter_card is null then
    raise exception 'There is no starter card to count with.';
  end if;

  v_is_crib := (v_game.count_step = 2);

  if v_is_crib then
    -- Guard 9: the crib must have been shown first (show_crib).
    if not v_game.crib_revealed then
      raise exception 'Show the crib before confirming its count.';
    end if;

    select c.cards
    into v_cards
    from public.game_cribs c
    where c.game_id = p_game_id;
  else
    select gh.cards
    into v_cards
    from public.game_hands gh
    where gh.game_id = p_game_id
      and gh.user_id = v_caller;
  end if;

  -- Guard 10: exactly four cards -- see WHAT GETS SCORED above.
  if coalesce(array_length(v_cards, 1), 0) <> 4 then
    raise exception '% has % cards; a count needs exactly 4.',
      case when v_is_crib then 'The crib' else 'Your hand' end,
      coalesce(array_length(v_cards, 1), 0);
  end if;

  -- AUTO-REVEAL (design decision 8). Counting a hand shows it -- you cannot
  -- confirm a hand the table has not seen. The crib is already shown by
  -- Guard 9. Done before the award so a WINNING hand is still on the table.
  if not v_is_crib and not (v_caller = any(v_game.revealed_by)) then
    update public.games
    set revealed_by = array_append(revealed_by, v_caller)
    where id = p_game_id;
  end if;

  -- SCORE. p_is_crib changes only the flush rule (crib: 5-card flush only).
  v_score := public.score_hand(v_cards, v_game.starter_card, v_is_crib);
  v_points := (v_score ->> 'points')::int;

  -- The reason, e.g. "hand: 15s 4 {MIDDOT} pairs 2 {MIDDOT} runs 3" -- the tracker shows it
  -- as "+9 {EMDASH} hand: 15s 4 {MIDDOT} pairs 2 {MIDDOT} runs 3". Zero components are omitted;
  -- a hand worth nothing reads "hand: nothing". array_append throughout
  -- (Batch 1's 22P02 lesson).
  if (v_score ->> 'fifteens')::int > 0 then
    v_parts := array_append(v_parts, ('15s ' || (v_score ->> 'fifteens'))::text);
  end if;
  if (v_score ->> 'pairs')::int > 0 then
    v_parts := array_append(v_parts, ('pairs ' || (v_score ->> 'pairs'))::text);
  end if;
  if (v_score ->> 'runs')::int > 0 then
    v_parts := array_append(v_parts, ('runs ' || (v_score ->> 'runs'))::text);
  end if;
  if (v_score ->> 'flush')::int > 0 then
    v_parts := array_append(v_parts, ('flush ' || (v_score ->> 'flush'))::text);
  end if;
  if (v_score ->> 'nobs')::int > 0 then
    v_parts := array_append(v_parts, ('nobs ' || (v_score ->> 'nobs'))::text);
  end if;

  v_reason := (case when v_is_crib then 'crib: ' else 'hand: ' end)
              || coalesce(nullif(array_to_string(v_parts, ' {MIDDOT} '), ''), 'nothing');

  -- THE SINGLE AWARD. To the caller: the hand's owner at steps 0 and 1, and
  -- the dealer -- who owns the crib in 2-player -- at step 2 (Guard 7).
  perform public.award_points_old(v_game.table_id, v_caller, v_points, v_reason);

  -- ADVANCE, only if that award did not just end the game. count_step,
  -- current_player and phase move together, in one statement each way.
  if v_game.count_step < 2 then
    update public.games
    set count_step = v_game.count_step + 1,
        current_player = v_game.dealer_id
    where id = p_game_id
      and status = 'active';
  else
    update public.games
    set phase = 'done',
        current_player = null
    where id = p_game_id
      and status = 'active';
  end if;
end;
$cc_body$
$old_body$, '{MIDDOT}', chr(183)), '{EMDASH}', chr(8212));
  grant execute on function public.confirm_count_old(uuid, int) to authenticated;

  -- [S9] The old copies are exact: the source bodies (confirm_count_old with
  -- the one substitution, award_points -> award_points_old).
  v_bad := null;
  for v_rec in select key, value #>> '{}' as md5 from jsonb_each(jsonb_build_object(
      'public.award_points_old(uuid, uuid, int, text)', '7234674b5e9be6beac60541661cd964a',   -- muggins-mode.sql
      'public.confirm_count_old(uuid, int)',            'b6ae75d3ed6403064b3b88b394685229',   -- phase2-batch2a-counting.sql, substituted
      'public.show_crib_old(uuid)',                     'cab1efd1eb3cc00738f3ccef06c72cfe'    -- phase2-batch2a-counting.sql
  )) loop
    select md5(replace(p.prosrc, E'\r', '')) into v_md5
    from pg_proc p where p.oid = to_regprocedure(v_rec.key);
    if v_md5 is distinct from v_rec.md5 then
      v_bad := coalesce(v_bad || '; ', '') || v_rec.key || ' has ' || coalesce(v_md5, '(missing)');
    end if;
  end loop;
  if v_bad is not null then
    raise exception 'FAIL [S9] the old copies are not the source bodies: %.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- Two read-only helpers (rolled back): a game's state and its players'
  -- scores, as one readable string each, players as letters. The middle dot
  -- in a count's reason is shown as "~", and an award made in this
  -- transaction (now()) as "now".
  create function public.e4_state(p_game uuid, p_names jsonb)
  returns text
  language sql
  stable
  as $h$
    select g.status || '/' || coalesce(g.ended_reason, '-') || '/' || coalesce(p_names ->> g.winner_id::text, '-')
      || '/' || g.phase || '/' || g.count_step || '/' || coalesce(p_names ->> g.current_player::text, '-')
      || '/' || coalesce((select string_agg(p_names ->> x.r::text, '.' order by x.o)
                          from unnest(g.revealed_by) with ordinality as x(r, o)), '-')
      || '/' || case when g.crib_revealed then 't' else 'f' end
    from public.games g
    where g.id = p_game
  $h$;

  create function public.e4_scores(p_game uuid, p_names jsonb)
  returns text
  language sql
  stable
  as $h$
    select coalesce(string_agg(
             (p_names ->> tm.user_id::text) || '=' || tm.score
             || '/' || coalesce(tm.last_points::text, '')
             || '/' || coalesce(replace(tm.last_reason, chr(183), '~'), '')
             || '/' || case when tm.last_awarded_at is null then ''
                            when tm.last_awarded_at = now() then 'now'
                            else tm.last_awarded_at::text end,
             ',' order by p_names ->> tm.user_id::text), '')
    from public.table_members tm
    join public.games g on g.table_id = tm.table_id
    where g.id = p_game
      and tm.user_id = any(g.players)
  $h$;

  -- ---- The tables and games -------------------------------------------------
  -- A creates each table (size, team mode, Muggins), every player sits down
  -- as themselves (seats in join order), and A starts the game.
  v_spec := '[
    {"name":"t2",  "max":2, "mode":"teams", "muggins":false, "members":["A","B"]},
    {"name":"t2o", "max":2, "mode":"teams", "muggins":false, "members":["A","B"]},
    {"name":"t2s", "max":2, "mode":"solo",  "muggins":false, "members":["A","B"]},
    {"name":"t2so","max":2, "mode":"solo",  "muggins":false, "members":["A","B"]},
    {"name":"tm",  "max":2, "mode":"teams", "muggins":true,  "members":["A","B"]},
    {"name":"tmo", "max":2, "mode":"teams", "muggins":true,  "members":["A","B"]},
    {"name":"t3",  "max":3, "mode":"teams", "muggins":false, "members":["A","B","C"]},
    {"name":"t3o", "max":3, "mode":"teams", "muggins":false, "members":["A","B","C"]},
    {"name":"t4s", "max":4, "mode":"solo",  "muggins":false, "members":["A","B","C","D"]},
    {"name":"t4so","max":4, "mode":"solo",  "muggins":false, "members":["A","B","C","D"]},
    {"name":"t4",  "max":4, "mode":"teams", "muggins":false, "members":["A","B","C","D"]}
  ]'::jsonb;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  for v_rec in select s.value as spec, s.ordinality as i from jsonb_array_elements(v_spec) with ordinality as s loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_a::text, true);
    insert into public.tables (code, created_by, max_players, team_mode, is_muggins)
    values (v_codes[v_rec.i], v_a, (v_rec.spec ->> 'max')::smallint, v_rec.spec ->> 'mode', (v_rec.spec ->> 'muggins')::boolean)
    returning id into v_t;
    for v_key in select jsonb_array_elements_text(v_rec.spec -> 'members') loop
      v_player := (v_letters ->> v_key)::uuid;
      perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', v_player::text, true);
      insert into public.table_members (table_id, user_id) values (v_t, v_player);
    end loop;
    perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_a::text, true);
    v_g := public.start_game_with_deal(v_t);
    v_tables := v_tables || jsonb_build_object(v_rec.spec ->> 'name', v_t);
    v_games := v_games || jsonb_build_object('g' || substr(v_rec.spec ->> 'name', 2), v_g);
  end loop;
  execute 'reset role';

  v_g2 := (v_games ->> 'g2')::uuid;
  v_g3 := (v_games ->> 'g3')::uuid;
  v_g4 := (v_games ->> 'g4')::uuid;
  v_t3 := (v_tables ->> 't3')::uuid;
  v_t4 := (v_tables ->> 't4')::uuid;

  -- ==== W: award_points, old vs new ==========================================
  -- The same calls, as the owner, on twin tables through award_points and
  -- award_points_old, compared after EVERY call. "first", "second" and
  -- "last" are seats 1, 2 and the last seat; "set" first puts seat 1 at
  -- 118 on both tables, so the next award caps and wins.
  v_calls := '[
    {"who":"first",  "pts":5,    "r":"one"},
    {"who":"second", "pts":0,    "r":"zero"},
    {"who":"last",   "pts":3,    "r":"three"},
    {"who":"first",  "pts":6,    "r":"six", "set":118},
    {"who":"second", "pts":2,    "r":"after the win"},
    {"who":"E",      "pts":1,    "r":"nobody"},
    {"who":"first",  "pts":null, "r":"no points"},
    {"who":"second", "pts":200,  "r":"big"}
  ]'::jsonb;
  for v_rec in select * from (values
      ('W1', 't2',  '2 players, team_mode teams (the default)'),
      ('W2', 't2s', '2 players, team_mode solo'),
      ('W3', 'tm',  '2 players, Muggins'),
      ('W4', 't3',  '3 players'),
      ('W5', 't4s', '4 players, team_mode solo')
    ) as w(id, tname, what) loop
    v_t := (v_tables ->> v_rec.tname)::uuid;
    v_tw := (v_tables ->> (v_rec.tname || 'o'))::uuid;
    v_g := (v_games ->> ('g' || substr(v_rec.tname, 2)))::uuid;
    v_twin := (v_games ->> ('g' || substr(v_rec.tname, 2) || 'o'))::uuid;
    update public.games
    set status = 'active', ended_reason = null, winner_id = null, win_claim_by = null, ready_by = '{}'
    where id in (v_g, v_twin);
    update public.table_members
    set score = 0, last_points = null, last_reason = null, last_awarded_at = null
    where table_id in (v_t, v_tw);
    select players into v_pl from public.games where id = v_g;

    v_err := '';
    v_n := 0;
    for v_act in select value from jsonb_array_elements(v_calls) loop
      v_n := v_n + 1;
      v_player := case v_act ->> 'who'
        when 'first' then v_pl[1]
        when 'second' then v_pl[2]
        when 'last' then v_pl[array_length(v_pl, 1)]
        else v_e
      end;
      if v_act ? 'set' then
        update public.table_members set score = (v_act ->> 'set')::int
        where table_id in (v_t, v_tw) and user_id = v_pl[1];
      end if;
      v_msg := null;
      begin
        perform public.award_points(v_t, v_player, (v_act ->> 'pts')::int, v_act ->> 'r');
      exception when others then
        v_msg := replace(replace(sqlerrm, v_t::text, '<table>'), v_e::text, 'E');
      end;
      v_msg2 := null;
      begin
        perform public.award_points_old(v_tw, v_player, (v_act ->> 'pts')::int, v_act ->> 'r');
      exception when others then
        v_msg2 := replace(replace(sqlerrm, v_tw::text, '<table>'), v_e::text, 'E');
      end;
      if v_msg is not null then
        v_err := v_err || case when v_err = '' then '' else '|' end || v_msg;
      end if;

      v_state := public.e4_state(v_g, v_names);
      v_state2 := public.e4_state(v_twin, v_names);
      v_scores := public.e4_scores(v_g, v_names);
      v_scores2 := public.e4_scores(v_twin, v_names);
      if v_state is distinct from v_state2 or v_scores is distinct from v_scores2 or v_msg is distinct from v_msg2 then
        raise exception 'FAIL [%] (%): the new and the old award_points differ after call % (%). NEW % / % / refused % -- OLD % / % / refused %.',
          v_rec.id, v_rec.what, v_n, v_act, v_state, v_scores, coalesce(v_msg, '-'), v_state2, v_scores2, coalesce(v_msg2, '-');
      end if;
    end loop;

    -- Not vacuous: exactly the two refusals, and seat 1's 118 + 6 capped at
    -- 121 and won -- or, on Muggins, capped at 121 and did NOT end the game.
    select g.status || '/' || coalesce(g.ended_reason, '-') || '/' || coalesce(v_names ->> g.winner_id::text, '-')
    into v_state
    from public.games g where g.id = v_g;
    select tm.score into v_n2 from public.table_members tm where tm.table_id = v_t and tm.user_id = v_pl[1];
    if v_err is distinct from 'No player E at table <table>.|award_points requires a point value (0 is allowed, null is not).'
       or v_n2 is distinct from 121
       or v_state is distinct from (case when v_rec.tname = 'tm' then 'active/-/-' else 'ended/won/' || (v_names ->> v_pl[1]::text) end) then
      raise exception 'FAIL [%] (%): refused % / seat 1 at % / game %; expected the two refusals, 121, and % .',
        v_rec.id, v_rec.what, v_err, v_n2, v_state,
        case when v_rec.tname = 'tm' then 'no win (Muggins)' else 'a win by seat 1' end;
    end if;
    v_checks := v_checks + 1;
  end loop;

  -- ==== Q: the crib read policy, old vs new, 2 players ========================
  -- g2 holds a crib. In every state -- live, won, or ended without a winner;
  -- every phase; count_step 0 to 3; crib_revealed off and on -- each player
  -- reads the crib through the LIVE policies, and that must equal the OLD
  -- rule: the three crib policies as they were before E4 ("up for counting"
  -- at count_step = 2, "a shown crib", "a won game").
  delete from public.game_plays where game_id = v_g2;
  delete from public.game_hands where game_id = v_g2;
  delete from public.game_cribs where game_id = v_g2;
  insert into public.game_cribs (game_id, cards) values (v_g2, array['3D', '6D', 'TD', 'KD']);
  update public.games
  set dealer_id = v_b, current_player = null, revealed_by = '{}', win_claim_by = null, ready_by = '{}'
  where id = v_g2;
  v_n := 0;
  foreach v_kind in array array['active', 'won', 'left'] loop
    foreach v_op in array array['discard', 'play', 'counting', 'done'] loop
      for v_stepi in 0 .. 3 loop
        foreach v_flag in array array[false, true] loop
          update public.games
          set status = case when v_kind = 'active' then 'active' else 'ended' end,
              ended_reason = case v_kind when 'won' then 'won' when 'left' then 'player_left' end,
              winner_id = case when v_kind = 'won' then v_a end,
              phase = v_op, count_step = v_stepi, crib_revealed = v_flag
          where id = v_g2;
          v_exp := (v_kind = 'active' and ((v_op = 'counting' and v_stepi = 2) or v_op = 'done'))
                   or v_flag
                   or v_kind = 'won';
          foreach v_player in array array[v_a, v_b] loop
            execute 'set local role authenticated';
            perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
            perform set_config('request.jwt.claim.sub', v_player::text, true);
            select count(*) into v_n2 from public.game_cribs where game_id = v_g2;
            execute 'reset role';
            if (v_n2 = 1) is distinct from v_exp then
              raise exception 'FAIL [Q1] the crib read for % in state % / % / step % / crib_revealed %: % row(s), but the old rule says %.',
                v_names ->> v_player::text, v_kind, v_op, v_stepi, v_flag, v_n2, v_exp;
            end if;
            v_n := v_n + 1;
          end loop;
        end loop;
      end loop;
    end loop;
  end loop;
  if v_n <> 192 then
    raise exception 'FAIL [Q1] checked % crib reads, expected 192.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- ==== D, T, F: the scripted counts ==========================================
  -- One element per hand: id, game (and twin, for 'diff'), mode ('diff':
  -- through the new functions on game and the old ones on twin, compared
  -- after every call; 'expect': the whole trace must equal expect.trace),
  -- dealer, starting scores, hands, crib, starter, script, refused (exactly
  -- the refusals it must meet), end ('done' or 'win').
  -- A script step is {who, op, step}: who is "cur" (whoever's turn it is)
  -- or a letter; op is confirm (confirm_count with that step) or show_crib.
  -- A trace step, taken before each call and after the last, is: the game
  -- state (status/ended_reason/winner/phase/count_step/current_player/
  -- revealed_by/crib_revealed), then "c=" the players who can read the crib
  -- and "h=" how many hands each can read, then every player's
  -- score/last_points/last_reason/last_awarded_at.
  v_scenarios := '[
    {"id":"D1","game":"g2","twin":"g2o","mode":"diff","what":"a 0-point hand (hand: nothing), a hand flush (4), a four-card crib flush (worth nothing), counted to done","dealer":"B","scores":{},"hands":{"A":["KS","QD","8H","AD"],"B":["AH","4H","9H","QH"]},"crib":["3D","6D","TD","KD"],"starter":"2C","script":[{"who":"cur","op":"confirm","step":0},{"who":"cur","op":"confirm","step":1},{"who":"cur","op":"show_crib","step":null},{"who":"cur","op":"confirm","step":2}],"refused":"","end":"done"},
    {"id":"D2","game":"g2","twin":"g2o","mode":"diff","what":"a five-card crib flush (5), a 21 hand with nobs, counted to done","dealer":"A","scores":{},"hands":{"A":["5H","5D","TC","JS"],"B":["7C","8C","9D","2H"]},"crib":["AS","3S","9S","KS"],"starter":"5S","script":[{"who":"cur","op":"confirm","step":0},{"who":"cur","op":"confirm","step":1},{"who":"cur","op":"show_crib","step":null},{"who":"cur","op":"confirm","step":2}],"refused":"","end":"done"},
    {"id":"D3","game":"g2","twin":"g2o","mode":"diff","what":"a win at step 0 (the pone, capped at 121): the dealer''s hand and the crib are never counted","dealer":"B","scores":{"A":110},"hands":{"A":["5H","5D","TC","JS"],"B":["7C","8C","9D","2H"]},"crib":["AS","3S","9S","KS"],"starter":"5S","script":[{"who":"cur","op":"confirm","step":0},{"who":"B","op":"confirm","step":1},{"who":"B","op":"show_crib","step":null}],"refused":"confirm(1)@B:This game is no longer active.|show_crib@B:This game is no longer active.","end":"win"},
    {"id":"D4","game":"g2","twin":"g2o","mode":"diff","what":"a win on the crib (exactly 121)","dealer":"B","scores":{"B":105},"hands":{"A":["5H","5D","TC","JS"],"B":["7C","8C","9D","2H"]},"crib":["AS","3S","9S","KS"],"starter":"5S","script":[{"who":"cur","op":"confirm","step":0},{"who":"cur","op":"confirm","step":1},{"who":"cur","op":"show_crib","step":null},{"who":"cur","op":"confirm","step":2},{"who":"A","op":"confirm","step":2}],"refused":"confirm(2)@A:This game is no longer active.","end":"win"},
    {"id":"D5","game":"g2","twin":"g2o","mode":"diff","what":"every refusal: steps 3, -1 and null, wrong turn, a step ahead, show_crib by the pone and early, the crib confirmed before it is shown; double confirms and a second show_crib are quiet","dealer":"B","scores":{},"hands":{"A":["KS","QD","8H","AD"],"B":["AH","4H","9H","QH"]},"crib":["3D","6D","TD","KD"],"starter":"2C","script":[{"who":"A","op":"confirm","step":3},{"who":"A","op":"confirm","step":-1},{"who":"A","op":"confirm","step":null},{"who":"B","op":"confirm","step":0},{"who":"A","op":"confirm","step":1},{"who":"A","op":"show_crib","step":null},{"who":"B","op":"show_crib","step":null},{"who":"A","op":"confirm","step":0},{"who":"A","op":"confirm","step":0},{"who":"A","op":"confirm","step":1},{"who":"B","op":"show_crib","step":null},{"who":"B","op":"confirm","step":1},{"who":"B","op":"confirm","step":2},{"who":"B","op":"show_crib","step":null},{"who":"B","op":"show_crib","step":null},{"who":"B","op":"confirm","step":2},{"who":"B","op":"confirm","step":2},{"who":"A","op":"confirm","step":0}],"refused":"confirm(3)@A:Invalid count step 3.|confirm(-1)@A:Invalid count step -1.|confirm(null)@A:Invalid count step <NULL>.|confirm(0)@B:It is not your turn to count.|confirm(1)@A:That count is not up yet.|show_crib@A:Only the dealer can show the crib.|show_crib@B:The crib is shown after both hands have been counted.|confirm(1)@A:It is not your turn to count.|show_crib@B:The crib is shown after both hands have been counted.|confirm(2)@B:Show the crib before confirming its count.","end":"done"},
    {"id":"D6","game":"gm","twin":"gmo","mode":"diff","what":"a Muggins table: 121 (capped) does not end the match; the count runs on to done","dealer":"B","scores":{"A":119,"B":115},"hands":{"A":["KS","QD","8H","AD"],"B":["AH","4H","9H","QH"]},"crib":["3D","6D","TD","KD"],"starter":"2C","script":[{"who":"cur","op":"confirm","step":0},{"who":"cur","op":"confirm","step":1},{"who":"cur","op":"show_crib","step":null},{"who":"cur","op":"confirm","step":2}],"refused":"","end":"done"},
    {"id":"T1","game":"g3","mode":"expect","what":"3 players, dealer A (seat 1): B, C, then A''s own hand, then A''s crib; show_crib at step 2 refused; the crib readable by nobody at steps 0-2 and by all three at step 3; done","dealer":"A","scores":{},"hands":{"B":["4S","5C","6H","KC"],"C":["7S","8S","9C","2D"],"A":["JD","QH","3C","AS"]},"crib":["TS","TH","5D","9H"],"starter":"6D","script":[{"who":"cur","op":"confirm","step":0},{"who":"cur","op":"confirm","step":1},{"who":"A","op":"show_crib","step":null},{"who":"cur","op":"confirm","step":2},{"who":"cur","op":"show_crib","step":null},{"who":"cur","op":"confirm","step":3}],"refused":"show_crib@A:The crib is shown after every hand has been counted.","end":"done","expect":{"trace":"active/-/-/counting/0/B/-/f c=- h=333 ; A=0///,B=0///,C=0/// > active/-/-/counting/1/C/B/f c=- h=333 ; A=0///,B=14/14/hand: 15s 6 ~ pairs 2 ~ runs 6/now,C=0/// > active/-/-/counting/2/A/B.C/f c=- h=333 ; A=0///,B=14/14/hand: 15s 6 ~ pairs 2 ~ runs 6/now,C=10/10/hand: 15s 6 ~ runs 4/now > active/-/-/counting/2/A/B.C/f c=- h=333 ; A=0///,B=14/14/hand: 15s 6 ~ pairs 2 ~ runs 6/now,C=10/10/hand: 15s 6 ~ runs 4/now > active/-/-/counting/3/A/B.C.A/f c=ABC h=333 ; A=1/1/hand: nobs 1/now,B=14/14/hand: 15s 6 ~ pairs 2 ~ runs 6/now,C=10/10/hand: 15s 6 ~ runs 4/now > active/-/-/counting/3/A/B.C.A/t c=ABC h=333 ; A=1/1/hand: nobs 1/now,B=14/14/hand: 15s 6 ~ pairs 2 ~ runs 6/now,C=10/10/hand: 15s 6 ~ runs 4/now > active/-/-/done/3/-/B.C.A/t c=ABC h=333 ; A=9/8/crib: 15s 6 ~ pairs 2/now,B=14/14/hand: 15s 6 ~ pairs 2 ~ runs 6/now,C=10/10/hand: 15s 6 ~ runs 4/now"}},
    {"id":"T2","game":"g3","mode":"expect","what":"3 players: C wins mid-count at step 1; A''s hand and the crib are frozen out","dealer":"A","scores":{"C":111},"hands":{"B":["4S","5C","6H","KC"],"C":["7S","8S","9C","2D"],"A":["JD","QH","3C","AS"]},"crib":["TS","TH","5D","9H"],"starter":"6D","script":[{"who":"cur","op":"confirm","step":0},{"who":"cur","op":"confirm","step":1},{"who":"A","op":"confirm","step":2},{"who":"A","op":"show_crib","step":null}],"refused":"confirm(2)@A:This game is no longer active.|show_crib@A:This game is no longer active.","end":"win","expect":{"trace":"active/-/-/counting/0/B/-/f c=- h=333 ; A=0///,B=0///,C=111/// > active/-/-/counting/1/C/B/f c=- h=333 ; A=0///,B=14/14/hand: 15s 6 ~ pairs 2 ~ runs 6/now,C=111/// > ended/won/C/counting/1/C/B.C/f c=ABC h=333 ; A=0///,B=14/14/hand: 15s 6 ~ pairs 2 ~ runs 6/now,C=121/10/hand: 15s 6 ~ runs 4/now > ended/won/C/counting/1/C/B.C/f c=ABC h=333 ; A=0///,B=14/14/hand: 15s 6 ~ pairs 2 ~ runs 6/now,C=121/10/hand: 15s 6 ~ runs 4/now > ended/won/C/counting/1/C/B.C/f c=ABC h=333 ; A=0///,B=14/14/hand: 15s 6 ~ pairs 2 ~ runs 6/now,C=121/10/hand: 15s 6 ~ runs 4/now"}},
    {"id":"F2","game":"g4","mode":"expect","what":"4 players, Teams, dealer D (seat 4): A, B, C, then D''s own hand, then D''s crib for team B+D; partners'' rows equal after every award, last_* only on the scorer","dealer":"D","scores":{},"hands":{"A":["5S","5C","JH","KD"],"B":["2S","3S","6S","QS"],"C":["7D","8D","8C","AD"],"D":["9S","TC","JC","3H"]},"crib":["2H","6H","8H","KH"],"starter":"4H","script":[{"who":"cur","op":"confirm","step":0},{"who":"cur","op":"confirm","step":1},{"who":"cur","op":"confirm","step":2},{"who":"cur","op":"confirm","step":3},{"who":"cur","op":"show_crib","step":null},{"who":"cur","op":"confirm","step":4}],"refused":"","end":"done","expect":{"trace":"active/-/-/counting/0/A/-/f c=- h=4444 ; A=0///,B=0///,C=0///,D=0/// > active/-/-/counting/1/B/A/f c=- h=4444 ; A=11/11/hand: 15s 8 ~ pairs 2 ~ nobs 1/now,B=0///,C=11///,D=0/// > active/-/-/counting/2/C/A.B/f c=- h=4444 ; A=11/11/hand: 15s 8 ~ pairs 2 ~ nobs 1/now,B=11/11/hand: 15s 4 ~ runs 3 ~ flush 4/now,C=11///,D=11/// > active/-/-/counting/3/D/A.B.C/f c=- h=4444 ; A=17/11/hand: 15s 8 ~ pairs 2 ~ nobs 1/now,B=11/11/hand: 15s 4 ~ runs 3 ~ flush 4/now,C=17/6/hand: 15s 4 ~ pairs 2/now,D=11/// > active/-/-/counting/4/D/A.B.C.D/f c=ABCD h=4444 ; A=17/11/hand: 15s 8 ~ pairs 2 ~ nobs 1/now,B=14/11/hand: 15s 4 ~ runs 3 ~ flush 4/now,C=17/6/hand: 15s 4 ~ pairs 2/now,D=14/3/hand: runs 3/now > active/-/-/counting/4/D/A.B.C.D/t c=ABCD h=4444 ; A=17/11/hand: 15s 8 ~ pairs 2 ~ nobs 1/now,B=14/11/hand: 15s 4 ~ runs 3 ~ flush 4/now,C=17/6/hand: 15s 4 ~ pairs 2/now,D=14/3/hand: runs 3/now > active/-/-/done/4/-/A.B.C.D/t c=ABCD h=4444 ; A=17/11/hand: 15s 8 ~ pairs 2 ~ nobs 1/now,B=19/11/hand: 15s 4 ~ runs 3 ~ flush 4/now,C=17/6/hand: 15s 4 ~ pairs 2/now,D=19/5/crib: flush 5/now"}},
    {"id":"F3","game":"g4","mode":"expect","what":"Teams: A''s hand leaves A+C at 116, C''s hand wins at step 2 (winner C, both partners 121); D''s hand is frozen out","dealer":"D","scores":{"A":105,"C":105},"hands":{"A":["5S","5C","JH","KD"],"B":["2S","3S","6S","QS"],"C":["7D","8D","8C","AD"],"D":["9S","TC","JC","3H"]},"crib":["2H","6H","8H","KH"],"starter":"4H","script":[{"who":"cur","op":"confirm","step":0},{"who":"cur","op":"confirm","step":1},{"who":"cur","op":"confirm","step":2},{"who":"D","op":"confirm","step":3}],"refused":"confirm(3)@D:This game is no longer active.","end":"win","expect":{"trace":"active/-/-/counting/0/A/-/f c=- h=4444 ; A=105///,B=0///,C=105///,D=0/// > active/-/-/counting/1/B/A/f c=- h=4444 ; A=116/11/hand: 15s 8 ~ pairs 2 ~ nobs 1/now,B=0///,C=116///,D=0/// > active/-/-/counting/2/C/A.B/f c=- h=4444 ; A=116/11/hand: 15s 8 ~ pairs 2 ~ nobs 1/now,B=11/11/hand: 15s 4 ~ runs 3 ~ flush 4/now,C=116///,D=11/// > ended/won/C/counting/2/C/A.B.C/f c=ABCD h=4444 ; A=121/11/hand: 15s 8 ~ pairs 2 ~ nobs 1/now,B=11/11/hand: 15s 4 ~ runs 3 ~ flush 4/now,C=121/6/hand: 15s 4 ~ pairs 2/now,D=11/// > ended/won/C/counting/2/C/A.B.C/f c=ABCD h=4444 ; A=121/11/hand: 15s 8 ~ pairs 2 ~ nobs 1/now,B=11/11/hand: 15s 4 ~ runs 3 ~ flush 4/now,C=121/6/hand: 15s 4 ~ pairs 2/now,D=11///"}}
  ]'::jsonb;

  for v_sc in select value from jsonb_array_elements(v_scenarios) loop
    v_gid := (v_games ->> (v_sc ->> 'game'))::uuid;
    v_twin := case when v_sc ->> 'mode' = 'diff' then (v_games ->> (v_sc ->> 'twin'))::uuid end;

    -- Set the hand, as the owner: every leftover reset, the dealer, the
    -- dealer's left to count, the known cards, the scores.
    foreach v_g in array array_remove(array[v_gid, v_twin], null) loop
      delete from public.game_plays where game_id = v_g;
      delete from public.game_hands where game_id = v_g;
      delete from public.game_cribs where game_id = v_g;
      select players into v_pl from public.games where id = v_g;
      v_dealer := (v_letters ->> (v_sc ->> 'dealer'))::uuid;
      update public.games
      set status = 'active', ended_reason = null, winner_id = null, win_claim_by = null, ready_by = '{}',
          phase = 'counting', dealer_id = v_dealer,
          current_player = v_pl[(array_position(v_pl, v_dealer) % array_length(v_pl, 1)) + 1],
          play_count = 0, play_segment = 0, count_step = 0,
          revealed_by = '{}', crib_revealed = false, discarded_by = v_pl,
          starter_card = v_sc ->> 'starter'
      where id = v_g;
      for v_key, v_val in select key, value from jsonb_each(v_sc -> 'hands') loop
        insert into public.game_hands (game_id, user_id, cards)
        values (v_g, (v_letters ->> v_key)::uuid, array(select jsonb_array_elements_text(v_val)));
      end loop;
      insert into public.game_cribs (game_id, cards)
      values (v_g, array(select jsonb_array_elements_text(v_sc -> 'crib')));
      update public.table_members tm
      set score = coalesce((v_sc -> 'scores' ->> (v_names ->> tm.user_id::text))::int, 0),
          last_points = null, last_reason = null, last_awarded_at = null
      where tm.table_id = (select table_id from public.games where id = v_g);
    end loop;

    -- Play the script.
    v_err := '';
    v_err2 := '';
    v_trace := '';
    v_n := 0;
    -- The script, plus an end marker: the trace is taken BEFORE every call,
    -- and once more after the last one.
    for v_act in select value from jsonb_array_elements((v_sc -> 'script') || '[{"op":"end"}]'::jsonb) loop
      if v_twin is null then
        -- The trace: the state, who can read the crib and the hands (each
        -- player, as that player), and the scores.
        v_readers := '';
        v_hs := '';
        select players into v_pl from public.games where id = v_gid;
        foreach v_player in array v_pl loop
          execute 'set local role authenticated';
          perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
          perform set_config('request.jwt.claim.sub', v_player::text, true);
          select count(*) into v_n2 from public.game_cribs where game_id = v_gid;
          select count(*) into v_hand from public.game_hands where game_id = v_gid;
          execute 'reset role';
          if v_n2 > 0 then
            v_readers := v_readers || (v_names ->> v_player::text);
          end if;
          v_hs := v_hs || v_hand;
        end loop;
        v_trace := v_trace || case when v_trace = '' then '' else ' > ' end
                   || public.e4_state(v_gid, v_names) || ' c=' || coalesce(nullif(v_readers, ''), '-') || ' h=' || v_hs
                   || ' ; ' || public.e4_scores(v_gid, v_names);
      end if;
      exit when v_act ->> 'op' = 'end';

      v_n := v_n + 1;
      v_op := v_act ->> 'op';
      v_stepi := (v_act ->> 'step')::int;
      v_label := case when v_op = 'confirm' then 'confirm(' || coalesce(v_stepi::text, 'null') || ')' else v_op end;

      v_who := case when v_act ->> 'who' = 'cur'
                    then (select current_player from public.games where id = v_gid)
                    else (v_letters ->> (v_act ->> 'who'))::uuid end;
      execute 'set local role authenticated';
      perform set_config('request.jwt.claims', json_build_object('sub', v_who, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', v_who::text, true);
      begin
        if v_op = 'confirm' then
          perform public.confirm_count(v_gid, v_stepi);
        else
          perform public.show_crib(v_gid);
        end if;
      exception when others then
        v_err := v_err || case when v_err = '' then '' else '|' end || v_label || '@' || (v_names ->> v_who::text) || ':' || sqlerrm;
      end;
      execute 'reset role';

      if v_twin is not null then
        v_who := case when v_act ->> 'who' = 'cur'
                      then (select current_player from public.games where id = v_twin)
                      else (v_letters ->> (v_act ->> 'who'))::uuid end;
        execute 'set local role authenticated';
        perform set_config('request.jwt.claims', json_build_object('sub', v_who, 'role', 'authenticated')::text, true);
        perform set_config('request.jwt.claim.sub', v_who::text, true);
        begin
          if v_op = 'confirm' then
            perform public.confirm_count_old(v_twin, v_stepi);
          else
            perform public.show_crib_old(v_twin);
          end if;
        exception when others then
          v_err2 := v_err2 || case when v_err2 = '' then '' else '|' end || v_label || '@' || (v_names ->> v_who::text) || ':' || sqlerrm;
        end;
        execute 'reset role';

        -- After EVERY call: the two games must be identical.
        v_state := public.e4_state(v_gid, v_names);
        v_state2 := public.e4_state(v_twin, v_names);
        v_scores := public.e4_scores(v_gid, v_names);
        v_scores2 := public.e4_scores(v_twin, v_names);
        if v_state is distinct from v_state2 or v_scores is distinct from v_scores2 or v_err is distinct from v_err2 then
          raise exception 'FAIL [%] (%): the new and the old functions differ after call % (%). NEW % / % / refused % -- OLD % / % / refused %.',
            v_sc ->> 'id', v_sc ->> 'what', v_n, v_label, v_state, v_scores, v_err, v_state2, v_scores2, v_err2;
        end if;
      end if;
    end loop;

    -- 'expect': every step of the hand against what the rules say.
    if v_sc ->> 'mode' = 'expect' and v_trace is distinct from v_sc -> 'expect' ->> 'trace' then
      raise exception 'FAIL [%] (%): trace % -- expected %.',
        v_sc ->> 'id', v_sc ->> 'what', v_trace, v_sc -> 'expect' ->> 'trace';
    end if;

    -- No scripted hand can pass vacuously: exactly the refusals it names
    -- (both versions, for 'diff'), and it ends where it says -- counted to
    -- 'done' with the game live, or won.
    if v_err is distinct from v_sc ->> 'refused'
       or (v_twin is not null and v_err2 is distinct from v_sc ->> 'refused') then
      raise exception 'FAIL [%] (%): refused % (old: %) -- expected exactly %.',
        v_sc ->> 'id', v_sc ->> 'what', coalesce(nullif(v_err, ''), 'nothing'),
        coalesce(nullif(v_err2, ''), 'nothing'), coalesce(nullif(v_sc ->> 'refused', ''), 'no refusal');
    end if;
    foreach v_g in array array_remove(array[v_gid, v_twin], null) loop
      select g.status, g.ended_reason, g.phase into v_rec from public.games g where g.id = v_g;
      if (v_sc ->> 'end' = 'done' and (v_rec.status <> 'active' or v_rec.phase <> 'done'))
         or (v_sc ->> 'end' = 'win' and (v_rec.status <> 'ended' or v_rec.ended_reason is distinct from 'won')) then
        raise exception 'FAIL [%] (%): the hand should end %, but the game (%) is % / % / %.',
          v_sc ->> 'id', v_sc ->> 'what', case when v_sc ->> 'end' = 'done' then 'counted to done' else 'in a win' end,
          case when v_g = v_twin then 'old' else 'new' end, v_rec.status, v_rec.ended_reason, v_rec.phase;
      end if;
    end loop;

    v_checks := v_checks + 1;
  end loop;

  -- ==== T (continued): the next hand with 3 players ===========================
  -- g3, its hand counted ('done'), dealer A. Next Hand needs all three taps;
  -- then the deal moves one seat clockwise, to B.
  update public.games
  set status = 'active', ended_reason = null, winner_id = null, win_claim_by = null, ready_by = '{}',
      phase = 'done', dealer_id = v_a, current_player = null, count_step = 3, crib_revealed = true
  where id = v_g3;
  select hand_no into v_hand from public.games where id = v_g3;
  execute 'set local role authenticated';
  foreach v_player in array array[v_a, v_b] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    perform public.next_hand(v_g3, v_hand);
  end loop;
  execute 'reset role';

  -- [TN1] Two taps of three: nothing dealt, A still deals.
  select dealer_id, hand_no, phase, ready_by into v_rec from public.games where id = v_g3;
  if v_rec.dealer_id is distinct from v_a or v_rec.hand_no <> v_hand or v_rec.phase <> 'done'
     or not (v_rec.ready_by @> array[v_a, v_b] and v_rec.ready_by <@ array[v_a, v_b]) then
    raise exception 'FAIL [TN1] after two of three Next Hand taps: dealer %, hand % (was %), phase %, ready %.',
      v_names ->> v_rec.dealer_id::text, v_rec.hand_no, v_hand, v_rec.phase, v_rec.ready_by;
  end if;
  v_checks := v_checks + 1;

  -- [TN2] The third tap deals: B deals (the next seat), every per-hand
  -- column reset, three 5-card hands and the 1-card crib.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  perform public.next_hand(v_g3, v_hand);
  execute 'reset role';
  select dealer_id, hand_no, phase, ready_by, count_step, revealed_by, crib_revealed, current_player into v_rec
  from public.games where id = v_g3;
  select count(*) into v_n from public.game_hands where game_id = v_g3 and array_length(cards, 1) = 5;
  select coalesce(array_length(cards, 1), 0) into v_n2 from public.game_cribs where game_id = v_g3;
  if v_rec.dealer_id is distinct from v_b or v_rec.hand_no <> v_hand + 1 or v_rec.phase <> 'discard'
     or v_rec.ready_by <> '{}' or v_rec.count_step <> 0 or v_rec.revealed_by <> '{}' or v_rec.crib_revealed
     or v_rec.current_player is not null or v_n <> 3 or v_n2 is distinct from 1 then
    raise exception 'FAIL [TN2] the next 3-player hand: dealer %, hand %, phase %, ready %, step %, revealed %, crib_revealed %, current %, % full hands, crib %.',
      v_names ->> v_rec.dealer_id::text, v_rec.hand_no, v_rec.phase, v_rec.ready_by, v_rec.count_step, v_rec.revealed_by,
      v_rec.crib_revealed, v_rec.current_player, v_n, v_n2;
  end if;
  v_checks := v_checks + 1;

  -- ==== F: Teams scoring, as the owner, on the 4-player Teams table ===========
  update public.games
  set status = 'active', ended_reason = null, winner_id = null, win_claim_by = null, ready_by = '{}'
  where id = v_g4;
  update public.table_members
  set score = 0, last_points = null, last_reason = null, last_awarded_at = null
  where table_id = v_t4;

  -- [FA1] A scores 5: A and C (seats 1 and 3) both hold 5; last_* on A only.
  perform public.award_points(v_t4, v_a, 5, 'five');
  v_scores := public.e4_scores(v_g4, v_names);
  if v_scores is distinct from 'A=5/5/five/now,B=0///,C=5///,D=0///' then
    raise exception 'FAIL [FA1] a Teams award to A: %.', v_scores;
  end if;
  v_checks := v_checks + 1;

  -- [FA2] D scores 3: B and D both hold 3; A keeps its own last award.
  perform public.award_points(v_t4, v_d, 3, 'three');
  v_scores := public.e4_scores(v_g4, v_names);
  if v_scores is distinct from 'A=5/5/five/now,B=3///,C=5///,D=3/3/three/now'
     or (select status from public.games where id = v_g4) <> 'active' then
    raise exception 'FAIL [FA2] a Teams award to D: %.', v_scores;
  end if;
  v_checks := v_checks + 1;

  -- [FA3] A and C at 118 (set on both rows), C scores 4: both capped at 121,
  -- and the match is won by C, the player who scored.
  update public.table_members set score = 118 where table_id = v_t4 and user_id in (v_a, v_c);
  perform public.award_points(v_t4, v_c, 4, 'four');
  v_scores := public.e4_scores(v_g4, v_names);
  select g.status || '/' || coalesce(g.ended_reason, '-') || '/' || coalesce(v_names ->> g.winner_id::text, '-')
  into v_state from public.games g where g.id = v_g4;
  if v_scores is distinct from 'A=121/5/five/now,B=3///,C=121/4/four/now,D=3/3/three/now'
     or v_state is distinct from 'ended/won/C' then
    raise exception 'FAIL [FA3] a Teams win: % / %.', v_scores, v_state;
  end if;
  v_checks := v_checks + 1;

  -- [FA4] On a Teams table the old refusals still fire, word for word, and
  -- change nothing: a scorer who isn't seated, and a null award.
  v_err := '';
  begin
    perform public.award_points(v_t4, v_e, 1, 'nobody');
  exception when others then
    v_err := replace(replace(sqlerrm, v_t4::text, '<table>'), v_e::text, 'E');
  end;
  begin
    perform public.award_points(v_t4, v_b, null, 'no points');
  exception when others then
    v_err := v_err || '|' || sqlerrm;
  end;
  if v_err is distinct from 'No player E at table <table>.|award_points requires a point value (0 is allowed, null is not).'
     or public.e4_scores(v_g4, v_names) is distinct from 'A=121/5/five/now,B=3///,C=121/4/four/now,D=3/3/three/now' then
    raise exception 'FAIL [FA4] the Teams refusals: % / %.', v_err, public.e4_scores(v_g4, v_names);
  end if;
  v_checks := v_checks + 1;

  -- ==== F (continued): the next hand with 4 players ===========================
  -- g4 counted ('done'), dealer D (seat 4): all four tap; the deal WRAPS to
  -- seat 1, A.
  update public.games
  set status = 'active', ended_reason = null, winner_id = null, win_claim_by = null, ready_by = '{}',
      phase = 'done', dealer_id = v_d, current_player = null, count_step = 4, crib_revealed = true
  where id = v_g4;
  select hand_no into v_hand from public.games where id = v_g4;
  execute 'set local role authenticated';
  foreach v_player in array array[v_a, v_b, v_c] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    perform public.next_hand(v_g4, v_hand);
  end loop;
  execute 'reset role';

  -- [FN1] Three taps of four: nothing dealt.
  select dealer_id, hand_no, phase into v_rec from public.games where id = v_g4;
  if v_rec.dealer_id is distinct from v_d or v_rec.hand_no <> v_hand or v_rec.phase <> 'done' then
    raise exception 'FAIL [FN1] after three of four Next Hand taps: dealer %, hand % (was %), phase %.',
      v_names ->> v_rec.dealer_id::text, v_rec.hand_no, v_hand, v_rec.phase;
  end if;
  v_checks := v_checks + 1;

  -- [FN2] The fourth tap deals: A deals, four 5-card hands, no crib yet.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_d::text, true);
  perform public.next_hand(v_g4, v_hand);
  execute 'reset role';
  select dealer_id, hand_no, phase, ready_by into v_rec from public.games where id = v_g4;
  select count(*) into v_n from public.game_hands where game_id = v_g4 and array_length(cards, 1) = 5;
  select count(*) into v_n2 from public.game_cribs where game_id = v_g4;
  if v_rec.dealer_id is distinct from v_a or v_rec.hand_no <> v_hand + 1 or v_rec.phase <> 'discard'
     or v_rec.ready_by <> '{}' or v_n <> 4 or v_n2 <> 0 then
    raise exception 'FAIL [FN2] the next 4-player hand: dealer %, hand %, phase %, ready %, % full hands, % crib rows.',
      v_names ->> v_rec.dealer_id::text, v_rec.hand_no, v_rec.phase, v_rec.ready_by, v_n, v_n2;
  end if;
  v_checks := v_checks + 1;

  -- ==== P: refusals with 3 and 4 players ======================================
  -- g3 set to hand T1's cards (dealer A; B counts first, then C, then A,
  -- then A's crib), every leftover reset.
  delete from public.game_plays where game_id = v_g3;
  delete from public.game_hands where game_id = v_g3;
  delete from public.game_cribs where game_id = v_g3;
  update public.games
  set status = 'active', ended_reason = null, winner_id = null, win_claim_by = null, ready_by = '{}',
      phase = 'counting', dealer_id = v_a, current_player = v_b, play_count = 0, play_segment = 0,
      count_step = 0, revealed_by = '{}', crib_revealed = false, discarded_by = array[v_a, v_b, v_c],
      starter_card = '6D'
  where id = v_g3;
  insert into public.game_hands (game_id, user_id, cards) values
    (v_g3, v_b, array['4S', '5C', '6H', 'KC']),
    (v_g3, v_c, array['7S', '8S', '9C', '2D']),
    (v_g3, v_a, array['JD', 'QH', '3C', 'AS']);
  insert into public.game_cribs (game_id, cards) values (v_g3, array['TS', 'TH', '5D', '9H']);
  update public.table_members
  set score = 0, last_points = null, last_reason = null, last_awarded_at = null
  where table_id = v_t3;

  -- [P1] E, not at the table.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_e, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_e::text, true);
  v_msg := null;
  begin perform public.confirm_count(v_g3, 0); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'You are not a member of this table.' then
    raise exception 'FAIL [P1] a non-member counting: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P2] D, seated at the table but not one of this game's players (the
  -- owner makes room for a fourth seat, and takes it away again at once, so
  -- the table is a 3-player table for everything that follows).
  update public.tables set max_players = 4 where id = v_t3;
  insert into public.table_members (table_id, user_id) values (v_t3, v_d);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_d::text, true);
  v_msg := null;
  begin perform public.confirm_count(v_g3, 0); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  delete from public.table_members where table_id = v_t3 and user_id = v_d;
  update public.tables set max_players = 3 where id = v_t3;
  if v_msg is distinct from 'You are not a player in this game.' then
    raise exception 'FAIL [P2] a seated non-player counting: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P3] C counts on B's turn.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  v_msg := null;
  begin perform public.confirm_count(v_g3, 0); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'It is not your turn to count.' then
    raise exception 'FAIL [P3] counting out of turn: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P4] B confirms step 1 while step 0 is up: a step ahead.
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.confirm_count(v_g3, 1); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'That count is not up yet.' then
    raise exception 'FAIL [P4] a step ahead: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P5] p_step above N (3 hands and the crib: steps 0 to 3).
  v_msg := null;
  begin perform public.confirm_count(v_g3, 4); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'Invalid count step 4.' then
    raise exception 'FAIL [P5] a 3-player step above N: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P6] B counts (step 0: 14, C is next); B's same confirm again is a step
  -- behind: quiet, and nothing changes.
  perform public.confirm_count(v_g3, 0);
  execute 'reset role';
  v_state := public.e4_state(v_g3, v_names);
  v_scores := public.e4_scores(v_g3, v_names);
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.confirm_count(v_g3, 0); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is not null
     or v_state is distinct from 'active/-/-/counting/1/C/B/f'
     or public.e4_state(v_g3, v_names) is distinct from v_state
     or public.e4_scores(v_g3, v_names) is distinct from v_scores
     or v_scores is distinct from 'A=0///,B=14/14/hand: 15s 6 ~ pairs 2 ~ runs 6/now,C=0///' then
    raise exception 'FAIL [P6] a step behind: refused %, state % then %, scores % then %.',
      coalesce(v_msg, 'nothing'), v_state, public.e4_state(v_g3, v_names), v_scores, public.e4_scores(v_g3, v_names);
  end if;
  v_checks := v_checks + 1;

  -- [P7] B, not the dealer, shows the crib.
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.show_crib(v_g3); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'Only the dealer can show the crib.' then
    raise exception 'FAIL [P7] the crib shown by a non-dealer: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P8] At the crib's step (3, set by the owner), A confirms it before
  -- showing it.
  update public.games set count_step = 3, current_player = v_a where id = v_g3;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin perform public.confirm_count(v_g3, 3); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'Show the crib before confirming its count.' then
    raise exception 'FAIL [P8] the crib confirmed before it is shown: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P9] Not in the counting phase (set to play by the owner).
  update public.games set phase = 'play', count_step = 0, current_player = v_b where id = v_g3;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.confirm_count(v_g3, 0); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'This game is not in the counting phase.' then
    raise exception 'FAIL [P9] counting outside the counting phase: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P10] 4 players: step 4 is the crib (valid, but not up yet); step 5 is
  -- above N. g4 at the start of its count, A first.
  update public.games
  set status = 'active', ended_reason = null, winner_id = null, win_claim_by = null, ready_by = '{}',
      phase = 'counting', dealer_id = v_d, current_player = v_a, count_step = 0,
      revealed_by = '{}', crib_revealed = false
  where id = v_g4;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin perform public.confirm_count(v_g4, 4); exception when others then v_msg := sqlerrm; end;
  v_msg2 := null;
  begin perform public.confirm_count(v_g4, 5); exception when others then v_msg2 := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'That count is not up yet.' or v_msg2 is distinct from 'Invalid count step 5.' then
    raise exception 'FAIL [P10] 4-player steps 4 and 5: % / %.', coalesce(v_msg, 'no error'), coalesce(v_msg2, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P11] A game that doesn't exist counts as 2-player, so the old order of
  -- refusals holds -- for the new and the old functions alike: step 3 is
  -- refused as invalid before the game is looked up; step 0, and show_crib,
  -- are "Game not found."
  execute 'set local role authenticated';
  v_err := '';
  v_err2 := '';
  v_new := gen_random_uuid();
  begin perform public.confirm_count(v_new, 3); exception when others then v_err := v_err || sqlerrm; end;
  begin perform public.confirm_count(v_new, 0); exception when others then v_err := v_err || '|' || sqlerrm; end;
  begin perform public.show_crib(v_new); exception when others then v_err := v_err || '|' || sqlerrm; end;
  begin perform public.confirm_count_old(v_new, 3); exception when others then v_err2 := v_err2 || sqlerrm; end;
  begin perform public.confirm_count_old(v_new, 0); exception when others then v_err2 := v_err2 || '|' || sqlerrm; end;
  begin perform public.show_crib_old(v_new); exception when others then v_err2 := v_err2 || '|' || sqlerrm; end;
  execute 'reset role';
  if v_err is distinct from 'Invalid count step 3.|Game not found.|Game not found.' or v_err2 is distinct from v_err then
    raise exception 'FAIL [P11] a game that does not exist: new % -- old %.', v_err, v_err2;
  end if;
  v_checks := v_checks + 1;

  -- ==== F (continued): his heels, privacy, a partner's pegging win, rematch ===
  -- g4 back to the start of a hand, dealer D (seat 4), every leftover reset:
  -- known 5-card hands, a deck whose top card -- the starter -- is the jack
  -- of hearts, and team B+D at 117.
  delete from public.game_plays where game_id = v_g4;
  delete from public.game_hands where game_id = v_g4;
  delete from public.game_cribs where game_id = v_g4;
  delete from public.game_decks where game_id = v_g4;
  update public.games
  set status = 'active', ended_reason = null, winner_id = null, win_claim_by = null, ready_by = '{}',
      phase = 'discard', dealer_id = v_d, current_player = null, play_count = 0, play_segment = 0,
      count_step = 0, revealed_by = '{}', crib_revealed = false, discarded_by = '{}', starter_card = null
  where id = v_g4;
  insert into public.game_hands (game_id, user_id, cards) values
    (v_g4, v_a, array['5H', 'KC', 'QC', '2D', 'AH']),
    (v_g4, v_b, array['5S', 'KD', 'QD', '3C', 'AS']),
    (v_g4, v_c, array['9C', 'KS', 'QS', '4C', 'AD']),
    (v_g4, v_d, array['6H', '7H', '8D', '4H', 'AC']);
  insert into public.game_decks (game_id, cards) values (v_g4, array['JH', '2C', '3D', '4D', '6C', '7C']);
  update public.table_members
  set score = case when user_id in (v_b, v_d) then 117 else 0 end,
      last_points = null, last_reason = null, last_awarded_at = null
  where table_id = v_t4;

  -- [FH1] During the discard every player -- partners included -- reads
  -- only their own hand, and nobody reads a crib.
  v_hs := '';
  foreach v_player in array array[v_a, v_b, v_c, v_d] loop
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    select count(*) into v_n from public.game_hands where game_id = v_g4;
    select count(*) into v_n2 from public.game_hands where game_id = v_g4 and user_id = v_player;
    select count(*) into v_hand from public.game_cribs where game_id = v_g4;
    execute 'reset role';
    v_hs := v_hs || v_n || v_n2 || v_hand;
  end loop;
  if v_hs is distinct from '110110110110' then
    raise exception 'FAIL [FH1] reads during the discard (rows / own / crib, per player A-D): %; expected 1, 1, 0 each.', v_hs;
  end if;
  v_checks := v_checks + 1;

  -- [FH2] Everyone discards one card (A, B, C, then D); D's discard
  -- completes the crib and turns the starter: the jack, his heels, 2 to the
  -- dealer's TEAM -- B and D both at 119, last_* on D only.
  foreach v_player in array array[v_a, v_b, v_c, v_d] loop
    select cards[5] into v_msg from public.game_hands where game_id = v_g4 and user_id = v_player;
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    perform public.discard_to_crib(v_g4, array[v_msg]);
    execute 'reset role';
  end loop;
  v_scores := public.e4_scores(v_g4, v_names);
  select phase, starter_card, current_player, status into v_rec from public.games where id = v_g4;
  if v_scores is distinct from 'A=0///,B=119///,C=0///,D=119/2/his heels/now'
     or v_rec.phase <> 'play' or v_rec.starter_card is distinct from 'JH'
     or v_rec.current_player is distinct from v_a or v_rec.status <> 'active' then
    raise exception 'FAIL [FH2] his heels to the dealer''s team: % / phase % / starter % / lead % / %.',
      v_scores, v_rec.phase, v_rec.starter_card, v_names ->> v_rec.current_player::text, v_rec.status;
  end if;
  v_checks := v_checks + 1;

  -- [FH3] During the play: still only their own hand, and the crib (now
  -- complete) unreadable.
  v_hs := '';
  foreach v_player in array array[v_a, v_b, v_c, v_d] loop
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    select count(*) into v_n from public.game_hands where game_id = v_g4;
    select count(*) into v_n2 from public.game_hands where game_id = v_g4 and user_id = v_player;
    select count(*) into v_hand from public.game_cribs where game_id = v_g4;
    execute 'reset role';
    v_hs := v_hs || v_n || v_n2 || v_hand;
  end loop;
  if v_hs is distinct from '110110110110' then
    raise exception 'FAIL [FH3] reads during the play (rows / own / crib, per player A-D): %; expected 1, 1, 0 each.', v_hs;
  end if;
  v_checks := v_checks + 1;

  -- [FH4] A leads 5H, B pairs it with 5S: 2 for B -- the team reaches 121
  -- and the match is won, winner B (the player who scored), D at 121 too.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  perform public.play_card(v_g4, '5H');
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  perform public.play_card(v_g4, '5S');
  execute 'reset role';
  v_scores := public.e4_scores(v_g4, v_names);
  select g.status || '/' || coalesce(g.ended_reason, '-') || '/' || coalesce(v_names ->> g.winner_id::text, '-')
  into v_state from public.games g where g.id = v_g4;
  if v_scores is distinct from 'A=0///,B=121/2/pair/now,C=0///,D=121/2/his heels/now'
     or v_state is distinct from 'ended/won/B' then
    raise exception 'FAIL [FH4] a partner''s pegging win: % / %.', v_scores, v_state;
  end if;
  v_checks := v_checks + 1;

  -- [FH5] Nothing scores after the win.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  v_msg := null;
  begin perform public.play_card(v_g4, '9C'); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'This game is no longer active.' then
    raise exception 'FAIL [FH5] a play after the win: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [FR1] The rematch: A, B and C tap New Game -- each is recorded and
  -- waits; nothing starts, and the scores stay where the match ended.
  execute 'set local role authenticated';
  v_bad := '';
  foreach v_player in array array[v_a, v_b, v_c] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    v_new := public.start_game_with_deal(v_t4);
    v_bad := v_bad || coalesce(v_new::text, 'waiting') || ' ';
  end loop;
  execute 'reset role';
  select ready_by into v_pl from public.games where id = v_g4;
  if v_bad is distinct from 'waiting waiting waiting '
     or not (v_pl @> array[v_a, v_b, v_c] and v_pl <@ array[v_a, v_b, v_c])
     or exists (select 1 from public.games where table_id = v_t4 and status in ('cutting', 'active'))
     or public.e4_scores(v_g4, v_names) is distinct from 'A=0///,B=121/2/pair/now,C=0///,D=121/2/his heels/now' then
    raise exception 'FAIL [FR1] three of four New Game taps: % / ready % / scores %.', v_bad, v_pl, public.e4_scores(v_g4, v_names);
  end if;
  v_checks := v_checks + 1;

  -- [FR2] D's tap starts it: C deals -- the next seat clockwise from the
  -- winner B, on the LOSING team -- with no cut; four 5-card hands; every
  -- member's score back to 0, both partners of both teams.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_d::text, true);
  v_new := public.start_game_with_deal(v_t4);
  execute 'reset role';
  select status, dealer_id, players into v_rec from public.games where id = v_new;
  select count(*) into v_n from public.game_hands where game_id = v_new and array_length(cards, 1) = 5;
  select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score || '/' || coalesce(tm.last_points::text, '') || '/' || coalesce(tm.last_reason, '') || '/' || coalesce(tm.last_awarded_at::text, ''), ',' order by v_names ->> tm.user_id::text)
  into v_scores from public.table_members tm where tm.table_id = v_t4;
  if v_new is null or v_new = v_g4 or v_rec.status is distinct from 'active' or v_rec.dealer_id is distinct from v_c
     or v_rec.players is distinct from array[v_a, v_b, v_c, v_d] or v_n <> 4
     or v_scores is distinct from 'A=0///,B=0///,C=0///,D=0///'
     or (select public.seat_team(seat) from public.table_members where table_id = v_t4 and user_id = v_c)
        = (select public.seat_team(seat) from public.table_members where table_id = v_t4 and user_id = v_b) then
    raise exception 'FAIL [FR2] the rematch after a Teams win: game %, % / dealer % / players % / % full hands / scores %.',
      v_new, v_rec.status, v_names ->> v_rec.dealer_id::text, v_rec.players, v_n, v_scores;
  end if;
  v_checks := v_checks + 1;

  raise exception 'ALL % CHECKS PASSED (rolled back). A=% B=%.', v_checks, v_a, v_b;
end $$;
