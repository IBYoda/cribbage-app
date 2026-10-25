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
- Computer-table functions must keep acting only through the guard (`_computer_for_table` / `_computer_for_game`).
