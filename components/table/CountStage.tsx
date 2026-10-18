import type { ReactNode } from "react";
import { FaceDownCard, PlayingCard } from "@/components/PlayingCard";
import { HAND_CARD } from "@/components/table/sizes";
import type { CardSlot } from "@/components/table/countingView";

// The middle region during counting and `done`: whose count it is, the
// opponent's hand (hand-card size, using the middle's room) for the whole
// count, Confirm on my turn (or "X is counting"), and a small recap line per
// confirmed count. Sized from the middle region (.count-stage in
// app/globals.css): it never scrolls or clips, and lays out in one row in a
// flat window.
export function CountStage({
  headline,
  hint,
  subject,
  subjectLabel,
  actions,
  recap,
  recapKeys,
  error,
  variant,
}: {
  headline: string;
  hint?: string;
  subject: CardSlot;
  subjectLabel: string | null;
  actions?: ReactNode;
  recap: string[];
  // Phase 3 (3 and 4 players): a key per recap line (by player), so two lines
  // with the same text never share one. Absent: each line is its own key.
  recapKeys?: string[];
  error?: string | null;
  // Phase 3: "n" makes room for up to five recap lines (.count-stage--n).
  variant?: "n";
}) {
  return (
    <div className={variant === "n" ? "count-stage count-stage--n" : "count-stage"}>
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
          {recap.map((line, i) => (
            <span key={recapKeys?.[i] ?? line}>{line}</span>
          ))}
        </div>
      )}

      {error && <p className="text-sm text-red-600">{error}</p>}
    </div>
  );
}

// My hand row's contents in counting: my four, face-up at full size (or
// face-down, if a slot ever holds cards that aren't readable).
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
  return (
    <>
      {slot.cards.map((card) => (
        <PlayingCard key={card} card={card} sizing={HAND_CARD} />
      ))}
    </>
  );
}
