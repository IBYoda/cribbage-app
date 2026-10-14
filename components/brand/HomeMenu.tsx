"use client";

import Link from "next/link";
import { useSyncExternalStore } from "react";
import { Wordmark } from "@/components/brand/Wordmark";
import { SiteFooter } from "@/components/brand/SiteFooter";
import { JoinTableForm } from "@/components/brand/JoinTableForm";

// One open table the player is seated at.
export type YourTable = {
  code: string;
  others: string[]; // the other players' names
  gameLive: boolean; // a game is being cut for or played
};

export type YourTablesState =
  | { status: "loading" }
  | { status: "error" }
  | { status: "ready"; tables: YourTable[] };

// THE MAIN MENU (signed in), as plain props -- HomeView reads the data. A
// card room like the landing page: the wordmark and the small Profile / Log
// out / Admin links at the top, the greeting, "Your tables", and the two big
// actions -- Start a Table and Join -- at the bottom, in thumb reach.
export function HomeMenu({
  name,
  avatarUrl,
  isAdmin,
  tables,
  onLogout,
}: {
  name: string;
  avatarUrl: string | null;
  isAdmin: boolean;
  tables: YourTablesState;
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

        <YourTables state={tables} />

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

function Avatar({ name, url }: { name: string; url: string | null }) {
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

// YOUR TABLES: one tap back into any open table the player is seated at.
function YourTables({ state }: { state: YourTablesState }) {
  return (
    <section className="flex flex-col gap-2" aria-labelledby="your-tables-heading">
      <h2
        id="your-tables-heading"
        className="text-sm font-semibold uppercase tracking-[0.18em] text-[var(--brass-light)]"
      >
        Your tables
      </h2>
      {state.status === "loading" ? (
        <p className="felt-panel text-sm">Looking for your tables...</p>
      ) : state.status === "error" ? (
        <p className="felt-panel text-sm">
          Couldn&apos;t load your tables just now. You can still start or join one below.
        </p>
      ) : state.tables.length === 0 ? (
        <p className="felt-panel text-sm">No open tables. Start one, or join with a code.</p>
      ) : (
        <ul className="flex flex-col gap-2">
          {state.tables.map((t) => (
            <li key={t.code}>
              <Link href={`/tables/${t.code}`} className="table-row">
                <span className="flex min-w-0 flex-col">
                  <span className="text-lg font-bold tracking-widest">Table {t.code}</span>
                  <span className="truncate text-sm">
                    {t.gameLive
                      ? "Game in progress"
                      : t.others.length > 0
                        ? "Between games"
                        : "Waiting for a second player"}
                    {t.others.length > 0 && ` · with ${t.others.join(", ")}`}
                  </span>
                </span>
                <span className="shrink-0 rounded-full bg-violet-600 px-3 py-1 text-sm font-semibold text-white">
                  Rejoin
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
