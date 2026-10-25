// THE COMPUTER OPPONENT'S BRAIN: which two cards to put in the crib, and
// which card to play. Pure functions -- no React, no database, no network --
// with an injectable random source so tests can seed it.
//
// FAIR PLAY BY CONSTRUCTION. The inputs carry only what a player at the table
// knows: their own hand, the starter, the cards played so far, and how many
// cards the opponent still holds. There is NO field for the deck, the
// opponent's discards or the crib, so none can be passed by accident. The one
// exception is opponentRemaining (the human's unplayed cards) in decidePlay:
// it is read ONLY when LEVELS[level].peek is true, and ignored otherwise.
//
// Points here are estimates for choosing a move. The server scores every
// play and count itself (score_pegging, score_hand); nothing from this file
// is ever sent as a score.

import { RANKS, SUITS, cardPlayValue, sortHand } from "../cards";
import { scoreHand, scorePegging } from "../scoring";
import { CRIB_SAMPLES, LEVELS, type ComputerLevel } from "./config";

export type Rng = () => number;

// Every card code, in a fixed order (A-K by suit S, H, D, C).
export const FULL_DECK: readonly string[] = RANKS.flatMap((rank) => SUITS.map((suit) => rank + suit));
const DECK_SET = new Set(FULL_DECK);

