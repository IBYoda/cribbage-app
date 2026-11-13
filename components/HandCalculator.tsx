"use client";

import { useEffect, useRef, useState, type CSSProperties } from "react";
import { PlayingCard } from "@/components/PlayingCard";
import { RANKS, SUITS, rankLabel, suitSymbol } from "@/lib/cards";
import { cardName, comboText, handBreakdown, type BreakdownLine } from "@/lib/handBreakdown";

// THE HAND CALCULATOR (app/calculator): all 52 cards face up; tap four for the
// hand and a fifth for the starter, and the score appears with what makes it
// up. Not a game: nothing is saved or sent anywhere. The scoring is the game's
// own (scoreHand, via lib/handBreakdown.ts).
//
// THE DECK: one fanned row of 13 per suit (clubs, diamonds, spades, hearts; A
// to K) at every width, each card's corner index showing. A card is 11% of the
// row's width and the cards sit every 89/12 = 7.42%, so the strip that shows
// (and takes a tap) is as wide as the row allows. Each card has a fixed slot:
// a chosen card leaves a gap, and the card before it shows in full.
//
// THE HAND: the first four taps, then the starter, set a little apart. Tapping
// one there puts it back; the rest move up in order (the starter becomes the
// fourth hand card). A sixth tap does nothing.
//
// The page is kept short enough that at 375 x 667 the deck, the hand, the
// controls and a typical count fit on one screen. After the fifth tap the page
// scrolls only if the count would end below the screen, and only as far as
// needed.

const CLUBS_FIRST = ["C", "D", "S", "H"] as const satisfies readonly (typeof SUITS)[number][];

// Slot geometry, as a percent of the row's width.
const CARD_WIDTH = 11;
const CARD_STEP = (100 - CARD_WIDTH) / 12;
const ROW_RATIO = 100 / (CARD_WIDTH * 1.4);

export function HandCalculator() {
  const [picked, setPicked] = useState<string[]>([]);
  const [crib, setCrib] = useState(false);
  const countEnd = useRef<HTMLDivElement>(null);

  const chosen = new Set(picked);
  const full = picked.length === 5;

  function pick(card: string) {
    if (picked.length >= 5 || chosen.has(card)) return;
    setPicked([...picked, card]);
  }

  // Once the fifth card's count is on screen: scroll only if it ends below
  // the screen, and then just far enough ("nearest"). Runs after the count
  // is drawn, so it measures the real height. Changing Hand / Crib doesn't
  // scroll.
  const fifth = full ? picked[4] : null;
  useEffect(() => {
    if (!fifth) return;
    const end = countEnd.current;
    if (!end || end.getBoundingClientRect().bottom <= window.innerHeight) return;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    end.scrollIntoView({ block: "nearest", behavior: reduce ? "auto" : "smooth" });
  }, [fifth]);

  function unpick(card: string) {
    setPicked((prev) => prev.filter((c) => c !== card));
  }

  const result = full ? handBreakdown(picked.slice(0, 4), picked[4], crib) : null;

  return (
    <div className="flex flex-col gap-2.5">
      {/* The deck. -mx-[18px] takes all but 2px of the panel's padding, so the
          fan (and each card's strip) is as wide as the screen allows. */}
      <div className="-mx-[18px] flex flex-col gap-px" aria-label="The deck" role="group">
        {CLUBS_FIRST.map((suit) => (
          <div key={suit} className="relative w-full" style={{ aspectRatio: ROW_RATIO }}>
            {RANKS.map((rank, i) => {
              const card = rank + suit;
              return chosen.has(card) ? null : (
                <button
                  key={card}
                  type="button"
                  className="calc-card"
                  style={{ left: `${i * CARD_STEP}%`, width: `${CARD_WIDTH}%`, zIndex: i } as CSSProperties}
                  aria-label={cardName(card)}
                  aria-pressed={false}
                  onClick={() => pick(card)}
                >
                  <PlayingCard card={card} sizing="h-full w-full" />
                </button>
              );
            })}
          </div>
        ))}
      </div>

      <section className="flex flex-col gap-1" aria-labelledby="calc-hand-heading">
        <div className="flex items-center justify-between gap-2">
          <h2
            id="calc-hand-heading"
            className="text-xs font-semibold uppercase tracking-[0.18em] text-[var(--brass-light)]"
          >
            Your hand
          </h2>
          <div className="flex items-center gap-1.5">
            <div role="group" aria-label="Count as" className="flex gap-1">
              <button type="button" aria-pressed={!crib} onClick={() => setCrib(false)} className="calc-toggle">
                Hand
              </button>
              <button type="button" aria-pressed={crib} onClick={() => setCrib(true)} className="calc-toggle">
                Crib
              </button>
            </div>
            <button
              type="button"
              onClick={() => setPicked([])}
              disabled={picked.length === 0}
              className="calc-toggle disabled:opacity-50"
            >
              Reset
            </button>
          </div>
        </div>

        {/* Four hand slots, then the starter a little apart. Empty slots are
            outlines, so the row never jumps as it fills. */}
        <div className="flex items-end gap-2">
          {[0, 1, 2, 3].map((i) => (
            <HandSlot key={i} card={picked[i]} onRemove={unpick} />
          ))}
          <div className="ml-3 flex flex-col items-center gap-0.5">
            <span className="text-[11px] font-semibold uppercase tracking-wide text-[var(--brass-light)]">
              Starter
            </span>
            <HandSlot card={picked[4]} onRemove={unpick} />
          </div>
        </div>

        <div ref={countEnd} role="status" aria-live="polite" className="flex flex-col gap-1 scroll-mb-4">
          {result ? (
            <Result total={result.total} lines={result.lines} crib={crib} starter={picked[4]} />
          ) : (
            <p className="text-sm">
              {picked.length < 4
                ? `Tap 4 cards for your hand (${picked.length} of 4), then the starter.`
                : "Now tap the starter (the cut)."}
            </p>
          )}
        </div>
      </section>
    </div>
  );
}

