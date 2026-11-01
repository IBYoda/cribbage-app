import type { ReactNode } from "react";
import { displayedRun, type PlayEvent } from "@/lib/pegging";

// THE SQUARE TABLE (PRD item 31; not on the live table yet): the centre of
// the table during pegging -- the running count in large type, the status
// pill under it, and the score flash ("Yoda +2 / fifteen") over the pill.
//
// It takes the same props as PlayArea and means the same by them, so it can
// stand in for PlayArea's status line and count (the cards themselves move
// to the seats: SeatPlayedCards):
//   * the count shows the live play_count; between runs (and in the hold, and
//     on the final board) the finished run's own total; nothing before the
//     very first card of the hand;
//   * the pill: "Your turn" / "<name>'s turn" / "Waiting..."; "Pegging over"
//     in the hold; nothing on the final board (ended);
//   * "New count" under the pill between runs;
//   * the hold's "Count hands" button (handOver) -- tapping it only clears
//     this screen's hold, as before.
// flash: the ScoreFlash element (components/table/ScoreStrip.tsx), which keeps
// all its own rules; it is drawn over the pill, so an award covers the
// status for as long as it shows.
export function CenterCount({
  plays,
  playCount,
  playSegment,
  currentPlayer,
  myUserId,
  nameFor,
  handOver,
  ended = false,
  flash,
  prompt,
}: {
  plays: PlayEvent[];
  playCount: number;
  playSegment: number;
  currentPlayer: string | null;
  myUserId: string;
  nameFor: (userId: string) => string;
  handOver?: { onCountHands: () => void };
  ended?: boolean;
  flash?: ReactNode;
  // Before pegging (the discard): this line -- a <p>, like the pill it
  // replaces -- in place of the status pill, and no "New count". Keeping the
  // same elements means the score flash stays mounted from the discard into
  // pegging (his heels lands right at that change).
  prompt?: ReactNode;
}) {
  const { events: shown, finished: betweenRuns } = displayedRun(
    plays,
    playSegment,
    Boolean(handOver) || ended
  );
  const hasCards = shown.some((p) => p.kind === "play");
  const shownCount = betweenRuns ? (shown.at(-1)?.count_after ?? 0) : playCount;
  const isMyTurn = currentPlayer === myUserId;

  return (
    <div className="center-count">
      <span className="center-count__number" aria-label={hasCards ? `Count ${shownCount}` : undefined}>
        {hasCards ? shownCount : ""}
      </span>

      {/* Ended (the final board): no pill, but the score flash still has
          its place, so the winning peg's flash carries over. The pill's slot
          stays (as false), so the flash keeps its place in the tree. */}
      {(!ended || flash) && (
        <div className="center-count__pill">
          {!ended && (prompt ?? (
            <p
              className={`whitespace-nowrap rounded-full px-2.5 py-0.5 text-xs font-semibold ${
                isMyTurn
                  ? "bg-green-600 text-white surface:bg-violet-600"
                  : "border border-zinc-300 text-zinc-600 dark:border-zinc-700 dark:text-zinc-400"
              }`}
            >
              {handOver
                ? "Pegging over"
                : isMyTurn
                  ? "Your turn"
                  : currentPlayer
                    ? `${nameFor(currentPlayer)}'s turn`
                    : "Waiting..."}
            </p>
          ))}
          {flash && <div className="center-count__flash">{flash}</div>}
        </div>
      )}

      {betweenRuns && !handOver && !ended && !prompt && (
        <span className="whitespace-nowrap text-xs text-zinc-500">New count</span>
      )}

      {handOver && (
        // 28px tall like the old status line's button; .tap-40-overlay gives
        // it a 40px tap target.
        <button
          onClick={handOver.onCountHands}
          className="tap-40-overlay h-7 whitespace-nowrap rounded-full bg-foreground px-3 text-sm font-semibold text-background"
        >
          Count hands
        </button>
      )}
    </div>
  );
}
