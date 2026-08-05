"use client";

import { useState } from "react";
import { FlipCard } from "@/components/PlayingCard";
import { rankLabel } from "@/lib/cards";

// A fan wide enough to read as "a deck" without producing an absurd number of
// tab stops. The reference app shows ~40; 24 gets the same effect on a phone.
const FAN_SIZE = 24;

type CutEntry = { user_id: string; card: string };
type CutRound = CutEntry[];

// "a 7" but "an A" / "an 8".
function withArticle(rank: string) {
  return /^[A8]/.test(rank) ? `an ${rank}` : `a ${rank}`;
}

// Placeholder for a seat whose player hasn't cut yet. Deliberately an empty
// outline rather than a face-down card: a card back would imply they hold
// something, when in fact nothing has been drawn.
function EmptySlot() {
  return (
    <div className="aspect-[5/7] w-24 rounded-lg border-2 border-dashed border-white/25" />
  );
}

export function CutForDealView({
  rounds,
  players,
  myUserId,
  dealerId,
  ackBy,
  nameFor,
  onDraw,
  onAcknowledge,
}: {
  // Full history. The round in progress is always the last element -- there is
  // no separate pointer, so these cannot drift apart.
  rounds: CutRound[];
  players: string[];
  myUserId: string;
  // Null until a round completes with a unique lowest card. That is also how
  // "this round was a tie" is detected: complete, but still no dealer.
  dealerId: string | null;
  ackBy: string[];
  nameFor: (userId: string) => string;
  // Both return an error message, or null on success. This view fills the
  // screen, so anything the page renders underneath would be invisible.
  onDraw: () => Promise<string | null>;
  onAcknowledge: () => Promise<string | null>;
}) {
  const [tappedIndex, setTappedIndex] = useState<number | null>(null);
  const [drawPending, setDrawPending] = useState(false);
  const [ackPending, setAckPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const round: CutRound = rounds[rounds.length - 1] ?? [];
  const roundNumber = rounds.length;

  const myEntry = round.find((entry) => entry.user_id === myUserId);
  const opponentIds = players.filter((id) => id !== myUserId);

  const roundComplete = round.length === players.length;
  const isDecisive = roundComplete && dealerId !== null;
  const isTie = roundComplete && dealerId === null;

  const iHaveDrawn = Boolean(myEntry);
  const iHaveAcked = ackBy.includes(myUserId);

  const stillToDraw = players
    .filter((id) => id !== myUserId && !round.some((entry) => entry.user_id === id))
    .map(nameFor);
  const stillToAck = players
    .filter((id) => id !== myUserId && !ackBy.includes(id))
    .map(nameFor);

  async function handleDraw(index: number) {
    if (iHaveDrawn || drawPending) return;
    setTappedIndex(index);
    setDrawPending(true);
    setError(null);

    const message = await onDraw();

    setDrawPending(false);
    if (message) {
      setError(message);
      setTappedIndex(null);
    }
  }

  async function handleAcknowledge() {
    setAckPending(true);
    setError(null);
    const message = await onAcknowledge();
    setAckPending(false);
    if (message) setError(message);
  }

  function cardFor(userId: string) {
    return round.find((entry) => entry.user_id === userId)?.card ?? null;
  }

  return (
    // Page content, not an overlay -- during the cut there is genuinely nothing
    // underneath it. No dismissal anywhere: closing it would strand the player
    // on an empty table with no way back into the cut.
    <div className="flex flex-1 flex-col items-center justify-between gap-4 rounded-lg bg-zinc-900 p-4 text-white">
      {/* OPPONENT(S) -- top, matching the table's seating convention. */}
      <div className="flex justify-center gap-6">
        {opponentIds.map((id) => {
          const card = cardFor(id);
          return (
            <div key={id} className="flex flex-col items-center gap-2">
              <p className="text-sm text-zinc-300">{nameFor(id)}</p>
              {card ? (
                <FlipCard card={card} revealed label={`${nameFor(id)}'s cut card`} />
              ) : (
                <EmptySlot />
              )}
            </div>
          );
        })}
      </div>

      {/* THE DECK. Tapping a card is what performs the draw -- no card exists
          until the server answers this tap. Tapping a position is not fake
          choice: cutting a deck IS choosing a position, and the card is
          whatever happens to be there. */}
      <div className="flex flex-col items-center gap-3">
        {roundNumber > 1 && (
          <p className="text-xs uppercase tracking-wide text-zinc-400">Cut {roundNumber}</p>
        )}
        <div className="flex justify-center px-2">
          {Array.from({ length: FAN_SIZE }).map((_, i) => {
            const interactive = !iHaveDrawn && !drawPending;
            return (
              <button
                key={i}
                type="button"
                disabled={!interactive}
                onClick={() => handleDraw(i)}
                aria-label={`Cut the deck at position ${i + 1}`}
                style={{ marginLeft: i === 0 ? 0 : "-1.15rem" }}
                className={[
                  "h-16 w-8 shrink-0 rounded border border-red-900/60 bg-red-900 transition-transform",
                  interactive ? "cursor-pointer hover:-translate-y-2" : "cursor-default",
                  tappedIndex === i ? "-translate-y-3 ring-2 ring-white" : "",
                ].join(" ")}
              >
                <span
                  className="block h-full w-full rounded"
                  style={{
                    backgroundImage:
                      "repeating-linear-gradient(45deg, rgba(255,255,255,0.16) 0 4px, transparent 4px 8px)",
                  }}
                />
              </button>
            );
          })}
        </div>

        {/* min-h keeps the deck and seats from jumping as the message changes. */}
        <div className="flex min-h-28 flex-col items-center justify-center gap-2 text-center">
          {!iHaveDrawn && (
            <p className="text-lg font-medium">
              {drawPending ? "Cutting..." : "Tap the deck to cut for deal"}
            </p>
          )}

          {iHaveDrawn && !roundComplete && (
            <p className="text-lg text-zinc-300">Waiting for {stillToDraw.join(", ")} to cut...</p>
          )}

          {isTie && (
            <>
              <p className="text-xl font-semibold">
                Tie — both cut {withArticle(rankLabel(myEntry!.card))}
              </p>
              {iHaveAcked ? (
                <p className="text-sm text-zinc-300">
                  Waiting for {stillToAck.join(", ")} to redraw...
                </p>
              ) : (
                <button
                  onClick={handleAcknowledge}
                  disabled={ackPending}
                  className="rounded bg-white px-6 py-2 font-medium text-black disabled:opacity-50"
                >
                  {ackPending ? "Redrawing..." : "Redraw"}
                </button>
              )}
            </>
          )}

          {isDecisive && (
            <>
              <p className="text-xl font-semibold">
                {dealerId === myUserId ? "You deal" : `${nameFor(dealerId!)} deals`}
              </p>
              <p className="text-xs text-zinc-400">Lowest card deals — ace is low.</p>
              {iHaveAcked ? (
                <p className="text-sm text-zinc-300">
                  Waiting for {stillToAck.join(", ")}...
                </p>
              ) : (
                <button
                  onClick={handleAcknowledge}
                  disabled={ackPending}
                  className="rounded bg-white px-6 py-2 font-medium text-black disabled:opacity-50"
                >
                  {ackPending ? "Dealing..." : "Deal cards"}
                </button>
              )}
            </>
          )}

          {error && <p className="text-sm text-red-400">{error}</p>}
        </div>
      </div>

      {/* YOU -- bottom, same convention. */}
      <div className="flex flex-col items-center gap-2">
        {myEntry ? (
          <FlipCard card={myEntry.card} revealed label="your cut card" />
        ) : (
          <EmptySlot />
        )}
        <p className="text-sm text-zinc-300">You</p>
      </div>
    </div>
  );
}
