"use client";

import type { ReactNode } from "react";
import { AVATAR_DIAMETERS, Avatar } from "@/components/Avatar";
import { useWingsOn } from "@/components/Wings";
import { rankWithTies } from "@/lib/follows";
import { formatWinPercent, winPercent } from "@/lib/soloStats";
import { displayTier, placementFor, tierForCount, wingsOverhang } from "@/lib/wings";

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
  // Returned by the functions; no longer shown (the skunk footnote was
  // removed from the leaderboard in S4).
  skunk_tracking_since: string | null;
};

// God's avatar for the Beat God chip: null when get_computer_profiles
// failed (the chip then has no avatar).
export type GodAvatar = { name: string; url: string | null } | null;

export type LeaderboardStatus = "loading" | "error" | "ready";

// A COMPUTER BOARD (S4, lib/leaderboardFilter.ts): the rows are
// get_solo_leaderboard(level)'s -- the same columns as get_leaderboard()'s,
// counting only games against that computer. Set, the panel shows the
// heading, the win % on each card, no Beat God chip (wings still come from
// beat_god), its own empty and failed words, and Refresh also on a failed
// read. Unset (Multiplayer), the panel is exactly as before S4.
export type ComputerBoard = { heading: string; empty: string; failed: string };

export function LeaderboardPanel({
  status,
  rows,
  meId,
  god,
  refreshing,
  onRefresh,
  wingsLayout = "reserve",
  filterBar,
  board,
  shownLimit = SHOWN_LIMIT,
  star,
  note,
}: {
  status: LeaderboardStatus;
  rows: LeaderboardRow[];
  meId: string | null;
  god: GodAvatar;
  refreshing: boolean;
  onRefresh: () => void;
  // WINGS ON THE ROWS (2.2 x): "reserve" keeps the same room beside every
  // avatar once anyone shown has wings, so the avatars stay in one column;
  // "indent" moves only the winged rows over. With no wings shown, neither
  // changes anything.
  wingsLayout?: "reserve" | "indent";
  // The filter chips, drawn under the title row (S4).
  filterBar?: ReactNode;
  board?: ComputerBoard | null;
  // FRIENDS (PRD item 36). shownLimit: how many cards to draw (null: all --
  // the Friends view, at most 51). star: the follow star for a card, drawn on
  // every card but the signed-in player's own. note: a line under the cards
  // (or in place of the empty message when there are none). Unset, the panel
  // is exactly as before.
  shownLimit?: number | null;
  star?: (row: LeaderboardRow) => ReactNode;
  note?: string | null;
}) {
  const limit = shownLimit ?? Infinity;
  const wingsOn = useWingsOn();
  const leaderboardWings = placementFor("leaderboard");
  const anyWinged =
    wingsOn &&
    rankWithTies(rows)
      .slice(0, limit)
      .some(({ row }) => displayTier(row.user_id, tierForCount(row.beat_god)) !== null);
  const reserve =
    wingsLayout === "reserve" && anyWinged ? wingsOverhang(AVATAR_DIAMETERS.md, leaderboardWings.scale) : 0;

  return (
    <>
      <div className="flex items-center justify-between gap-3">
        <h1 id="page-title" className="font-display text-3xl font-bold italic">
          Leaderboard
        </h1>
        {(status === "ready" || (board && status === "error")) && (
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
      {filterBar}
      {board && (
        <h2 className="-mb-1 font-display text-xl font-bold italic text-[var(--brass-light)]">{board.heading}</h2>
      )}

      {status === "loading" ? (
        <p role="status">Loading the leaderboard...</p>
      ) : board && status === "error" ? (
        // A computer board fails quietly: the Refresh above tries again.
        <p role="status" className="text-sm">
          {board.failed}
        </p>
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
        <p role="status">{note ?? (board ? board.empty : "No finished games yet. Go play one!")}</p>
      ) : (
        <>
          <ol className="flex flex-col gap-2" aria-label="Players by wins">
            {rankWithTies(rows)
              .slice(0, limit)
              .map(({ row, rank }) => (
                <LeaderboardCard
                  key={row.user_id}
                  row={row}
                  rank={rank}
                  isMe={row.user_id === meId}
                  god={god}
                  wingsOn={wingsOn}
                  reserve={reserve}
                  computerBoard={!!board}
                  star={star && row.user_id !== meId ? star(row) : undefined}
                />
              ))}
          </ol>
          {rows.length > limit && (
            <p className="text-sm text-[var(--brass-light)]">Showing the top {limit}.</p>
          )}
          {note && <p className="text-sm text-[var(--brass-light)]">{note}</p>}
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
  wingsOn,
  reserve,
  computerBoard,
  star,
}: {
  row: LeaderboardRow;
  rank: number;
  isMe: boolean;
  god: GodAvatar;
  wingsOn: boolean;
  // Room kept beside an avatar with no wings, so every row's avatar lines up.
  reserve: number;
  // On a computer board: the win % beside the record, and no Beat God chip
  // (the wings above still come from beat_god).
  computerBoard: boolean;
  // The follow star (never on my own card): top-right, positioned over the
  // card (.follow-star), with 28px kept free at the end of the name line.
  star?: ReactNode;
}) {
  // The row already has the count: no read of its own.
  const tier = wingsOn ? displayTier(row.user_id, tierForCount(row.beat_god)) : null;
  const chips = [
    { label: "Skunks", value: row.skunks },
    { label: "Double Skunks", value: row.double_skunks },
    { label: "Skunked", value: row.times_skunked },
  ].filter((c) => c.value > 0);
  const showBeatGod = !computerBoard && row.beat_god > 0;

  return (
    <li
      className={`leaderboard-card ${isMe ? "leaderboard-card--me" : ""}`}
      aria-current={isMe ? "true" : undefined}
    >
      {/* The rank, right-aligned, then the avatar 4px along: its wings use the
          rank column's spare room and stop short of the number. Then the
          name on a line of its own, the whole width, and the record under it,
          at the right. My own row says so by its brass highlight alone (and
          aria-current for screen readers). */}
      <div className="flex min-w-0 items-center">
        <span className="w-6 shrink-0 text-right font-display text-lg font-bold tabular-nums text-[var(--brass-light)]">
          {rank}
        </span>
        <span
          className="ml-1 inline-flex shrink-0"
          style={!tier && reserve ? { marginLeft: reserve + 4, marginRight: reserve } : undefined}
        >
          <Avatar name={row.nickname} url={row.avatar_url} tier={tier} wings={placementFor("leaderboard")} />
        </span>
        <span className="ml-2 flex min-w-0 flex-1 flex-col">
          <span className={star ? "block truncate pr-7 font-bold leading-tight" : "block truncate font-bold leading-tight"}>
            {row.nickname}
          </span>
          <span className="flex items-baseline justify-end gap-1.5 leading-tight">
            <span
              className="font-display text-lg font-bold tabular-nums"
              aria-label={`${row.wins} ${row.wins === 1 ? "win" : "wins"}, ${row.losses} ${row.losses === 1 ? "loss" : "losses"}`}
            >
              {row.wins} - {row.losses}
            </span>
            <span aria-hidden="true" className="text-[11px] uppercase tracking-[0.18em] text-[var(--brass-light)]">
              W - L
            </span>
            {computerBoard && (
              <span className="text-[11px] uppercase tracking-[0.18em] text-[var(--brass-light)]">
                · Win {formatWinPercent(winPercent(row.wins, row.losses))}
              </span>
            )}
          </span>
        </span>
      </div>

      {(chips.length > 0 || showBeatGod) && (
        <ul className="mt-2 flex flex-wrap gap-1.5" aria-label={computerBoard ? "Skunks" : "Skunks and Beat God"}>
          {chips.map((c) => (
            <li key={c.label} className="leaderboard-chip">
              {c.label} <span className="font-bold tabular-nums">{c.value}</span>
            </li>
          ))}
          {showBeatGod && (
            <li className="leaderboard-chip">
              Beat God
              {god && <Avatar name={god.name} url={god.url} size="xs" />}
              <span className="font-bold tabular-nums">{row.beat_god}</span>
            </li>
          )}
        </ul>
      )}
      {star}
    </li>
  );
}
