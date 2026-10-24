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
