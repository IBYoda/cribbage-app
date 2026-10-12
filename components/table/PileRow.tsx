import type { ReactNode } from "react";
import { FaceDownCard, PlayingCard } from "@/components/PlayingCard";
import { HAND_CARD } from "@/components/table/sizes";
import { DealerChip } from "@/components/table/OpponentBand";

// The row just above my hand: the crib on the left, the action buttons in the
// middle (Sort, Send to Crib, Show Hand), and the starter on the right. One
// fixed-height row -- both piles are the SAME SIZE AS MY HAND'S CARDS, and
// buttons are 40px tap targets -- so it costs the same space in every phase.
export function PileRow({
  crib,
  starter,
  flash,
  children,
}: {
  crib: CribPileProps | null;
  starter: StarterPileProps | null;
  // The score flash ("Elsa +1 — last card"): above the buttons, between the
  // piles. See .pile-center in app/globals.css.
  flash?: ReactNode;
  children?: ReactNode;
}) {
  return (
    <div className="flex items-end justify-between gap-2">
      <div className="flex min-w-[var(--hand-w)] justify-start">
        {crib && <CribPile {...crib} />}
      </div>
      <div className="pile-center">
        {flash && <div className="pile-flash">{flash}</div>}
        {children}
      </div>
      <div className="flex min-w-[var(--hand-w)] justify-end">
        {starter && <StarterPile {...starter} />}
      </div>
    </div>
  );
}

export type CribPileProps = {
  // Face-down pile until the dealer shows it.
  faceDownCount: number;
  // Once shown: the four cards, fanned in place of the pile.
  shownCards: string[] | null;
};

// A labelled pile, bottom-left, hand-card size. Expands into a fan only when
// shown -- overlapped down to each card's corner (18px, or 36% of a card if
// that's more), so four hand-size cards still leave room for the buttons.
// Labelled just "Crib" with the dealer chip -- the crib is always the
// dealer's, and the chip says whose without a name that long nicknames would
// clip ("oda Again!'s crib").
function CribPile({ faceDownCount, shownCards }: CribPileProps) {
  return (
    <div className="relative" aria-label="Crib (the dealer's)">
      {shownCards ? (
        <div className="flex">
          {shownCards.map((card, i) => (
            <div
              key={card}
              className={i === 0 ? "" : "-ml-[calc(var(--hand-w)_-_max(18px,_var(--hand-w)_*_0.36))]"}
            >
              <PlayingCard card={card} sizing={HAND_CARD} />
            </div>
          ))}
        </div>
      ) : faceDownCount > 0 ? (
        // A pile, not a spread: one card with a hint of depth.
        <div className="relative">
          <div className="absolute left-0.5 top-0.5">
            <FaceDownCard sizing={HAND_CARD} />
          </div>
          <div className="relative">
            <FaceDownCard sizing={HAND_CARD} />
          </div>
        </div>
      ) : (
        // Nothing discarded yet: an outline where the crib will go.
        <div className={`${HAND_CARD} rounded-lg border-2 border-dashed border-zinc-300 dark:border-zinc-700`} />
      )}
      <PileLabel>Crib</PileLabel>
      <span className="absolute -right-1 -top-1">
        <DealerChip />
      </span>
    </div>
  );
}

export type StarterPileProps = {
  // The cut starter, once there is one; until then, the face-down deck.
  card: string | null;
};

function StarterPile({ card }: StarterPileProps) {
  return (
    <div className="relative">
      {card ? <PlayingCard card={card} sizing={HAND_CARD} /> : <FaceDownCard sizing={HAND_CARD} />}
      <PileLabel>{card ? "Starter" : "Deck"}</PileLabel>
    </div>
  );
}

// Labels sit ON the pile, across its bottom edge, so they cost no height. A
// pill that may be wider than the small card rather than truncating inside it.
function PileLabel({ children }: { children: ReactNode }) {
  return (
    <span className="pointer-events-none absolute bottom-0.5 left-1/2 -translate-x-1/2 whitespace-nowrap rounded-full bg-black/70 px-1.5 text-[10px] font-semibold leading-4 text-white">
      {children}
    </span>
  );
}
