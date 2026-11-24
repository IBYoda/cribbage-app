<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

# New tables

From October 30, 2026, Supabase no longer grants Data API access to new tables in the `public` schema. A new table needs explicit grants, or supabase-js gets "permission denied".

- Every SQL file that creates a table in `public` includes its GRANT statements in the same file, with row-level security enabled on the table. Follow the template's order.
- Least privilege: nothing for `anon` unless there is a stated reason. For `authenticated`, only the privileges the policies and the app actually use. `service_role` only if something needs it.
- The matching verification SQL checks the grants too.
- Template: `docs/sql/appearance-settings.sql` (it revokes all from `public`, `anon` and `authenticated`, then grants `authenticated` only SELECT, INSERT and UPDATE). Its grant check is in `docs/sql/appearance-settings-verification.sql`.
- Existing tables are unaffected: they keep their current grants.
- Function EXECUTE grants are a separate matter; this rule covers tables only.

# Game functions (since the computer opponent)

The eight 2-player game functions (`start_game_with_deal`, `draw_cut_card`, `acknowledge_deal_cut`, `discard_to_crib`, `play_card`, `show_crib`, `confirm_count`, `next_hand`) now live as internal `<name>_as(p_actor, ...)` functions, with thin public wrappers that pass `auth.uid()`.

- Change game rules in the `_as` function, never in the wrapper.
- After changing one, re-run `docs/sql/computer-c1-verification.sql` and `docs/sql/computer-c2-verification.sql`, and update the md5 fingerprints in `computer-c1-verification.sql`.
- The older `phase3-e*` and muggins verification suites fingerprint function bodies and stop at those checks by design after C1; they are no longer the regression proof.
- `leave_table`, `end_timed_out_sessions`, `assign_table_seat` and `table_host` are fingerprinted by `docs/sql/end-empty-tables-precheck.sql` and `end-empty-tables-verification.sql` (check C4: the md5 of the live body, LF or CRLF). Slice C did not change them: it added two triggers on `table_members` beside `table_members_assign_seat` instead. `table_members_end_when_empty` (AFTER DELETE) ends a human table as `'empty'` when its last non-computer seat goes; `table_members_require_open` (BEFORE INSERT, which must sort after `table_members_assign_seat`) refuses a seat at a table that is not open. A new `end_empty_tables()` sweep (pg_cron job `end-empty-tables`, every 5 minutes) ends any open table with no human seat that is more than 10 minutes old. If you ever change one of those four bodies, capture the live body first (`pg_get_functiondef`), and update both files' expected md5s.
- Table codes (step 3 slice B, `docs/sql/free-codes-part1.sql` and `free-codes-part2.sql`): a code is freed when its table ends (`tables_code_open_key`, unique among non-ended tables only; `tables_code_key` is gone once part 2 runs) and reused after a 24-hour cooldown (`tables.ended_at`, stamped by the `tables_set_ended_at` trigger; `_pick_table_code()`). So: never look a table up by code alone after the first lookup -- hold its id (links carry `?t=<id>`; `join_table_by_code` and `watch_table` take `p_table_id`). In verification suites, pick free codes with "no OPEN table holds it, or every table while `tables_code_open_key` doesn't exist" (the predicate the suites already use), and count codes among non-ended tables only.
- Before replacing any function, compare its live body's md5 with the file you think it came from: the live text can differ from the committed file (it did for `create_computer_table`; see `docs/sql/computer-live-create_computer_table-2026-11-23.sql`).
- Computer-table functions must keep acting only through the guard (`_computer_for_table` / `_computer_for_game`).
