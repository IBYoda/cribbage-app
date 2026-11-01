import type { CSSProperties, ReactNode } from "react";
import { Avatar } from "@/components/Avatar";
import { FaceDownCard, FlipCard, PlayingCard } from "@/components/PlayingCard";
import { SeatPlayedCards } from "@/components/table/SeatPlayedCards";
import { seatGeometry, type SeatPosition } from "@/lib/tableLayout";

// THE SQUARE TABLE WITH SIDE SEATS (PRD item 31; mockups 04 and 05): the
// middle of a 3-player table -- and, with the top seat added, a 4-player
// one. 3 players see it by default (chooseTableLayout; ?layout=classic for
// the classic table); the dev mock shows it with &players=3. The rest of the screen is the 2-player square
// table's (SquareTableShell, with no across row): my pile row, my hand, the
// board strip and the plates. Sizes are in app/globals.css ("SIDE SEATS").
//
// Everyone faces the centre. A side seat is a column at the screen's edge:
// the player's avatar (in their lane's colour), name and status at the top
// corner, then their hand as a vertical stack of sideways cards, turned to
// face them (seatGeometry: left 90, right -90 degrees). When they deal, their
// crib and deck sit above and below the stack -- from their own point of
// view the crib on the left of their hand and the deck on the right (left
// seat: crib top, deck bottom; right seat: crib bottom, deck top). Each
// seat's played cards lie in front of it, between its stack and the count;
// mine below the count, as with 2 players. No "D" anywhere.

export type RingPiles = {
  // The crib's cards so far (face-down), or its four face-up once it has
  // been turned over (cribCards).
  cribCount: number;
  cribCards: string[] | null;
  // The cut starter, or null: the face-down deck.
  starter: string | null;
  // The starter has moved to the middle (counting): the deck shows nothing,
  // its place kept for the starter's slide to start from.
  starterMoved?: boolean;
};

export type RingSeat = {
  // Where the seat is on my screen: "left" or "right" (the top seat, for 4
  // players, is a later slice).
  position: SeatPosition;
  userId: string;
  name: string;
  avatarUrl: string | null;
  laneColor?: string;
  // A short word by the name: "Go", "Discarded", "Counting".
  status?: ReactNode;
  // The hand. Face-down backs (count), or -- counting and the final board --
  // the cards themselves (null: not readable yet, face-down), turned over in
  // place when `revealed` comes true (FlipCard); revealed unset: shown
  // face-up as they are.
  hand: { count: number; cards?: (string | null)[] | null; revealed?: boolean };
  // Their crib and deck, when they deal.
  piles: RingPiles | null;
  // Their cards in the run on show (playedBySeat), oldest first.
  played: string[];
};

// One sideways card, in a slot sized for the turned card. home: the slot is
// where the moved starter's slide starts (its turn, in degrees).
function SideCard({ children, home }: { children: ReactNode; home?: number }) {
  return (
    <div className="sq-side__slot" data-starter-home={home}>
      <div className="sq-side__card">{children}</div>
    </div>
  );
}

// A seat's hand, or a face-up crib: sideways cards overlapping in a column,
// in the owner's order from their left to their right (the left seat top to
// bottom, the right seat bottom to top), the newer card on top -- so each
// earlier card shows a strip with its corner index.
function SideStack({ cards, hand = false }: { cards: ReactNode[]; hand?: boolean }) {
  return (
    <div className="sq-side__stack" data-hand-stack={hand ? "" : undefined}>
      {cards.map((card, i) => (
        <SideCard key={i}>{card}</SideCard>
      ))}
    </div>
  );
}

const CARD = "w-full aspect-[5/7]";

function SidePileLabel({ children }: { children: ReactNode }) {
  return (
    <span className="pointer-events-none absolute bottom-0.5 left-1/2 -translate-x-1/2 whitespace-nowrap rounded-full bg-black/70 px-1.5 text-[10px] font-semibold leading-4 text-white">
      {children}
    </span>
  );
}

function SidePile({ kind, piles, turn }: { kind: "crib" | "deck"; piles: RingPiles; turn: number }) {
  if (kind === "deck" && piles.starterMoved) {
    return (
      <div className="sq-side__pile" data-pile="deck" aria-hidden>
        <SideCard home={turn}>{null}</SideCard>
      </div>
    );
  }
  if (kind === "crib" && piles.cribCards) {
    return (
      <div className="sq-side__pile sq-side__pile--fan" data-pile="crib" aria-label="Crib (the dealer's)">
        <SideStack cards={piles.cribCards.map((card) => <PlayingCard key={card} card={card} sizing={CARD} />)} />
      </div>
    );
  }
  return (
    <div className="sq-side__pile" data-pile={kind} aria-label={kind === "crib" ? "Crib (the dealer's)" : undefined}>
      <SideCard>
        {kind === "deck" ? (
          <>
            {piles.starter ? <PlayingCard card={piles.starter} sizing={CARD} /> : <FaceDownCard sizing={CARD} />}
            <SidePileLabel>{piles.starter ? "Starter" : "Deck"}</SidePileLabel>
          </>
        ) : (
          <>
            {/* As the other cribs: a pile with a hint of depth, or an outline
                where it will go while nothing is in it. */}
            {piles.cribCount > 0 ? (
              <div className="relative">
                <div className="absolute left-0.5 top-0.5 w-full">
                  <FaceDownCard sizing={CARD} />
                </div>
                <div className="relative">
                  <FaceDownCard sizing={CARD} />
                </div>
              </div>
            ) : (
              <div className="aspect-[5/7] w-full rounded-lg border-2 border-dashed border-zinc-300 dark:border-zinc-700" />
            )}
            <SidePileLabel>Crib</SidePileLabel>
          </>
        )}
      </SideCard>
    </div>
  );
}

