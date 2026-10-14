import type { CSSProperties } from "react";
import { PlayingCard } from "@/components/PlayingCard";

// The landing page's artwork: the perfect 29. Three fives and the jack of
// spades in hand, the five of spades cut as the starter -- the jack matching
// the starter's suit is "his nobs". Real PlayingCards, fanned like a hand:
// they overlap and turn about a point below their base, and deal in one by
// one (.hero-card in app/globals.css; no animation with reduced motion).
const HAND = [
  { card: "5H", turn: -14, drop: 10 },
  { card: "5D", turn: -5, drop: 2 },
  { card: "5C", turn: 5, drop: 2 },
  { card: "JS", turn: 14, drop: 10 },
];

export function HeroHand() {
  return (
    <div
      className="hero-hand"
      role="img"
      aria-label="A 29 hand: the five of hearts, five of diamonds, five of clubs and jack of spades, with the five of spades cut as the starter"
    >
      <div className="hero-hand__fan" aria-hidden="true">
        {HAND.map((h, i) => (
          <div
            key={h.card}
            className="hero-card"
            style={
              {
                "--turn": `${h.turn}deg`,
                "--drop": `${h.drop}px`,
                "--deal-delay": `${i * 90}ms`,
              } as CSSProperties
            }
          >
            <PlayingCard card={h.card} sizing="w-full aspect-[5/7] shadow-lg" />
          </div>
        ))}
      </div>
      {/* The starter: no visible label (the description above names it).
          Dropped like the fan's inner cards, so its bottom edge sits level
          with theirs. */}
      <div
        className="hero-card"
        aria-hidden="true"
        style={{ "--drop": "2px", "--deal-delay": "480ms" } as CSSProperties}
      >
        <PlayingCard card="5S" sizing="w-full aspect-[5/7] shadow-lg" />
      </div>
    </div>
  );
}
