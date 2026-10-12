"use client";

import type { CSSProperties } from "react";
import { PlayingCard } from "@/components/PlayingCard";

export type PlayEvent = {
  seq: number;
  segment: number;
  user_id: string;
  kind: "play" | "go";
  card: string | null;
  count_after: number;
};

// WHICH RUN IS ON THE TABLE -- shared by the play area (which draws it) and
// the table page (which puts each player's "Go" label by their seat).
//
// The current run once it has a card; between runs, the run that just
// finished; in the hold after the last card, the newest run with any plays.
export function displayedRun(
  plays: PlayEvent[],
  playSegment: number,
  handOver: boolean
): { events: PlayEvent[]; finished: boolean } {
  const currentCards = plays.filter((p) => p.segment === playSegment && p.kind === "play");
  const finished = currentCards.length === 0 || handOver;
  const lastFinishedSegment = Math.max(
    -1,
    ...plays.filter((p) => p.segment < playSegment).map((p) => p.segment)
  );
  // At the end of the hand the last run may be the current segment (the last
  // card didn't reset the count) or the one before it (it made 31): either
  // way, the newest segment that has any plays.
  const lastSegmentWithPlays = Math.max(-1, ...plays.map((p) => p.segment));
  const segment = handOver ? lastSegmentWithPlays : finished ? lastFinishedSegment : playSegment;
  return { events: plays.filter((p) => p.segment === segment), finished };
}

// WHO SAID GO in the run on the table: the user ids of its go events.
//
// A go event's user_id is the player who could NOT play (play_card logs one
// for the opponent who can't answer, while they still hold cards) -- exactly
// "who said go". A player stuck for several plays in a row gets a go event
// each time; the Set makes that one label. The player who plays the last card
// of a deadlocked run never gets one, which matches the rules: they peg the
// point, they don't say go. DISPLAY ONLY -- the go POINT is awarded inside
// play_card from control flow, never from these rows.
export function goSayers(events: PlayEvent[]): Set<string> {
  return new Set(events.filter((p) => p.kind === "go").map((p) => p.user_id));
}

// ONE shared play area, in play order -- the order is what makes runs.
//
// One row: the run's cards, left to right, always overlapping like a fanned
// hand (newest on top, in full), with the running count straight after the
// newest card. Sizing and overlap are in .play-area in app/globals.css.
//
// WHICH RUN IS SHOWN: the current one -- or, between runs, the one that just
// finished. When a run ends (31, or nobody can go) the server starts a new
// segment with no cards in it yet; rather than blanking the row, the finished
// run stays up, dimmed, with a quiet "New count" hint, until the first card
// of the new run replaces it. Purely client-side: derived from the plays
// already loaded, nothing stored.
//
// ENDED: the final board after a win. The hand's last run stays on the table
// as it stood -- NOT dimmed, with its final count -- but no turn pill, no Go
// slot and no buttons: nothing is left to do in it.
export function PlayArea({
  plays,
  playCount,
  playSegment,
  currentPlayer,
  myUserId,
  nameFor,
  handOver,
  ended = false,
}: {
  plays: PlayEvent[];
  playCount: number;
  // The segment currently being played into. Comes from the server rather than
  // being derived, because immediately after a reset there are no plays in the
  // new segment yet -- max(segment) over `plays` would still report the old one.
  playSegment: number;
  currentPlayer: string | null;
  myUserId: string;
  nameFor: (userId: string) => string;
  // THE HOLD after the last card of the hand (see the table page): the
  // server is already in counting, but this screen still shows the final run
  // until the player taps Count hands.
  handOver?: { onCountHands: () => void };
  // The final board after a win: show the last run only (see ENDED above).
  ended?: boolean;
}) {
  // Between runs, or the hand is over: either way the row shows the run
  // that just FINISHED, dimmed, with its own final total.
  const { events: shown, finished: betweenRuns } = displayedRun(
    plays,
    playSegment,
    Boolean(handOver) || ended
  );
  const cards = shown.filter((p) => p.kind === "play");
  // The finished run keeps its own final total (31, or wherever the go
  // stopped it); the live run shows the live count.
  const shownCount = betweenRuns ? (shown.at(-1)?.count_after ?? 0) : playCount;

  const isMyTurn = currentPlayer === myUserId;

  return (
    <div className={`play-area ${ended ? "play-area--ended" : ""}`}>
      {!ended && (
        <div className="play-area__status">
          <p
            className={`whitespace-nowrap rounded-full px-2.5 py-0.5 text-xs font-semibold ${
              isMyTurn
                ? "bg-green-600 text-white"
                : "border border-zinc-300 text-zinc-600 dark:border-zinc-700 dark:text-zinc-400"
            }`}
          >
            {/* During the hold current_player is already the first COUNTER,
                so "X's turn" would be wrong here -- pegging is simply over. */}
            {handOver
              ? "Pegging over"
              : isMyTurn
                ? "Your turn"
                : currentPlayer
                  ? `${nameFor(currentPlayer)}'s turn`
                  : "Waiting..."}
          </p>
          {/* Reserved for a future Go button -- empty for now (it holds Count
              hands during the hold). The "Go" label itself sits by the player
              who said it: above my hand, or under the opponent's name. */}
          <div className="play-area__go-slot gap-2">
            {handOver && (
              // Drawn 28px tall to fit the status line; .tap-40-overlay gives it
              // a 40px tap target without growing the line.
              <button
                onClick={handOver.onCountHands}
                className="tap-40-overlay h-7 whitespace-nowrap rounded-full bg-foreground px-3 text-sm font-semibold text-background"
              >
                Count hands
              </button>
            )}
          </div>
          {betweenRuns && !handOver && (
            <span className="whitespace-nowrap text-xs text-zinc-500">New count</span>
          )}
        </div>
      )}

      <div
        className={`play-area__run ${betweenRuns && !ended ? "opacity-50" : ""}`}
        style={{ "--n": Math.max(cards.length, 1) } as CSSProperties}
        aria-label={
          ended
            ? "The last run of the game"
            : handOver
              ? "Last run of the hand"
              : betweenRuns
                ? "Last run (finished)"
                : "Cards played this run"
        }
      >
        {cards.map((event) => (
          <div key={event.seq} className="play-area__card">
            <PlayingCard card={event.card!} sizing="w-full aspect-[5/7]" />
          </div>
        ))}
        {/* The count, straight after the newest card. Hidden only before the
            very first card of the hand, when there's nothing to total. */}
        {cards.length > 0 && (
          <span className="play-area__count" aria-label={`Count ${shownCount}`}>
            {shownCount}
          </span>
        )}
      </div>
    </div>
  );
}
