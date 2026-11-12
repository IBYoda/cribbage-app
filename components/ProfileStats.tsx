"use client";

import { useEffect, useState } from "react";
import { Avatar } from "@/components/Avatar";
import { LEVEL_INFO, type ComputerLevel } from "@/lib/computer/config";
import {
  computerFaces,
  formatWinPercent,
  multiplayerRecord,
  readComputerFaces,
  readLeaderboardRows,
  readSoloStats,
  PROFILE_SOLO_ORDER,
  shapeSoloStats,
  skunkChips,
  type ComputerFace,
  type SoloEntry,
  type StatRecord,
} from "@/lib/soloStats";

// THE PROFILE'S STATS (PRD item 35, slice S3), under the profile card: two
// felt panels, "Multiplayer" (the player's own get_leaderboard() row) and
// "Solo Play" (get_solo_stats(), one row per computer, hardest first:
// PROFILE_SOLO_ORDER). Drawn like the leaderboard's cards and chips
// (.leaderboard-card, .leaderboard-chip). Read once when the page opens; no
// realtime.
//
// Quiet on failure: a read that fails says "Stats unavailable right now." in
// its own panel, and never touches the profile form above.

export type StatsState<T> = { status: "loading" } | { status: "error" } | { status: "ready"; data: T };

export function ProfileStats({ userId }: { userId: string }) {
  const [multiplayer, setMultiplayer] = useState<StatsState<StatRecord | null>>({ status: "loading" });
  const [solo, setSolo] = useState<StatsState<SoloEntry[]>>({ status: "loading" });
  const [faces, setFaces] = useState<Record<ComputerLevel, ComputerFace>>(() => computerFaces([]));

  useEffect(() => {
    let cancelled = false;
    Promise.all([readLeaderboardRows(), readSoloStats(userId), readComputerFaces()]).then(([board, mine, found]) => {
      if (cancelled) return;
      setMultiplayer(board.ok ? { status: "ready", data: multiplayerRecord(board.data, userId) } : { status: "error" });
      setSolo(
        mine.ok ? { status: "ready", data: shapeSoloStats(mine.data, userId, PROFILE_SOLO_ORDER) } : { status: "error" }
      );
      setFaces(found);
    });
    return () => {
      cancelled = true;
    };
  }, [userId]);

  return <ProfileStatsView multiplayer={multiplayer} solo={solo} faces={faces} />;
}

// Plain props, so a dev preview can draw it with made-up data.
export function ProfileStatsView({
  multiplayer,
  solo,
  faces,
}: {
  multiplayer: StatsState<StatRecord | null>;
  solo: StatsState<SoloEntry[]>;
  faces: Record<ComputerLevel, ComputerFace>;
}) {
  return (
    <>
      <section className="felt-panel flex w-full flex-col gap-3" aria-labelledby="stats-multiplayer">
        <h2 id="stats-multiplayer" className="font-display text-2xl font-bold italic">
          Multiplayer
        </h2>
        {multiplayer.status === "loading" ? (
          <p role="status" className="text-sm">
            Loading your stats...
          </p>
        ) : multiplayer.status === "error" ? (
          <p className="text-sm">Stats unavailable right now.</p>
        ) : multiplayer.data === null ? (
          <p className="text-sm">No multiplayer games yet.</p>
        ) : (
          <div className="leaderboard-card">
            <div className="flex items-center justify-between gap-3">
              <span className="text-sm">Your record</span>
              <RecordFigure record={multiplayer.data} />
            </div>
            <Chips record={multiplayer.data} />
          </div>
        )}
      </section>

      <section className="felt-panel flex w-full flex-col gap-3" aria-labelledby="stats-computer">
        <h2 id="stats-computer" className="font-display text-2xl font-bold italic">
          Solo Play
        </h2>
        {solo.status === "loading" ? (
          <p role="status" className="text-sm">
            Loading your stats...
          </p>
        ) : solo.status === "error" ? (
          <p className="text-sm">Stats unavailable right now.</p>
        ) : (
          <ol className="flex flex-col gap-2" aria-label="Your record against each computer, hardest first">
            {solo.data.map((entry) => (
              <SoloCard key={entry.level} entry={entry} face={faces[entry.level]} />
            ))}
          </ol>
        )}
      </section>
    </>
  );
}

function SoloCard({ entry, face }: { entry: SoloEntry; face: ComputerFace }) {
  return (
    <li className="leaderboard-card">
      <div className="flex min-w-0 items-center gap-3">
        <Avatar name={face.name} url={face.url} />
        <span className="flex min-w-0 flex-1 flex-col">
          <span className="block truncate font-bold leading-tight">{face.name}</span>
          <span className="text-xs text-[var(--brass-light)]">{LEVEL_INFO[entry.level].label}</span>
        </span>
        {entry.played ? (
          <RecordFigure record={entry} />
        ) : (
          <span className="shrink-0 text-sm text-[var(--brass-light)]">Not played yet</span>
        )}
      </div>
      {entry.played && <Chips record={entry} />}
    </li>
  );
}

// "W - L" big, with its label and the win % small under it, at the right.
function RecordFigure({ record }: { record: StatRecord }) {
  return (
    <span className="flex shrink-0 flex-col items-end leading-tight">
      <span
        className="font-display text-lg font-bold tabular-nums"
        aria-label={`${record.wins} ${record.wins === 1 ? "win" : "wins"}, ${record.losses} ${
          record.losses === 1 ? "loss" : "losses"
        }`}
      >
        {record.wins} - {record.losses}
      </span>
      <span className="text-[11px] uppercase tracking-[0.18em] text-[var(--brass-light)]">
        <span aria-hidden="true">W - L</span> · Win {formatWinPercent(record.winPct)}
      </span>
    </span>
  );
}

// The leaderboard's skunk chips; a 0 is left out, so none means no line.
function Chips({ record }: { record: StatRecord }) {
  const chips = skunkChips(record);
  if (chips.length === 0) return null;
  return (
    <ul className="mt-2 flex flex-wrap gap-1.5" aria-label="Skunks">
      {chips.map((c) => (
        <li key={c.label} className="leaderboard-chip">
          {c.label} <span className="font-bold tabular-nums">{c.value}</span>
        </li>
      ))}
    </ul>
  );
}
