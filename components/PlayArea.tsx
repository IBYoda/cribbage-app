"use client";

import { PlayingCard } from "@/components/PlayingCard";

export type PlayEvent = {
  seq: number;
  segment: number;
  user_id: string;
  kind: "play" | "go";
  card: string | null;
  count_after: number;
};

// Played cards are laid out small -- several rows of them have to fit above
// the hand on a phone.
const PLAYED_CARD_SIZING = "w-9 shrink-0 aspect-[5/7]";

export function PlayArea({
  plays,
  playCount,
  playSegment,
  currentPlayer,
  myUserId,
  nameFor,
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
}) {
  // Group into runs-to-31. Every reset increments the segment, so this is how
  // the history reads as separate runs rather than one undifferentiated pile.
  const segments = new Map<number, PlayEvent[]>();
  for (const event of plays) {
    const bucket = segments.get(event.segment) ?? [];
    bucket.push(event);
    segments.set(event.segment, bucket);
  }
  // The current segment may legitimately be empty (a reset just happened), so
  // it is included explicitly rather than only taken from what's in `plays`.
  if (!segments.has(playSegment)) segments.set(playSegment, []);

  const orderedSegments = [...segments.entries()].sort((a, b) => a[0] - b[0]);

  const lastEvent = plays.length > 0 ? plays[plays.length - 1] : null;
  const isMyTurn = currentPlayer === myUserId;

  return (
    <div className="flex w-full max-w-md flex-col items-center gap-3">
      <div className="flex items-baseline gap-2">
        <span className="text-sm text-zinc-500">Count</span>
        <span className="text-3xl font-bold tabular-nums">{playCount}</span>
        <span className="text-sm text-zinc-500">/ 31</span>
      </div>

      <div className="flex w-full flex-col gap-2">
        {orderedSegments.map(([segment, events]) => {
          const isCurrent = segment === playSegment;
          return (
            <div
              key={segment}
              // Completed runs stay visible but recede -- useful context,
              // without competing with the run actually in progress.
              className={`flex min-h-12 flex-wrap items-center gap-1 rounded border px-2 py-1 ${
                isCurrent
                  ? "border-zinc-400 dark:border-zinc-500"
                  : "border-zinc-200 opacity-50 dark:border-zinc-800"
              }`}
            >
              {events.length === 0 && (
                <span className="text-xs text-zinc-500">New count — play a card</span>
              )}
              {events.map((event) =>
                event.kind === "play" ? (
                  <PlayingCard
                    key={event.seq}
                    card={event.card!}
                    sizing={PLAYED_CARD_SIZING}
                  />
                ) : (
                  // A go is part of the history, not just a transient message:
                  // it explains a gap in the alternation, and it is what the
                  // scoring slice will read to award the point.
                  <span
                    key={event.seq}
                    className="rounded border border-amber-500 px-2 py-1 text-xs font-semibold text-amber-600 dark:text-amber-500"
                    title={`${nameFor(event.user_id)} could not play`}
                  >
                    GO
                  </span>
                )
              )}
            </div>
          );
        })}
      </div>

      {lastEvent?.kind === "go" && (
        <p className="text-sm font-medium text-amber-600 dark:text-amber-500">
          {lastEvent.user_id === myUserId
            ? "You said go"
            : `${nameFor(lastEvent.user_id)} said go`}
        </p>
      )}

      <p
        className={`rounded px-4 py-1.5 text-base font-semibold ${
          isMyTurn
            ? "bg-green-600 text-white"
            : "border border-zinc-300 text-zinc-600 dark:border-zinc-700 dark:text-zinc-400"
        }`}
      >
        {isMyTurn
          ? "Your turn"
          : currentPlayer
            ? `${nameFor(currentPlayer)}'s turn`
            : "Waiting..."}
      </p>
    </div>
  );
}
