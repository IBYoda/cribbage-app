import { FaceDownCard, PlayingCard } from "@/components/PlayingCard";
import { SMALL_CARD } from "@/components/table/sizes";

export type OpponentSeat = {
  userId: string;
  name: string;
  isDealer: boolean;
  // Face-down cards to draw when the hand isn't shown.
  cardCount: number;
  // The hand, face-up, once it has been shown.
  shownCards?: string[];
  // They said go in the run on the table: an amber "Go" under their name,
  // until the run clears.
  saidGo?: boolean;
};

// The opponents' hands, as close to free as they can be: small overlapping
// cards with only their top part showing, clipped by the band's bottom edge.
// Face-down they cost one thin strip; face-up the corner index (rank over
// suit) is exactly the part that shows, so a shown hand is still readable.
//
// 2-player: one seat, across the top. Phase 3 adds left/right seats as
// sideways stacks at the screen edges; this band then holds only the top
// seat (the partner, in a 4-player team game).
export function OpponentBand({ seats }: { seats: OpponentSeat[] }) {
  if (seats.length === 0) {
    return (
      <p className="flex h-8 items-center justify-center text-xs text-zinc-500">
        Waiting for another player to join...
      </p>
    );
  }

  return (
    <div className="flex h-8 items-start justify-center gap-6 overflow-hidden">
      {seats.map((seat) => (
        <div key={seat.userId} className="flex min-w-0 max-w-full items-start gap-2">
          {/* Cards overlap by 55% -- a stack, not a spread. */}
          <div className="flex">
            {seat.shownCards
              ? seat.shownCards.map((card, i) => (
                  <div key={card} className={i === 0 ? "" : "-ml-[calc(var(--small-w)*0.45)]"}>
                    <PlayingCard card={card} sizing={SMALL_CARD} />
                  </div>
                ))
              : Array.from({ length: seat.cardCount }).map((_, i) => (
                  <div key={i} className={i === 0 ? "" : "-ml-[calc(var(--small-w)*0.7)]"}>
                    <FaceDownCard sizing={SMALL_CARD} />
                  </div>
                ))}
          </div>
          {/* Name tag, with "Go" beneath it -- both inside the strip's 32px,
              so the label costs no height. */}
          <div className="flex min-w-0 flex-col pt-0.5 leading-none">
            <p className="flex items-center gap-1 truncate text-xs font-medium">
              <span className="truncate">{seat.name}</span>
              {seat.isDealer && <DealerChip />}
            </p>
            {seat.saidGo && (
              <span className="mt-0.5 text-xs font-semibold text-amber-600 dark:text-amber-500 surface:text-amber-200">Go</span>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}

// "D" for dealer -- the same chip on the seat and on the score plate.
export function DealerChip() {
  return (
    <span
      className="inline-flex h-4 w-4 shrink-0 items-center justify-center rounded-full bg-amber-500 text-[10px] font-bold text-white"
      title="Dealer"
      aria-label="Dealer"
    >
      D
    </span>
  );
}