// A small seeded generator (mulberry32) for tests and reproducible games:
// returns numbers in [0, 1), like Math.random.
export function seededRng(seed: number): Rng {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function pickIndex(rng: Rng, n: number) {
  return Math.min(n - 1, Math.floor(rng() * n));
}

function assertCards(cards: string[], what: string) {
  const seen = new Set<string>();
  for (const card of cards) {
    if (!DECK_SET.has(card)) throw new Error(`${what}: "${card}" is not a card.`);
    if (seen.has(card)) throw new Error(`${what}: "${card}" appears twice.`);
    seen.add(card);
  }
}

// ---------------------------------------------------------------------------
// LEGAL PLAYS
// ---------------------------------------------------------------------------

// The cards still held (myHand minus playedByMe) whose play value keeps the
// count at 31 or under. In hand order.
export function legalPlays(myHand: string[], playedByMe: string[], count: number): string[] {
  const played = new Set(playedByMe);
  return myHand.filter((card) => !played.has(card) && count + cardPlayValue(card) <= 31);
}

// ---------------------------------------------------------------------------
// THE DISCARD
// ---------------------------------------------------------------------------

export type DiscardInput = {
  hand: string[]; // the six cards dealt
  isDealer: boolean; // the crib is mine (counts for me) or the opponent's
  level: ComputerLevel;
  rng?: Rng;
};

export type DiscardOption = {
  discard: [string, string];
  keep: string[];
  handValue: number; // average score of the kept four over all 46 starters
  cribValue: number; // estimated crib score (my two cards + two unknown)
  value: number; // handValue + cribValue (dealer) or - cribValue (pone)
};

// Every one of the 15 discards with its expected value, best first. The
// crib is estimated by Monte Carlo: CRIB_SAMPLES random (starter, two
// unknown cards) draws from the 46 unseen cards, the SAME draws for every
// discard, scored with the crib rule. Uses rng for the draws only.
export function evaluateDiscards(input: DiscardInput): DiscardOption[] {
  const { hand, isDealer } = input;
  const rng = input.rng ?? Math.random;
  if (!Array.isArray(hand) || hand.length !== 6) {
    throw new Error("decideDiscard needs exactly six cards.");
  }
  assertCards(hand, "decideDiscard");

  const sorted = sortHand(hand);
  const held = new Set(sorted);
  const unseen = FULL_DECK.filter((card) => !held.has(card));

  // The shared crib samples: three distinct unseen cards each.
  const samples: [string, string, string][] = [];
  for (let s = 0; s < CRIB_SAMPLES; s++) {
    const a = pickIndex(rng, unseen.length);
    let b = pickIndex(rng, unseen.length - 1);
    if (b >= a) b += 1;
    let c = pickIndex(rng, unseen.length - 2);
    for (const taken of [a, b].sort((x, y) => x - y)) if (c >= taken) c += 1;
    samples.push([unseen[a], unseen[b], unseen[c]]);
  }

  const options: DiscardOption[] = [];
  for (let i = 0; i < 6; i++) {
    for (let j = i + 1; j < 6; j++) {
      const discard: [string, string] = [sorted[i], sorted[j]];
      const keep = sorted.filter((_, k) => k !== i && k !== j);

      let handTotal = 0;
      for (const starter of unseen) handTotal += scoreHand(keep, starter, false).points;
      const handValue = handTotal / unseen.length;

      let cribTotal = 0;
      for (const [starter, x, y] of samples) {
        cribTotal += scoreHand([discard[0], discard[1], x, y], starter, true).points;
      }
      const cribValue = cribTotal / samples.length;

      options.push({ discard, keep, handValue, cribValue, value: isDealer ? handValue + cribValue : handValue - cribValue });
    }
  }
  // Best first; equal values keep the enumeration order (stable sort).
  return options.sort((p, q) => q.value - p.value);
}

// THE DUMB DISCARD (style "dumb", playing to lose): the WORST discard --
// the lowest-valued of the 15 (evaluateDiscards), so it keeps its worst
// cards and throws its best. When the crib is the opponent's (not the
// dealer) every 5 it holds goes into that crib first: two 5s at random if it
// holds two or more; with one 5, that 5 plus whichever other card gives the
// lowest-valued discard.
function dumbDiscard(hand: string[], isDealer: boolean, rng: Rng): [string, string] {
  if (!Array.isArray(hand) || hand.length !== 6) {
    throw new Error("decideDiscard needs exactly six cards.");
  }
  assertCards(hand, "decideDiscard");
  const fives = hand.filter((card) => card[0] === "5");
  if (!isDealer && fives.length >= 2) {
    const a = pickIndex(rng, fives.length);
    let b = pickIndex(rng, fives.length - 1);
    if (b >= a) b += 1;
    return [fives[a], fives[b]];
  }
  // Best first, so the worst is the last one that qualifies.
  const options = evaluateDiscards({ hand, isDealer, level: "easy", rng });
  if (!isDealer && fives.length === 1) {
    const withFive = options.filter((o) => o.discard.includes(fives[0]));
    return withFive[withFive.length - 1].discard;
  }
  return options[options.length - 1].discard;
}

// The two cards to put in the crib. The best discard, except that with
// probability mistakeRate it picks one of the 15 uniformly at random. The
// "dumb" style (easy) has its own discard (dumbDiscard).
export function decideDiscard(input: DiscardInput): [string, string] {
  const rng = input.rng ?? Math.random;
  if (LEVELS[input.level].style === "dumb") return dumbDiscard(input.hand, input.isDealer, rng);
  const options = evaluateDiscards({ ...input, rng });
  if (rng() < LEVELS[input.level].mistakeRate) {
    return options[pickIndex(rng, options.length)].discard;
  }
  return options[0].discard;
}

// ---------------------------------------------------------------------------
// THE PLAY
// ---------------------------------------------------------------------------

export type PlayInput = {
  myRemaining: string[]; // my cards not yet played
  starter: string;
  segmentCards: string[]; // the current run since the last reset, in order
  count: number; // the running count (the sum of segmentCards)
  allPlayed: string[]; // every card played this hand, by anyone
  opponentCardCount: number; // how many cards the opponent still holds
  level: ComputerLevel;
  rng?: Rng;
  // The opponent's unplayed cards. Read ONLY when LEVELS[level].peek.
  opponentRemaining?: string[];
};

export type PlayOption = {
  card: string;
  points: number; // what this card scores now
  risk: number; // the opponent's expected best reply
  value: number; // points - risk
};

const EPS = 1e-9;

// The opponent's best reply after my card, as points: the exact maximum over
// their legal replies when their cards are known, otherwise the expected
// maximum when they hold n random cards from the unseen ones.
function replyRisk(segment: string[], count: number, opponentCards: string[], n: number, exact: boolean): number {
  // A 31 resets the count: the opponent leads afresh, with nothing to score.
  if (count === 31 || n <= 0) return 0;
  const scores: number[] = [];
  for (const card of opponentCards) {
    if (count + cardPlayValue(card) > 31) {
      scores.push(0);
      continue;
    }
    scores.push(scorePegging([...segment, card]).points);
  }
  if (exact) return scores.length ? Math.max(0, ...scores) : 0;

  // Expected best reply = sum over k >= 1 of P(best >= k), where
  // P(best >= k) = 1 - P(none of the n cards scores k or more), a
  // hypergeometric draw of n from the unseen cards.
  const total = opponentCards.length;
  const draw = Math.min(n, total);
  const top = Math.max(0, ...scores);
  let expected = 0;
  for (let k = 1; k <= top; k++) {
    const good = scores.filter((s) => s >= k).length;
    let pNone = 1;
    for (let i = 0; i < draw; i++) pNone *= (total - good - i) / (total - i);
    expected += 1 - Math.max(0, pNone);
  }
  return expected;
}

// Every legal card with its estimated value, best first. Tie-breaks: not
// leading a 5 (it invites a ten for 15), then playing the higher card so
// the low, flexible ones stay for later, then card order.
export function evaluatePlays(input: PlayInput): PlayOption[] {
  const { myRemaining, starter, segmentCards, count, allPlayed, level } = input;
  assertCards(myRemaining, "decidePlay (myRemaining)");
  assertCards([starter], "decidePlay (starter)");
  assertCards(segmentCards, "decidePlay (segmentCards)");
  assertCards(allPlayed, "decidePlay (allPlayed)");
  const sum = segmentCards.reduce((total, card) => total + cardPlayValue(card), 0);
  if (sum !== count) {
    throw new Error(`decidePlay: count ${count} does not match the segment's cards (${sum}).`);
  }

  const legal = legalPlays(myRemaining, [], count);
  if (legal.length === 0) {
    throw new Error(`decidePlay: no legal card at count ${count} (holding ${myRemaining.join(", ") || "nothing"}).`);
  }

  // peek is decided here, once: without it opponentRemaining is never read.
  const peek = LEVELS[level].peek && Array.isArray(input.opponentRemaining);
  let opponentCards: string[];
  if (peek) {
    opponentCards = input.opponentRemaining as string[];
  } else {
    const known = new Set([...myRemaining, ...allPlayed, starter]);
    opponentCards = FULL_DECK.filter((card) => !known.has(card));
  }
  const n = peek ? opponentCards.length : input.opponentCardCount;

  const options = legal.map((card) => {
    const segment = [...segmentCards, card];
    const points = scorePegging(segment).points;
    const risk = replyRisk(segment, count + cardPlayValue(card), opponentCards, n, peek);
    return { card, points, risk, value: points - risk };
  });

  const leadingFive = (card: string) => segmentCards.length === 0 && card[0] === "5";
  return options.sort((p, q) => {
    if (Math.abs(q.value - p.value) > EPS) return q.value - p.value;
    if (leadingFive(p.card) !== leadingFive(q.card)) return leadingFive(p.card) ? 1 : -1;
    const byValue = cardPlayValue(q.card) - cardPlayValue(p.card);
    if (byValue !== 0) return byValue;
    return FULL_DECK.indexOf(p.card) - FULL_DECK.indexOf(q.card);
  });
}

// THE DUMB PLAY (style "dumb", playing to lose), from the same points and
// reply risk as evaluatePlays: (1) only the legal cards that score the
// LEAST (never a 15, 31, pair or run if a card avoids it); (2) leading a
// run, a 5 if it holds one; (3) otherwise the card that gives the opponent
// the best reply (the highest risk), ties broken at random. The opponent's
// cards are never passed in.
function dumbPlay(input: PlayInput, rng: Rng): string {
  const options = evaluatePlays({ ...input, opponentRemaining: undefined });
  const least = Math.min(...options.map((o) => o.points));
  const pool = options.filter((o) => o.points === least);
  if (input.segmentCards.length === 0) {
    const fives = pool.filter((o) => o.card[0] === "5");
    if (fives.length > 0) return fives[pickIndex(rng, fives.length)].card;
  }
  const most = Math.max(...pool.map((o) => o.risk));
  const top = pool.filter((o) => Math.abs(o.risk - most) <= EPS);
  return top[pickIndex(rng, top.length)].card;
}

// One legal card to play: the best, except that with probability
// mistakeRate it picks a legal card uniformly at random. Throws if there is
// no legal card (the caller should never ask then: the server passes the
// turn on a go).
export function decidePlay(input: PlayInput): string {
  const rng = input.rng ?? Math.random;
  if (LEVELS[input.level].style === "dumb") return dumbPlay(input, rng);
  const options = evaluatePlays(input);
  if (rng() < LEVELS[input.level].mistakeRate) {
    return options[pickIndex(rng, options.length)].card;
  }
  return options[0].card;
}
