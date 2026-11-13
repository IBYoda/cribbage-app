// THE HAND CALCULATOR'S BREAKDOWN (app/calculator): what a hand or crib scores,
// category by category, and WHICH CARDS make up each part -- for someone
// learning to count.
//
// One set of rules: every category's POINTS come from scoreHand
// (lib/scoring.ts, the game's own display scorer, checked against the SQL
// scorer). This file only lists the cards behind those points; it never
// decides a score. scripts/test-phase3.ts checks that the listed pieces add
// up to scoreHand's numbers, over known hands and many random ones.
//
// Pure, no React.

import { cardPlayValue, cardRankValue, rankLabel, rankOf, suitOf } from "./cards";
import { scoreHand } from "./scoring";

export type BreakdownCategory = "fifteens" | "pairs" | "runs" | "flush" | "nobs";

export type BreakdownLine = {
  category: BreakdownCategory;
  // One of the five ways a hand scores: "Fifteens", "Pairs", "Runs",
  // "Flush", "Nobs". (No "double run" names: those mean runs and pairs
  // together, which a teaching tool shows as separate lines.)
  label: string;
  points: number;
  // The cards of each scoring piece, low to high: one entry per fifteen, per
  // pair, per run (each run with its actual cards, worth its length).
  combos: string[][];
};

export type HandBreakdown = { total: number; lines: BreakdownLine[] };

const SUIT_NAMES: Record<string, string> = { S: "spades", H: "hearts", D: "diamonds", C: "clubs" };
const RANK_NAMES: Record<string, string> = {
  A: "Ace",
  "2": "Two",
  "3": "Three",
  "4": "Four",
  "5": "Five",
  "6": "Six",
  "7": "Seven",
  "8": "Eight",
  "9": "Nine",
  T: "Ten",
  J: "Jack",
  Q: "Queen",
  K: "King",
};

// "Ace of clubs", for screen readers.
export function cardName(card: string): string {
  return `${RANK_NAMES[rankOf(card)] ?? rankLabel(card)} of ${SUIT_NAMES[suitOf(card)] ?? "?"}`;
}

// Every subset (as index lists) of n items, smallest first.
function subsets(n: number): number[][] {
  const out: number[][] = [];
  for (let mask = 1; mask < 1 << n; mask++) {
    const pick: number[] = [];
    for (let bit = 0; bit < n; bit++) if (mask & (1 << bit)) pick.push(bit);
    out.push(pick);
  }
  return out.sort((a, b) => a.length - b.length);
}

// The breakdown of four cards plus the starter, as a hand (isCrib false) or a
// crib. Lines with no points are left out; a hand of 0 has no lines.
export function handBreakdown(cards: string[], starter: string, isCrib: boolean): HandBreakdown {
  const score = scoreHand(cards, starter, isCrib);
  const all = [...cards, starter];
  const lines: BreakdownLine[] = [];

  // Fifteens: each subset summing to 15 is one 2-point piece.
  if (score.fifteens > 0) {
    const combos = subsets(all.length)
      .filter((pick) => pick.reduce((sum, i) => sum + cardPlayValue(all[i]), 0) === 15)
      // Each piece low to high, as people count it ("5+J", not "J+5").
      .map((pick) => pick.map((i) => all[i]).sort((a, b) => cardRankValue(a) - cardRankValue(b)));
    lines.push({ category: "fifteens", label: "Fifteens", points: score.fifteens, combos });
  }

  // Pairs: each two cards of the same rank is one 2-point piece (three of a
  // kind is three pairs, four of a kind six).
  if (score.pairs > 0) {
    const combos: string[][] = [];
    for (let i = 0; i < all.length; i++) {
      for (let j = i + 1; j < all.length; j++) {
        if (cardRankValue(all[i]) === cardRankValue(all[j])) combos.push([all[i], all[j]]);
      }
    }
    lines.push({ category: "pairs", label: "Pairs", points: score.pairs, combos });
  }

  // Runs: the longest block of consecutive ranks (3 or more), once for every
  // way of picking one card of each of its ranks -- so 3-4-4-5 is two runs of
  // 3 (one with each 4), worth 6. Five cards hold at most one such block.
  if (score.runs > 0) {
    const byRank = new Map<number, string[]>();
    for (const card of all) {
      const rank = cardRankValue(card);
      byRank.set(rank, [...(byRank.get(rank) ?? []), card]);
    }
    let best: number[] = [];
    let block: number[] = [];
    for (let rank = 1; rank <= 14; rank++) {
      if (byRank.has(rank)) block.push(rank);
      else {
        if (block.length >= 3 && block.length > best.length) best = block;
        block = [];
      }
    }
    let combos: string[][] = [[]];
    for (const rank of best) {
      combos = combos.flatMap((combo) => (byRank.get(rank) ?? []).map((card) => [...combo, card]));
    }
    // Shown in rank order, low to high.
    combos = combos.map((combo) => [...combo].sort((a, b) => cardRankValue(a) - cardRankValue(b)));
    lines.push({ category: "runs", label: "Runs", points: score.runs, combos });
  }

  // Flush: the four hand cards (and the starter when it matches; a crib
  // counts only all five).
  if (score.flush > 0) {
    lines.push({ category: "flush", label: "Flush", points: score.flush, combos: [score.flush === 5 ? all : [...cards]] });
  }

  // Nobs: the jack in the hand of the starter's suit.
  if (score.nobs > 0) {
    const jack = cards.find((card) => rankOf(card) === "J" && suitOf(card) === suitOf(starter))!;
    lines.push({ category: "nobs", label: "Nobs", points: score.nobs, combos: [[jack, starter]] });
  }

  return { total: score.points, lines };
}

// "4♥+5♠+6♦": one scoring piece's cards, as the screen shows them.
export function comboText(combo: string[], symbol: (card: string) => string): string {
  return combo.map((card) => `${rankLabel(card)}${symbol(card)}`).join("+");
}
