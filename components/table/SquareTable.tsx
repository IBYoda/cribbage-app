import type { CSSProperties, ReactNode } from "react";
import { Avatar } from "@/components/Avatar";
import { FaceDownCard, FlipCard, PlayingCard } from "@/components/PlayingCard";
import { surfaceIsDark, type CardBack, type TableSurface } from "@/lib/appearance";
import type { ScreenSide } from "@/lib/tableLayout";

// THE SQUARE TABLE (PRD item 31, docs/mockups/table-redesign/) -- the default
// layout of a 2-player table that isn't Muggins (chooseTableLayout,
// lib/tableLayout.ts; ?layout=classic for the classic one), and of the dev
// mock (app/dev/table-mock). Square-only versions of the shell, the header
// and the across player's seat, so the classic TableShell, TableHeader and
// OpponentBand stay exactly as they are. Sizes are in app/globals.css ("THE SQUARE TABLE").
//
// Rows, top to bottom (2 players, as in mockups 01-03): the header, with the
// across player's avatar and name in its centre; the across player's hand,
// whole card backs overlapped; the middle (played cards, count and pill);
// the pile row (crib, Sort, deck -- only when I deal); my hand; the board
// strip (CribbageBoard); the score plates. No dealer "D" anywhere: the
// dealer is shown only by where the crib and the deck are.

export function SquareTableShell({
  header,
  opponent,
  middle,
  piles,
  hand,
  board,
  scores,
  surface = "green-felt",
  back = "classic",
  dealing = false,
  overlay,
}: {
  header: ReactNode;
  opponent: ReactNode;
  middle: ReactNode;
  piles: ReactNode;
  hand: ReactNode;
  // The board strip (CribbageBoard), full width, --sq-board-h tall. Its
  // space is kept even without one, so nothing above it moves.
  board?: ReactNode;
  scores: ReactNode;
  surface?: TableSurface;
  back?: CardBack;
  // THE DEALING ANIMATION: a deal is on -- the hand-card slots are hidden
  // (.sq-dealing) and `overlay` (DealAnimation) flies the cards in.
  dealing?: boolean;
  overlay?: ReactNode;
}) {
  return (
    <main
      className={`table-shell table-shell--square mx-auto w-full max-w-4xl ${dealing ? "sq-dealing" : ""}`}
      data-surface={surface}
      data-scheme={surfaceIsDark(surface) ? "dark" : undefined}
      data-back={back}
    >
      <div className="min-w-0">{header}</div>
      <div className="sq-opponent-row">{opponent}</div>
      <div className="sq-middle">{middle}</div>
      <div className="min-w-0">{piles}</div>
      <div className="min-w-0">{hand}</div>
      {/* THE BOARD STRIP (PRD item 31, step 1b). */}
      <div className="sq-board" data-sq="board">
        {board}
      </div>
      <div className="min-w-0">{scores}</div>
      {overlay}
    </main>
  );
}

// The header line: table code and hand on the left, the across player
// (avatar, name, "Go") in the centre, the controls on the right.
export function SquareTableHeader({
  code,
  handNo,
  opponent,
  right,
}: {
  code: string;
  handNo: number | null;
  // laneColor: their board lane's colour, as their avatar's ring.
  opponent: { name: string; avatarUrl: string | null; saidGo: boolean; laneColor?: string } | null;
  right: ReactNode;
}) {
  return (
    <header className="sq-header">
      <h1 className="min-w-0 truncate font-semibold">
        Table {code}
        {handNo != null && <span className="font-normal text-zinc-500"> · Hand {handNo}</span>}
      </h1>
      <div className="flex min-w-0 items-center gap-2" data-sq="opp-seat">
        {opponent && (
          <>
            <span data-sq="opp-avatar">
              <Avatar name={opponent.name} url={opponent.avatarUrl} size="sm" tone="table" ringColor={opponent.laneColor} />
            </span>
            <span className="max-w-[9rem] truncate text-sm font-medium" data-sq="opp-name">
              {opponent.name}
            </span>
            {opponent.saidGo && (
              <span className="text-xs font-semibold text-amber-600 dark:text-amber-500 surface:text-amber-200">Go</span>
            )}
          </>
        )}
      </div>
      <div className="flex shrink-0 items-center justify-end gap-3 text-sm">{right}</div>
    </header>
  );
}

// The dealer's piles at the ACROSS seat (mockup 03): from that player's own
// point of view the crib is on the left of their hand and the deck on the
// right -- on my screen, the crib on my right and the deck on my left. The
// caller passes the crib's side from seatGeometry("top").crib; the deck takes
// the other side. Drawn smaller than mine, beside their hand row.
//   cribCards: the crib face-up (its count is up): its four cards fanned in
//   place of the pile, each showing its corner, the last one whole.
export type AcrossPiles = {
  cribCount: number;
  starter: string | null;
  cribSide: ScreenSide;
  cribCards?: string[] | null;
  // The starter has moved to the middle (counting): the deck shows nothing,
  // its place kept for the starter's slide to start from.
  starterMoved?: boolean;
};

