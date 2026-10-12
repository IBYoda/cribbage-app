import type { ReactNode } from "react";

// My hand: full-size cards (HAND_CARD), centred, never wrapping. The top
// padding is headroom for a selected card's lift (-translate-y-4 in
// PlayingCard), so selecting a card never grows the row or clips the card.
// The callers render the cards themselves -- the page needs per-card
// select / play / dimmed state that this wrapper shouldn't know about.
//
// `label` sits in that same headroom, centred just above the cards -- my
// "Go" during pegging. Pegging never lifts a card (only the discard does),
// so the two never compete for the space, and the label adds no height.
export function HandRow({ children, label }: { children: ReactNode; label?: ReactNode }) {
  return (
    <div className="relative flex min-h-[calc(var(--hand-w)*1.4+16px)] items-end justify-center gap-[var(--card-gap)] pt-4">
      {label && (
        <div className="pointer-events-none absolute inset-x-0 top-0 flex h-4 items-center justify-center">
          {label}
        </div>
      )}
      {children}
    </div>
  );
}
