// THE TYPESCRIPT MIRROR of the SQL scoring engines.
//
// These are display-only. The authoritative scorers are score_pegging() and
// score_hand() in the database, called from inside play_card() and (in Batch
// 2) the Confirm Count RPC, which compute AND award inside one locked
// transaction. The client must never supply or influence a point value -- so
// nothing here is ever sent to the server as a score. It exists to show a
// player what a hand is worth without a round trip.
//
// Because there are two implementations of the same rules, they can drift.
// What stops that is scripts/test-scoring.ts, which checks this file
// exhaustively against an independent brute-force scorer and checks the SQL
// against the same expected values.
//
// Deliberately pure and React-free: same reason lib/cards.ts is.

import { cardPlayValue, cardRankValue, rankOf, suitOf } from "./cards";

// ---------------------------------------------------------------------------
// PEGGING
// ---------------------------------------------------------------------------

export type PeggingScore = {
  points: number;
  // Human-readable, e.g. "fifteen + pair". Feeds the score tracker's
  // "+4 - fifteen + pair" flash. Empty string when nothing scored.
  reason: string;
};

// Takes the cards played IN THE CURRENT SEGMENT, in play order, the card just
// played last. Cards from an earlier segment must not be passed in -- in the
// database that filtering is play_card's job (it queries on segment).
//
// Does NOT handle the go / last-card point. That depends on whether the
// segment is closing, which is control flow, not cards; play_card adds it.
export function scorePegging(segmentCards: string[]): PeggingScore {
  const n = segmentCards?.length ?? 0;
  if (n === 0) return { points: 0, reason: "" };

  const reasons: string[] = [];
  let points = 0;

  // The running count is the sum of the segment, by PLAY value.
  const total = segmentCards.reduce((sum, card) => sum + cardPlayValue(card), 0);
  if (total === 15) {
    points += 2;
    reasons.push("fifteen");
  } else if (total === 31) {
    points += 2;
    reasons.push("thirty-one");
  }

  // Pairs: how many cards at the END of the segment share the just-played
  // rank. k equal ranks in a row score k*(k-1): 2, 6, 12.
  const ranks = segmentCards.map(cardRankValue);
  const lastRank = ranks[n - 1];
  let streak = 1;
  for (let i = n - 2; i >= 0 && ranks[i] === lastRank; i--) streak += 1;

  if (streak >= 2) {
    points += streak * (streak - 1);
    reasons.push(
      streak === 2 ? "pair" : streak === 3 ? "pair royal" : "double pair royal"
    );
  }

  // Runs: the LONGEST suffix of length >= 3 whose ranks are all distinct and
  // span exactly (length - 1). Order inside the suffix does not matter, so
  // 5-3-4 is a run -- but the cards must be contiguous at the END, so an
  // intervening card that breaks the sequence breaks the run.
  for (let runLength = n; runLength >= 3; runLength--) {
    const suffix = ranks.slice(n - runLength);
    const distinct = new Set(suffix).size;
    const min = Math.min(...suffix);
    const max = Math.max(...suffix);

    if (distinct === runLength && max - min === runLength - 1) {
      points += runLength;
      reasons.push(`run of ${runLength}`);
      break;
    }
  }

  return { points, reason: reasons.join(" + ") };
}

// ---------------------------------------------------------------------------
// HAND / CRIB
// ---------------------------------------------------------------------------

export type HandScore = {
  points: number;
  fifteens: number;
  pairs: number;
  runs: number;
  flush: number;
  nobs: number;
};

// Four hand cards plus the starter.
//
// isCrib changes exactly one rule, the flush:
//   hand: all four hand cards same suit = 4, and 5 if the starter matches
//   crib: ONLY all five same suit scores, for 5. A four-card crib flush is
//         worth nothing at all.
//
// Does NOT score "his heels" (the starter being a jack). That is the DEALER's
// 2 points, awarded at cut time in discard_to_crib. Counting it here as well
// would double-award it.
export function scoreHand(
  cards: string[],
  starter: string,
  isCrib: boolean
): HandScore {
  if (!cards || cards.length === 0 || !starter) {
    throw new Error("scoreHand needs both a hand and a starter card.");
  }

  const all = [...cards, starter];
  const n = all.length;

  // Hoisted once per card rather than recomputed inside each loop below: the
  // test suite calls this ~26 million times, and the string parsing dominates
  // otherwise.
  const ranks = all.map(cardRankValue);
  const values = all.map(cardPlayValue);

  // Fifteens: every non-empty subset summing to exactly 15, 2 points each.
  // Brute force over bitmasks -- with 5 cards that is 31 subsets.
  let fifteens = 0;
  for (let mask = 1; mask < 1 << n; mask++) {
    let sum = 0;
    for (let bit = 0; bit < n; bit++) {
      if (mask & (1 << bit)) sum += values[bit];
    }
    if (sum === 15) fifteens += 2;
  }

  // Pairs: every unordered same-rank pair, 2 points each. Three of a kind is
  // 3 pairs (6) and four of a kind is 6 pairs (12) -- that falls out of
  // counting combinations instead of needing special cases.
  let pairs = 0;
  for (let i = 0; i < n; i++) {
    for (let j = i + 1; j < n; j++) {
      if (ranks[i] === ranks[j]) pairs += 2;
    }
  }

  // Runs: each maximal block of consecutive ranks present scores
  // (length x product of the counts of its ranks). Double, triple and
  // double-double runs all arise from that one formula.
  const counts = new Array<number>(13).fill(0);
  for (const rank of ranks) counts[rank - 1] += 1;

  let runs = 0;
  let runLength = 0;
  let runMultiplier = 1;
  for (let r = 0; r < 13; r++) {
    if (counts[r] > 0) {
      runLength += 1;
      runMultiplier *= counts[r];
    } else {
      if (runLength >= 3) runs += runLength * runMultiplier;
      runLength = 0;
      runMultiplier = 1;
    }
  }
  // A run ending at the king needs closing out after the loop. Ace is low and
  // runs never wrap, so there is no king-to-ace case.
  if (runLength >= 3) runs += runLength * runMultiplier;

  // Flush.
  let flush = 0;
  const handSuit = suitOf(cards[0]);
  if (cards.every((card) => suitOf(card) === handSuit)) {
    if (suitOf(starter) === handSuit) {
      flush = 5;
    } else if (!isCrib) {
      flush = 4;
    }
  }

  // Nobs: holding the jack matching the starter's suit. Counts only from the
  // hand/crib cards -- the STARTER being a jack is his heels, not nobs, and
  // is scored elsewhere.
  const starterSuit = suitOf(starter);
  const nobs = cards.some(
    (card) => rankOf(card) === "J" && suitOf(card) === starterSuit
  )
    ? 1
    : 0;

  return {
    points: fifteens + pairs + runs + flush + nobs,
    fifteens,
    pairs,
    runs,
    flush,
    nobs,
  };
}