// The across player's hand: whole card backs (or the shown cards), overlapped
// by half a card, centred, never cut off. The first card is on top, as in
// the mockups. With piles, the crib and the deck sit either side.
//
// counting: the counting phase -- their four kept cards, spread a little
// wider (two-thirds of each card shows) with the newer card on top, so a
// face-up card's corner always shows. Face-down until `revealed` (their
// hand's count is up), then each card turns over in place (FlipCard); a page
// loaded later shows them face-up at once. cards null: not readable yet,
// face-down.
export function SquareOpponentHand({
  cardCount,
  shownCards,
  piles,
  counting,
}: {
  cardCount: number;
  shownCards?: string[];
  piles?: AcrossPiles | null;
  counting?: { cards: string[] | null; revealed: boolean };
}) {
  const cards: (string | null)[] = shownCards ?? Array.from({ length: cardCount }, () => null);
  return (
    <div
      className={`sq-opp-hand ${counting ? "sq-opp-hand--open" : ""}`}
      style={{ "--n": Math.max(cards.length, 1) } as CSSProperties}
    >
      {counting
        ? cards.map((_, i) => {
            const card = counting.cards?.[i] ?? null;
            return (
              <div key={i} className="sq-opp-card">
                {card ? (
                  <FlipCard
                    card={card}
                    revealed={counting.revealed}
                    label={counting.revealed ? card : "Face-down card"}
                    sizing="w-full aspect-[5/7]"
                  />
                ) : (
                  <FaceDownCard sizing="w-full aspect-[5/7]" />
                )}
              </div>
            );
          })
        : cards.map((card, i) => (
            <div key={card ?? i} className="sq-opp-card" style={{ zIndex: cards.length - i }}>
              {card ? <PlayingCard card={card} sizing="w-full aspect-[5/7]" /> : <FaceDownCard sizing="w-full aspect-[5/7]" />}
            </div>
          ))}
      {piles && (
        <>
          <div
            className={`sq-across-pile sq-across-pile--deck sq-across-pile--${piles.cribSide === "left" ? "right" : "left"}`}
            data-starter-home={piles.starterMoved ? "0" : undefined}
            aria-hidden={piles.starterMoved || undefined}
          >
            {piles.starterMoved ? (
              <div className="aspect-[5/7] w-full" />
            ) : piles.starter ? (
              <PlayingCard card={piles.starter} sizing="w-full aspect-[5/7]" />
            ) : (
              <FaceDownCard sizing="w-full aspect-[5/7]" />
            )}
            {!piles.starterMoved && <SquarePileLabel>{piles.starter ? "Starter" : "Deck"}</SquarePileLabel>}
          </div>
          <div
            className={`sq-across-pile sq-across-pile--crib sq-across-pile--${piles.cribSide === "left" ? "left" : "right"}`}
            aria-label="Crib (the dealer's)"
          >
            {/* As the classic crib pile (PileRow): with cards in it, a pile
                with a hint of depth; empty (nobody has discarded yet), an
                outline where it will go. */}
            {piles.cribCards ? (
              <div className="sq-across-crib-fan">
                {piles.cribCards.map((card) => (
                  <div key={card} className="sq-across-crib-card">
                    <PlayingCard card={card} sizing="w-full aspect-[5/7]" />
                  </div>
                ))}
              </div>
            ) : piles.cribCount > 0 ? (
              <div className="relative">
                <div className="absolute left-0.5 top-0.5 w-full">
                  <FaceDownCard sizing="w-full aspect-[5/7]" />
                </div>
                <div className="relative">
                  <FaceDownCard sizing="w-full aspect-[5/7]" />
                </div>
              </div>
            ) : (
              <div className="aspect-[5/7] w-full rounded-lg border-2 border-dashed border-zinc-300 dark:border-zinc-700" />
            )}
            <SquarePileLabel>Crib</SquarePileLabel>
          </div>
        </>
      )}
    </div>
  );
}

// The same label as the live piles (PileRow's PileLabel): on the pile,
// across its bottom edge.
function SquarePileLabel({ children }: { children: ReactNode }) {
  return (
    <span className="pointer-events-none absolute bottom-0.5 left-1/2 -translate-x-1/2 whitespace-nowrap rounded-full bg-black/70 px-1.5 text-[10px] font-semibold leading-4 text-white">
      {children}
    </span>
  );
}
