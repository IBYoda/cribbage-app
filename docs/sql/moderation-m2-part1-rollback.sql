-- Moderation, slice M2: ROLLBACK of PART 1 (docs/sql/moderation-m2-part1.sql).
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- WHAT IT DOES (one transaction): drops public.block_player_by_id(uuid).
-- Nothing in the database calls it. The M2 app calls it from the chat
-- card's Block: after this rollback that Block answers "Couldn't update your
-- Block List just now." (the Profile page's block by nickname, Unblock, and
-- Hide all keep working). Roll the app back first if that matters.
--
-- GUARD (raises, changing nothing, unless it holds): the four fingerprinted
-- bodies unchanged.
--
-- ONE-WAY: nothing. Block List rows made through block_player_by_id are
-- ordinary rows of public.blocks: they STAY (unblock them on the Profile
-- page). The block_change rows they logged stay too.
-- RE-RUNNABLE: "drop function if exists".

begin;

do $$
declare
  v_rec record;
  v_txt text;
begin
  for v_rec in
    select * from (values
      ('public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa'),
      ('public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c'),
      ('public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb'),
      ('public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d')
    ) as t(fn, lf, crlf)
  loop
    select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is null or v_txt not in (v_rec.lf, v_rec.crlf) then
      raise exception 'STOP: % has body md5 %; expected % (LF) or % (CRLF). Nothing was changed.', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf, v_rec.crlf;
    end if;
  end loop;
end;
$$;

drop function if exists public.block_player_by_id(uuid);

notify pgrst, 'reload schema';

commit;

-- After the commit, read-only.
select to_regprocedure('public.block_player_by_id(uuid)') is null as block_player_by_id_gone;
