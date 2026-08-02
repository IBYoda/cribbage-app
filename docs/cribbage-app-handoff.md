# Cribbage App — Handoff Notes for Claude Code

**Purpose of this file:** Context for a fresh Claude Code session working in this repo. Drop this into the chat (or save as part of `AGENTS.md`) so it doesn't have to be re-explained.

---

## What this project is

A real-time multiplayer cribbage companion app for 2-4 players, playing remotely over Zoom with physical cribbage boards. The app handles the parts that are broken when everyone deals from their own physical deck — a shared virtual deck, private hands, and score tracking — while players keep their physical boards and pegs for the tactile part of the game.

**Full requirements live in the project's PRD** (`cribbage-app-prd.md` — ask the user for it if not already in this folder). Key decisions worth knowing without re-reading the whole thing:

- Responsive **web app** (not native mobile) — Next.js, works in a phone browser
- **Confirm Count** and **auto-scored pegging** calculate all scores automatically — nothing is typed in manually
- **Show Hand** is a voluntary, always-available reveal button (not turn-gated); **Confirm Count** is turn-gated
- Structure is **Table** (persistent room, 4-digit join code) → can host multiple **Games** (one match to 121) back to back via "New Game," without leaving the table
- Real accounts (Supabase Auth) with profile icon + editable game nickname
- Admin role for the project owner: view/kill abandoned tables & games; 5-hour game timeout, 12-hour table timeout, both automatic
- 4-player teams do **not** auto-share hands between partners
- Player stats ("19"s, skunks, stink holes, etc.) are an explicit **stretch goal**, deliberately not tracked in v1 — no need to build hand-level logging now

## Tech stack

- Next.js (App Router, TypeScript, Tailwind) — scaffolded via `create-next-app`
- Supabase — Auth, Postgres database, Realtime
- Vercel — hosting (not yet connected)
- This is a **completely separate** GitHub repo / Supabase project / Vercel project from the user's other app (Hello Fresh Helper). Nothing is shared between them.

## Current state (as of this handoff)

- [x] Next.js scaffold created (`npx create-next-app@latest .`) in `C:\Users\ib_yo\Repos\cribbage-app`
- [x] `@supabase/supabase-js` installed
- [x] New Supabase project created, with recommended settings:
  - "Automatically expose new tables" — **unchecked**
  - "Enable automatic RLS" — **checked**
  - (Both chosen so new tables are locked-down-by-default, not open-by-default)
- [x] `.env.local` created with `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` (using Supabase's newer **publishable key**, not the secret key — confirmed `.env*` is in `.gitignore`)
- [x] `lib/supabase.ts` written — creates and exports a single shared Supabase client, reading the two env vars, with a startup check that throws a clear error if either is missing
- [ ] Not yet verified the Supabase connection actually works end-to-end (no test run yet)
- [ ] Initial scaffold not yet committed/pushed to GitHub (user is doing this now, on `main`, as the baseline before any feature branches)

## What's next: Phase 1, Slice 1 — Auth

Per the phased build order, Phase 1 is: Accounts, Tables & Admin basics — broken into small slices. **Slice 1 is just sign-up / log-in / log-out**, nothing else yet (no profiles, no tables).

Suggested first step once `lib/supabase.ts` is verified: a minimal sign-up and login page using Supabase Auth's email/password methods (`supabase.auth.signUp`, `supabase.auth.signInWithPassword`, `supabase.auth.signOut`), on its own git branch (e.g. `feature/auth`), tested end-to-end (create an account, log out, log back in) before moving to Slice 2 (profiles).

## Working conventions (please follow these)

- **Small, testable vertical slices** — one feature end-to-end and validated before the next. If a slice can't reasonably be split further, say so explicitly rather than quietly bundling extra things in.
- **Every slice starts with creating its own branch** — the very first git command run for a new slice is `git checkout -b feature/whatever-the-slice-is`, done by Claude Code at the start of the session, before any code is written. Never build on main.
- **After that, no more git commands** — no add, commit, push, or merge. The user handles all of that themselves once the slice is built and verified.
- **The one exception is small, self-contained doc-only changes like this one** — same rule applies: create the branch first, then edit, nothing else.
- **Explain the "why," not just the code** — the user is learning to direct AI-assisted development, not memorize every line.
- User is on **PowerShell (Windows 11)** — quote file paths that contain `[` or `]` (not relevant yet, but will matter once dynamic routes like `app/games/[id]/page.tsx` show up).
- Before doing real-world-data work (e.g. touching Supabase schema, external APIs), do a real reconnaissance pass first — check actual current structure, don't assume.
- When something can't be fully verified (e.g. no way to click through a UI), say so plainly rather than implying full confidence.