// A side seat's column: the pile slots above and below the stack keep their
// room whoever deals, so both stacks (and the played cards between them)
// line up.
function SideSeatColumn({ seat }: { seat: RingSeat }) {
  const geometry = seatGeometry(seat.position);
  const { hand } = seat;
  const cards: ReactNode[] = Array.from({ length: hand.count }, (_, i) => {
    const card = hand.cards?.[i] ?? null;
    if (!hand.cards || !card) return <FaceDownCard key={i} sizing={CARD} />;
    if (hand.revealed === undefined) return <PlayingCard key={card} card={card} sizing={CARD} />;
    return (
      <FlipCard key={card} card={card} revealed={hand.revealed} label={hand.revealed ? card : "Face-down card"} sizing={CARD} />
    );
  });
  const pileAt = (side: "top" | "bottom") => {
    if (!seat.piles) return null;
    const kind = geometry.crib === side ? "crib" : geometry.deck === side ? "deck" : null;
    return kind ? <SidePile kind={kind} piles={seat.piles} turn={geometry.rotation} /> : null;
  };
  return (
    <div
      className={`sq-side sq-side--${seat.position}`}
      data-seat={seat.position}
      style={{ "--side-turn": `${geometry.rotation}deg` } as CSSProperties}
      aria-label={`${seat.name}'s seat`}
    >
      <div className="sq-side__pile-slot">{pileAt("top")}</div>
      <SideStack cards={cards} hand />
      <div className="sq-side__pile-slot">{pileAt("bottom")}</div>
    </div>
  );
}

// The seat's name tag, in the top corner on its side.
function SeatTag({ seat }: { seat: RingSeat }) {
  return (
    <div className={`sq-ring__tag sq-ring__tag--${seat.position}`} data-sq={`tag-${seat.position}`}>
      <Avatar name={seat.name} url={seat.avatarUrl} size="xs" tone="table" ringColor={seat.laneColor} />
      <span className="min-w-0 truncate text-sm font-medium">{seat.name}</span>
      {seat.status}
    </div>
  );
}

// THE MIDDLE. Rows: the side seats' name tags along the top; then the side
// columns with, between them, the centre -- the played cards in front of
// each side seat either side of `center` (the count and its pill, or the
// counting stage), and `below` under them (the final board's result); then
// my played cards (myPlayed; null in counting: no row).
//   played: show the side seats' played cards (pegging, a pegging win's final
//   board). Off in the discard and counting, so the centre gets the width.
export function SquareRingMiddle({
  seats,
  center,
  below,
  played,
  myPlayed,
  dimmed = false,
  variant,
}: {
  seats: RingSeat[];
  center: ReactNode;
  below?: ReactNode;
  played: boolean;
  myPlayed: string[] | null;
  dimmed?: boolean;
  // "count": counting (no played cards); "final": the final board.
  variant?: "count" | "final";
}) {
  const left = seats.find((s) => s.position === "left") ?? null;
  const right = seats.find((s) => s.position === "right") ?? null;
  const playedOf = (seat: RingSeat | null) =>
    seat ? (
      <SeatPlayedCards
        cards={seat.played}
        rotation={seatGeometry(seat.position).rotation}
        label={`${seat.name}'s played cards`}
        dimmed={dimmed}
        scale={0.89}
      />
    ) : (
      <span />
    );
  return (
    <div className={`sq-ring ${variant ? `sq-ring--${variant}` : ""}`}>
      {left && <SeatTag seat={left} />}
      {right && <SeatTag seat={right} />}
      <div className="sq-ring__seat sq-ring__seat--left">{left && <SideSeatColumn seat={left} />}</div>
      <div className="sq-ring__center">
        <div className="sq-ring__row">
          {played && playedOf(left)}
          <div className="sq-ring__count">{center}</div>
          {played && playedOf(right)}
        </div>
        {below}
      </div>
      <div className="sq-ring__seat sq-ring__seat--right">{right && <SideSeatColumn seat={right} />}</div>
      {myPlayed && (
        <div className="sq-ring__mine">
          <SeatPlayedCards cards={myPlayed} rotation={0} label="Your played cards" dimmed={dimmed} />
        </div>
      )}
    </div>
  );
}

// The little words by a side seat's name.
export function SeatStatus({ kind }: { kind: "go" | "discarded" | "discarding" | "counting" | null }) {
  if (!kind) return null;
  if (kind === "go") {
    return <span className="shrink-0 text-xs font-semibold text-amber-600 dark:text-amber-500 surface:text-amber-200">Go</span>;
  }
  if (kind === "counting") {
    return (
      <span className="shrink-0 text-xs font-semibold text-emerald-600 dark:text-emerald-500 surface:text-violet-200">
        Counting
      </span>
    );
  }
  return kind === "discarded" ? (
    <span className="shrink-0 text-xs font-medium text-emerald-600 dark:text-emerald-500 surface:text-violet-200">Discarded</span>
  ) : (
    <span className="shrink-0 text-xs text-zinc-500">Picking…</span>
  );
}
