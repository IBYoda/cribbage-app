import type { ReactNode } from "react";
import { FaceDownCard, PlayingCard } from "@/components/PlayingCard";
import { HAND_CARD, SMALL_CARD } from "@/components/table/sizes";
import type { CardSlot } from "@/components/table/countingView";

// The middle region during counting and `done` (UI polish, stage 3): the
// status line, the opponent's hand or crib while they count it (hand-card
// size, using the middle's room), my buttons on my turn, and a small recap
// line per confirmed count. Sized from the middle region (.count-stage in
// app/globals.css): it never scrolls or clips, and lays out in one row in a
// flat window.
export function CountStage({
  headline,
  hint,
  subject,
  subjectLabel,
  actions,
  recap,
  error,
}: {
  headline: string;
  hint?: string;
  subject: CardSlot;
  subjectLabel: string | null;
  actions?: ReactNode;
  recap: string[];
  error?: string | null;
}) {
  return (
    <div className="count-stage">
      <div className="count-stage__text">
        <p className="text-sm font-medium">{headline}</p>
        {hint && <p className="text-xs text-zinc-500">{hint}</p>}
      </div>

      {subject.kind !== "none" && (
        <div className="count-stage__subject" aria-label={subjectLabel ?? undefined}>
          {subject.kind === "faceDown"
            ? Array.from({ length: subject.count }).map((_, i) => (
                <div key={i} className="count-stage__card">
                  <FaceDownCard sizing="w-full aspect-[5/7]" />
                </div>
              ))
            : subject.cards.map((card) => (
                <div key={card} className="count-stage__card">
                  <PlayingCard card={card} sizing="w-full aspect-[5/7]" />
                </div>
              ))}
        </div>
      )}

      {actions && <div className="count-stage__actions">{actions}</div>}

      {recap.length > 0 && (
        <div className="count-stage__recap text-zinc-500">
          {recap.map((line) => (
            <span key={line}>{line}</span>
          ))}
        </div>
      )}

      {error && <p className="text-sm text-red-600">{error}</p>}
    </div>
  );
}

// My hand row's contents in counting: full-size cards (being counted), small
// overlapping cards (still waiting their turn), or face-down cards (the crib
// before it's shown).
export function SlotCards({ slot }: { slot: CardSlot }) {
  if (slot.kind === "none") return null;
  if (slot.kind === "faceDown") {
    return (
      <>
        {Array.from({ length: slot.count }).map((_, i) => (
          <FaceDownCard key={i} sizing={HAND_CARD} />
        ))}
      </>
    );
  }
  if (slot.kind === "collapsed") {
    // Overlapped down to the corners: readable, but plainly not the hand
    // being counted.
    return (
      <div className="flex" aria-label="Your hand (counted later)">
        {slot.cards.map((card, i) => (
          <div
            key={card}
            className={i === 0 ? "" : "-ml-[calc(var(--small-w)_-_max(18px,_var(--small-w)_*_0.36))]"}
          >
            <PlayingCard card={card} sizing={SMALL_CARD} />
          </div>
        ))}
      </div>
    );
  }
  return (
    <>
      {slot.cards.map((card) => (
        <PlayingCard key={card} card={card} sizing={HAND_CARD} />
      ))}
    </>
  );
}
