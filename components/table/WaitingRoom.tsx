"use client";

import { useEffect, useState } from "react";
import { copyText } from "@/components/table/WaitingForPlayer";

// THE WAITING ROOM (Phase 3, app stage A2): a 3- or 4-player table before a
// game. Only behind the Phase 3 flag (lib/featureFlags.ts); a 2-player
// table never shows it.
//
//   * The table code to send, with Copy (as WaitingForPlayer).
//   * One row per seat, in seat order (clockwise): the player, or "waiting"
//     for an empty seat. "(you)" on mine, a Host tag on the host's, and with
//     4 players in Teams mode the team (seats 1 and 3 against 2 and 4).
//   * THE HOST'S MOVE: tap a player, then a seat -- an empty seat moves
//     them, an occupied one swaps the two (one set_seat call). Tapping the
//     picked player again unpicks them. The page clears the pick after the
//     call, worked or not, and shows a refusal word for word.
//   * START: only the host, only when every seat is taken. Everyone else
//     sees who they're waiting for.
//
// Pure props: the page owns the roster, the pick and the calls.

export type WaitingSeat = {
  seat: number;
  player: { userId: string; name: string; avatarUrl: string | null } | null;
};

// Teams: seats 1 and 3 are Team A, 2 and 4 Team B (seat_team on the server).
export function teamOf(seat: number) {
  return seat % 2 === 1 ? "A" : "B";
}

export function WaitingRoom({
  code,
  capacity,
  seats,
  myId,
  hostId,
  hostName,
  isTeams,
  picked,
  busy,
  onPick,
  onMove,
  canStart,
  starting,
  onStart,
}: {
  code: string;
  capacity: number;
  seats: WaitingSeat[];
  myId: string;
  hostId: string | null;
  hostName: string | null;
  isTeams: boolean;
  picked: string | null; // the player the host picked to move
  busy: boolean; // a set_seat call is on its way
  onPick: (userId: string) => void;
  onMove: (seat: number) => void;
  canStart: boolean;
  starting: boolean;
  onStart: () => void;
}) {
  const [copyState, setCopyState] = useState<"idle" | "copied" | "failed">("idle");
  useEffect(() => {
    if (copyState === "idle") return;
    const t = window.setTimeout(() => setCopyState("idle"), 2000);
    return () => window.clearTimeout(t);
  }, [copyState]);

  const isHost = hostId !== null && hostId === myId;
  const seated = seats.filter((s) => s.player).length;
  const full = seated === capacity;

  return (
    <div className="waiting-room">
      <div className="waiting-room__top">
        <p className="text-lg font-semibold leading-tight">
          {full ? "Everyone's here" : `Waiting for players (${seated} of ${capacity})`}
        </p>
        <div className="flex items-center gap-3">
          <span className="text-2xl font-bold tracking-widest tabular-nums" aria-label={`Table code ${code}`}>
            {code}
          </span>
          <button
            onClick={async () => setCopyState((await copyText(code)) ? "copied" : "failed")}
            className="min-h-9 min-w-[5rem] rounded border border-zinc-400 px-3 text-sm font-medium dark:border-zinc-600"
          >
            {copyState === "copied" ? "Copied!" : copyState === "failed" ? "Copy failed" : "Copy"}
          </button>
        </div>
      </div>

      <ol className="waiting-room__seats" aria-label="Seats">
        {seats.map(({ seat, player }) => {
          const isPicked = !!player && player.userId === picked;
          // While a player is picked, every other seat is a target.
          const isTarget = isHost && picked !== null && !isPicked;
          const action = !isHost
            ? undefined
            : isTarget
              ? () => onMove(seat)
              : player
                ? () => onPick(player.userId)
                : undefined;
          const label = player
            ? `${player.name}${player.userId === myId ? " (you)" : ""}`
            : "waiting…";
          const team = isTeams ? teamOf(seat) : null;
          const content = (
            <>
              <span className="seat-row__seat">Seat {seat}</span>
              <span className={`seat-row__name ${player ? "" : "seat-row__name--empty"}`}>{label}</span>
              {player && player.userId === hostId && <span className="seat-row__tag">Host</span>}
              {team && <span className={`seat-row__team seat-row__team--${team}`}>Team {team}</span>}
              {isTarget && <span className="seat-row__hint">{player ? "Swap" : "Move here"}</span>}
            </>
          );
          return (
            <li key={seat}>
              {action ? (
                <button
                  type="button"
                  onClick={action}
                  disabled={busy}
                  aria-pressed={player ? isPicked : undefined}
                  className={`seat-row seat-row--action ${isPicked ? "seat-row--picked" : ""} ${isTarget ? "seat-row--target" : ""}`}
                >
                  {content}
                </button>
              ) : (
                <div className="seat-row">{content}</div>
              )}
            </li>
          );
        })}
      </ol>

      <div className="waiting-room__foot">
        {isHost ? (
          <>
            <p className="text-sm text-zinc-500">
              {picked !== null
                ? "Tap a seat to move them there, or tap them again to cancel."
                : "Tap a player to move them to another seat."}
            </p>
            <button
              onClick={onStart}
              disabled={!canStart || starting || busy}
              className="min-h-11 rounded bg-foreground px-6 text-lg text-background disabled:opacity-40"
            >
              {starting ? "Starting..." : "Start"}
            </button>
          </>
        ) : full ? (
          <p className="text-sm text-zinc-500">Waiting for {hostName ?? "the host"} to start</p>
        ) : null}
      </div>
    </div>
  );
}
