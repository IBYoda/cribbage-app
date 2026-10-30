"use client";

import { Avatar } from "@/components/Avatar";

// THE LEADERBOARD's content (app/leaderboard): plain props, so the page
// reads the data and a dev preview can draw the same thing with made-up
// rows. Rows come from get_leaderboard() (docs/sql/leaderboard-l2-
// function.sql), already ordered: wins desc, losses asc, nickname.
//
// One card per player: the rank, the avatar, the nickname (truncated), and
// "W - L" big on the right; under it, small chips for the skunk stats and
// Beat God (with God's avatar). A chip with a 0 is left out, so most cards
// keep one short line of chips instead of four that wrap on a phone; a
// player with none has no chip line. Players tied on wins AND losses share a
// rank (1, 2, 2, 4). The signed-in player's card is highlighted in brass.
// Only the top SHOWN_LIMIT cards are drawn, ranked over the FULL list first,
// so a tie at the cut keeps its true rank; "Showing the top 20." says so
// when there are more.

const SHOWN_LIMIT = 20;

export type LeaderboardRow = {
  user_id: string;
  nickname: string;
  avatar_url: string | null;
  wins: number;
  losses: number;
  skunks: number;
  double_skunks: number;
  times_skunked: number;
  beat_god: number;
  skunk_tracking_since: string | null;
};

// God's avatar for the Beat God chip: null when get_computer_profiles
// failed (the chip then has no avatar).
export type GodAvatar = { name: string; url: string | null } | null;

export type LeaderboardStatus = "loading" | "error" | "ready";

export function LeaderboardPanel({
  status,
  rows,
  meId,
  god,
  refreshing,
  onRefresh,
}: {
  status: LeaderboardStatus;
  rows: LeaderboardRow[];
  meId: string | null;
  god: GodAvatar;
  refreshing: boolean;
  onRefresh: () => void;
}) {
  const since = rows[0]?.skunk_tracking_since ?? null;

  return (
    <>
      <div className="flex items-center justify-between gap-3">
        <h1 id="page-title" className="font-display text-3xl font-bold italic">
          Leaderboard
        </h1>
        {status === "ready" && (
          <button
            type="button"
            onClick={onRefresh}
            disabled={refreshing}
            className="inline-flex min-h-6 items-center text-sm font-semibold underline underline-offset-4 disabled:opacity-60"
          >
            {refreshing ? "Refreshing..." : "Refresh"}
          </button>
        )}
      </div>

      {status === "loading" ? (
        <p role="status">Loading the leaderboard...</p>
      ) : status === "error" ? (
        <div role="alert" className="flex flex-col gap-3">
          <p className="text-[var(--error-on-felt)]">Couldn&apos;t load the leaderboard just now.</p>
          <button
            type="button"
            onClick={onRefresh}
            disabled={refreshing}
            className="peg-btn peg-btn--brass peg-btn--small self-start disabled:opacity-60"
          >
            {refreshing ? "Retrying..." : "Retry"}
          </button>
        </div>
      ) : rows.length === 0 ? (
        <p role="status">No finished games yet. Go play one!</p>
      ) : (
        <>
          <ol className="flex flex-col gap-2" aria-label="Players by wins">
            {ranked(rows)
              .slice(0, SHOWN_LIMIT)
              .map(({ row, rank }) => (
                <LeaderboardCard key={row.user_id} row={row} rank={rank} isMe={row.user_id === meId} god={god} />
              ))}
          </ol>
          {rows.length > SHOWN_LIMIT && (
            <p className="text-sm text-[var(--brass-light)]">Showing the top {SHOWN_LIMIT}.</p>
          )}
          {since && (
            <p className="text-sm text-[var(--brass-light)]">Skunk stats count games since {localDate(since)}.</p>
          )}
        </>
      )}
    </>
  );
}

function LeaderboardCard({
  row,
  rank,
  isMe,
  god,
}: {
  row: LeaderboardRow;
  rank: number;
  isMe: boolean;
  god: GodAvatar;
}) {
  const chips = [
    { label: "Skunks", value: row.skunks },
    { label: "Double Skunks", value: row.double_skunks },
    { label: "Skunked", value: row.times_skunked },
  ].filter((c) => c.value > 0);

  return (
    <li
      className={`leaderboard-card ${isMe ? "leaderboard-card--me" : ""}`}
      aria-current={isMe ? "true" : undefined}
    >
      <div className="flex min-w-0 items-center gap-2.5">
        <span className="w-6 shrink-0 text-center font-display text-lg font-bold tabular-nums text-[var(--brass-light)]">
          {rank}
        </span>
        <Avatar name={row.nickname} url={row.avatar_url} />
        <span className="min-w-0 flex-1">
          <span className="block truncate font-bold">{row.nickname}</span>
          {isMe && <span className="block text-xs text-[var(--brass-light)]">You</span>}
        </span>
        <span className="flex shrink-0 flex-col items-end leading-none">
          <span
            className="font-display text-2xl font-bold tabular-nums"
            aria-label={`${row.wins} ${row.wins === 1 ? "win" : "wins"}, ${row.losses} ${row.losses === 1 ? "loss" : "losses"}`}
          >
            {row.wins} - {row.losses}
          </span>
          <span aria-hidden="true" className="mt-1 text-[11px] uppercase tracking-[0.18em] text-[var(--brass-light)]">
            W - L
          </span>
        </span>
      </div>

      {(chips.length > 0 || row.beat_god > 0) && (
        <ul className="mt-2 flex flex-wrap gap-1.5" aria-label="Skunks and Beat God">
          {chips.map((c) => (
            <li key={c.label} className="leaderboard-chip">
              {c.label} <span className="font-bold tabular-nums">{c.value}</span>
            </li>
          ))}
          {row.beat_god > 0 && (
            <li className="leaderboard-chip">
              Beat God
              {god && <Avatar name={god.name} url={god.url} size="xs" />}
              <span className="font-bold tabular-nums">{row.beat_god}</span>
            </li>
          )}
        </ul>
      )}
    </li>
  );
}

// Ranks with ties: the same wins AND losses as the row above share its rank;
// otherwise the rank is the position (1, 2, 2, 4). The rows arrive sorted.
function ranked(rows: LeaderboardRow[]) {
  const out: { row: LeaderboardRow; rank: number }[] = [];
  rows.forEach((row, i) => {
    const prev = out[i - 1];
    const tied = prev && prev.row.wins === row.wins && prev.row.losses === row.losses;
    out.push({ row, rank: tied ? prev.rank : i + 1 });
  });
  return out;
}

// The player's own date format ("Oct 30, 2026" / "30 Oct 2026").
function localDate(iso: string) {
  return new Date(iso).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}
