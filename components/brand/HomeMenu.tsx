"use client";

import Link from "next/link";
import { useEffect, useRef, useSyncExternalStore } from "react";
import { Wordmark } from "@/components/brand/Wordmark";
import { SiteFooter } from "@/components/brand/SiteFooter";
import { JoinTableForm } from "@/components/brand/JoinTableForm";
import type { JoinableTable, MyTable } from "@/lib/openTables";

// What the Open Tables list shows (read by HomeView, lib/openTables.ts).
export type OpenTablesState = {
  mine: MyTable[] | null; // null until the first successful read
  joinable: JoinableTable[] | null; // likewise
  failed: boolean; // the last refresh had a failed read
  refreshing: boolean; // a Refresh the player asked for is running
  readAt: number; // when the joinable rows were read, for "5 min ago"
  onRefresh: () => void;
};

// THE MAIN MENU (signed in), as plain props -- HomeView reads the data. A
// card room like the landing page: the wordmark and the small Profile / Log
// out / Admin links at the top, the greeting, "Open Tables", and the two big
// actions -- Start a Table and Join -- at the bottom, in thumb reach.
export function HomeMenu({
  name,
  avatarUrl,
  isAdmin,
  openTables,
  onLogout,
}: {
  name: string;
  avatarUrl: string | null;
  isAdmin: boolean;
  openTables: OpenTablesState;
  onLogout: () => void;
}) {
  return (
    <div className="card-room" data-scheme="dark">
      <main className="mx-auto flex w-full max-w-md flex-1 flex-col gap-6 px-5 pt-4">
        <header className="flex items-center justify-between gap-3">
          <Wordmark size="small" />
          <nav className="flex items-center gap-4 text-sm" aria-label="Account">
            {isAdmin && (
              <Link href="/admin" className="footer-link">
                Admin
              </Link>
            )}
            <Link href="/profile" className="footer-link">
              Profile
            </Link>
            <button type="button" onClick={onLogout} className="footer-link">
              Log out
            </button>
          </nav>
        </header>

        <section className="flex items-center gap-3">
          <Avatar name={name} url={avatarUrl} />
          <div className="min-w-0">
            <p className="text-sm">
              <TimeOfDayGreeting />,
            </p>
            <p className="truncate font-display text-2xl font-bold">{name}</p>
          </div>
        </section>

        <OpenTables state={openTables} viewerName={name} viewerAvatar={avatarUrl} />

        {/* The two big actions, pushed to the bottom: in the lower third of a
            375x667 screen. */}
        <section className="mt-auto flex flex-col gap-2.5 pt-2" aria-label="Play">
          <Link href="/tables/new" className="peg-btn peg-btn--brass">
            Start a Table
          </Link>
          <JoinTableForm />
        </section>
      </main>
      <SiteFooter />
    </div>
  );
}

// "Good morning / afternoon / evening" by the player's own clock. The server
// can't know their time, so the server render -- and the first render after
// loading -- say "Welcome back"; the real greeting replaces it once on the
// client (useSyncExternalStore's server snapshot), with no hydration
// mismatch.
function timeOfDayGreeting() {
  const hour = new Date().getHours();
  if (hour < 5) return "Up late";
  if (hour < 12) return "Good morning";
  if (hour < 18) return "Good afternoon";
  return "Good evening";
}
const subscribeNever = () => () => {};
function TimeOfDayGreeting() {
  const greeting = useSyncExternalStore(subscribeNever, timeOfDayGreeting, () => "Welcome back");
  return <>{greeting}</>;
}

export function Avatar({ name, url }: { name: string; url: string | null }) {
  if (url) {
    return (
      // A plain img, as on the score plates: a Supabase Storage upload.
      // eslint-disable-next-line @next/next/no-img-element
      <img src={url} alt="" className="h-12 w-12 shrink-0 rounded-full border-2 border-[var(--brass)] object-cover" />
    );
  }
  return (
    <span
      aria-hidden="true"
      className="flex h-12 w-12 shrink-0 items-center justify-center rounded-full border-2 border-[var(--brass)] bg-[#2a6a44] text-lg font-bold"
    >
      {name.slice(0, 1).toUpperCase()}
    </span>
  );
}