function HandSlot({ card, onRemove }: { card: string | undefined; onRemove: (card: string) => void }) {
  if (!card) return <span className="calc-slot" aria-hidden="true" />;
  return (
    <button
      type="button"
      className="calc-slot calc-slot--card"
      aria-label={`${cardName(card)}, chosen. Tap to put it back.`}
      aria-pressed={true}
      onClick={() => onRemove(card)}
    >
      <PlayingCard card={card} sizing="h-full w-full" />
    </button>
  );
}

const show = (card: string) => `${rankLabel(card)}${suitSymbol(card)}`;

function Result({
  total,
  lines,
  crib,
  starter,
}: {
  total: number;
  lines: BreakdownLine[];
  crib: boolean;
  starter: string;
}) {
  return (
    <>
      <p className="font-display text-[28px] font-bold leading-8">
        {total === 0 ? "No points" : `${total} ${total === 1 ? "Point" : "Points"}`}
        <span className="sr-only">{crib ? " as a crib" : " as a hand"}</span>
      </p>
      {lines.length > 0 && (
        <ul className="flex flex-col gap-1">
          {lines.map((line) => (
            <li key={line.category} className="flex flex-col">
              <span className="text-[15px] font-semibold leading-5">
                {line.label}: {line.points}
              </span>
              <Pieces line={line} crib={crib} starter={starter} />
            </li>
          ))}
        </ul>
      )}
    </>
  );
}

// The cards behind a line, as the reader would count them: fifteens and pairs
// in one line each; every run on a line of its own, with what it's worth.
function Pieces({ line, crib, starter }: { line: BreakdownLine; crib: boolean; starter: string }) {
  const small = "text-[13px] leading-5 text-[var(--brass-light)]";
  if (line.category === "runs") {
    return (
      <span className={`flex flex-col ${small}`}>
        {line.combos.map((combo) => (
          <span key={combo.join()}>
            {comboText(combo, suitSymbol)} ({combo.length})
          </span>
        ))}
      </span>
    );
  }
  if (line.category === "flush") {
    const cards = line.combos[0];
    const rule =
      cards.length === 5
        ? "all five cards one suit"
        : crib
          ? "" // never: a crib's flush needs all five
          : "the four hand cards one suit";
    return (
      <span className={small}>
        {cards.map(show).join(" ")} ({rule})
      </span>
    );
  }
  if (line.category === "nobs") {
    return (
      <span className={small}>
        {show(line.combos[0][0])}, the same suit as the starter {show(starter)}
      </span>
    );
  }
  return <span className={small}>{line.combos.map((c) => comboText(c, suitSymbol)).join(", ")}</span>;
}
