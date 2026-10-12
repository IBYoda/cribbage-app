"use client";

import { useState } from "react";
import { DealerChip } from "@/components/table/OpponentBand";

export type PlateMember = {
  userId: string;
  name: string;
  avatarUrl: string | null;
};

// One score plate. A plate has one OR MORE members: 2- and 3-player games and
// 4-player individual games have one member per plate; a 4-player TEAM game
// has two plates of two. The strip doesn't care which -- the caller decides
// the grouping, so Phase 3 only has to build the list differently.
export type ScorePlate = {
  key: string;
  members: PlateMember[];
  score: number;
  isMine: boolean;
  hasDealer: boolean;
  // The plate's most recent award, for the flash. For a team plate this will
  // be the latest award to either partner.
  lastPoints: number | null;
  lastReason: string | null;
  lastAwardedAt: string | null;
};

// The scores, directly under my hand: a row of equal-width plates, 48px tall.
// Fits 2, 3 or 4 plates at 375px wide (4 plates are ~90px each: the name
// truncates, the score doesn't).
export function ScoreStrip({ plates }: { plates: ScorePlate[] }) {
  return (
    <div className="relative">
      <div className="flex h-12 gap-1">
        {plates.map((plate) => (
          <div
            key={plate.key}
            className={`flex min-w-0 flex-1 items-center gap-1.5 rounded-lg border px-2 ${
              plate.isMine
                ? "border-zinc-500 bg-zinc-100 dark:border-zinc-400 dark:bg-zinc-800"
                : "border-zinc-300 dark:border-zinc-700"
            }`}
          >
            <div className="flex shrink-0 -space-x-2">
              {plate.members.map((m) => (
                <Avatar key={m.userId} member={m} />
              ))}
            </div>
            <div className="flex min-w-0 flex-1 flex-col leading-tight">
              <span className="flex min-w-0 items-center gap-1 text-xs font-medium">
                <span className="truncate">
                  {plate.members.map((m) => m.name).join(" & ")}
                  {plate.isMine && <span className="text-zinc-500"> (you)</span>}
                </span>
                {plate.hasDealer && <DealerChip />}
              </span>
            </div>
            <span className="shrink-0 text-xl font-bold tabular-nums">{plate.score}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function Avatar({ member }: { member: PlateMember }) {
  if (member.avatarUrl) {
    return (
      // A plain img, not next/image: these are user uploads from Supabase
      // Storage at 28px, and next/image would need the storage host added to
      // the config for no real gain at this size.
      // eslint-disable-next-line @next/next/no-img-element
      <img
        src={member.avatarUrl}
        alt=""
        className="h-7 w-7 rounded-full border-2 border-background object-cover"
      />
    );
  }
  return (
    <span className="flex h-7 w-7 items-center justify-center rounded-full border-2 border-background bg-zinc-400 text-xs font-bold text-white dark:bg-zinc-600">
      {member.name.slice(0, 1).toUpperCase()}
    </span>
  );
}

// ONE flash for the table: "Elsa +2 — pair", naming the player the way PRD
// Section 8 asks ("Sam +2 — pair"). Shown in the middle of the pile row,
// above Sort, between the crib and the starter (see PileRow) -- it never adds
// height and never covers cards.
//
// Two short lines -- the name, then the reason -- each truncated with an
// ellipsis if the gap between the piles is too narrow (the full text is in
// the tooltip), so the pill always stays inside the gap.
//
// Same pattern as PlayerScore: flash on CHANGE of the newest award, not on
// freshness, so a page loaded with an hour-old award doesn't replay it. Keyed
// on the award time so a new award restarts the CSS animation.
export function ScoreFlash({ plates }: { plates: ScorePlate[] }) {
  // Compared as times, not strings: the same timestamp can arrive formatted
  // differently from a REST read and from a realtime payload.
  const timeOf = (p: ScorePlate | null) => (p?.lastAwardedAt ? Date.parse(p.lastAwardedAt) || 0 : 0);
  const latest = plates.reduce<ScorePlate | null>(
    (best, p) => (p.lastAwardedAt && timeOf(p) >= timeOf(best) ? p : best),
    null
  );
  const latestAt = latest?.lastAwardedAt ?? null;

  const [seenAt, setSeenAt] = useState<string | null>(latestAt);
  const [hasNew, setHasNew] = useState(false);
  if (latestAt !== seenAt) {
    setSeenAt(latestAt);
    setHasNew(true);
  }

  if (!hasNew || !latest || latest.lastPoints === null) return null;

  const name = latest.members.map((m) => m.name).join(" & ");
  const points = latest.lastPoints >= 0 ? `+${latest.lastPoints}` : String(latest.lastPoints);

  return (
    <span
      key={latestAt}
      title={`${name} ${points}${latest.lastReason ? ` — ${latest.lastReason}` : ""}`}
      className="score-flash flex max-w-full flex-col items-center rounded-xl bg-green-600 px-2 py-0.5 text-[11px] font-semibold leading-[13px] text-white shadow"
    >
      <span className="flex max-w-full">
        <span className="min-w-0 truncate">{name}</span>
        <span className="shrink-0">&nbsp;{points}</span>
      </span>
      {latest.lastReason && <span className="max-w-full truncate">{latest.lastReason}</span>}
    </span>
  );
}