// OPEN TABLES: one list, two kinds of row. First, pinned and in brass, every
// open table the player is seated at (Rejoin); then the public tables they
// could join (Join). A table the player is seated at never appears twice.
// The list is capped in height and scrolls inside itself (.open-tables-list
// in app/globals.css), so Start a Table and Join stay in the lower third.
function OpenTables({
  state,
  viewerName,
  viewerAvatar,
}: {
  state: OpenTablesState;
  viewerName: string;
  viewerAvatar: string | null;
}) {
  const { mine, joinable, failed, refreshing, readAt, onRefresh } = state;
  const myRows = mine ?? [];
  const myCodes = new Set(myRows.map((t) => t.code));
  const joinRows = (joinable ?? []).filter((t) => !myCodes.has(t.code));
  const hasRows = myRows.length + joinRows.length > 0;
  const loading = !failed && !hasRows && (mine === null || joinable === null);

  // "More below": fades the list's last rows while it can scroll further.
  // Written straight to the element (no state), after every render and on
  // scroll and resize.
  const listRef = useRef<HTMLUListElement>(null);
  useEffect(() => markMoreBelow(listRef.current));
  useEffect(() => {
    const onResize = () => markMoreBelow(listRef.current);
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  return (
    <section className="flex flex-col gap-2" aria-labelledby="open-tables-heading">
      <div className="flex items-center justify-between gap-3">
        <h2
          id="open-tables-heading"
          className="text-sm font-semibold uppercase tracking-[0.18em] text-[var(--brass-light)]"
        >
          Open Tables
        </h2>
        <button
          type="button"
          onClick={onRefresh}
          disabled={refreshing}
          className="inline-flex min-h-6 items-center text-sm font-semibold underline underline-offset-4 disabled:opacity-60"
        >
          {refreshing ? "Refreshing..." : "Refresh"}
        </button>
      </div>

      {hasRows ? (
        <>
          {failed && (
            <p role="status" className="text-sm text-[var(--error-on-felt)]">
              Couldn&apos;t load tables just now.
            </p>
          )}
          <ul
            ref={listRef}
            tabIndex={0}
            aria-label="Open Tables list"
            className="open-tables-list"
            data-failed={failed ? "true" : undefined}
            onScroll={(e) => markMoreBelow(e.currentTarget)}
          >
            {myRows.map((t) => (
              <li key={`mine-${t.code}`} className="table-row table-row--mine">
                <span className="flex min-w-0 items-center gap-3">
                  <Avatar name={viewerName} url={viewerAvatar} />
                  <span className="flex min-w-0 flex-col">
                    <span className="truncate font-bold">Your table</span>
                    <span className="text-sm leading-snug">{myTableStatus(t)}</span>
                  </span>
                </span>
                <Link href={`/tables/${t.code}`} className="rejoin-btn" aria-label={`Rejoin your table ${t.code}`}>
                  Rejoin
                </Link>
              </li>
            ))}
            {joinRows.map((t) => (
              <li key={`join-${t.code}`} className="table-row">
                <span className="flex min-w-0 items-center gap-3">
                  <Avatar name={t.hostName} url={t.hostAvatar} />
                  <span className="flex min-w-0 flex-col">
                    <span className="truncate font-bold">{t.hostName}</span>
                    <span className="text-sm">{timeAgo(t.createdAt, readAt)}</span>
                  </span>
                </span>
                <Link
                  href={`/tables/${t.code}`}
                  className="peg-btn peg-btn--brass peg-btn--small shrink-0"
                  aria-label={`Join ${t.hostName}'s table`}
                >
                  Join
                </Link>
              </li>
            ))}
          </ul>
        </>
      ) : failed ? (
        <p role="status" className="felt-panel text-sm text-[var(--error-on-felt)]">
          Couldn&apos;t load tables just now.
        </p>
      ) : (
        <p role="status" className="felt-panel text-sm">
          {loading ? "Looking for tables..." : "No open tables right now. Start one below."}
        </p>
      )}
    </section>
  );
}

// "Game in progress" / "Between games · with Elsa" / "Waiting for a second
// player" -- the same lines the old "Your tables" list used.
function myTableStatus(t: MyTable) {
  const base = t.gameLive
    ? "Game in progress"
    : t.others.length > 0
      ? "Between games"
      : "Waiting for a second player";
  return t.others.length > 0 ? `${base} · with ${t.others.join(", ")}` : base;
}

function markMoreBelow(el: HTMLElement | null) {
  if (!el) return;
  el.dataset.more = String(el.scrollTop + el.clientHeight < el.scrollHeight - 2);
}

// "just now", "5 min ago", "2 h ago" -- relative to when the rows were read.
function timeAgo(iso: string, now: number) {
  const minutes = Math.max(0, Math.floor((now - new Date(iso).getTime()) / 60_000));
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} min ago`;
  return `${Math.floor(minutes / 60)} h ago`;
}
