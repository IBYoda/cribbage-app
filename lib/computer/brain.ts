// THE COMPUTER OPPONENT'S BRAIN: which two cards to put in the crib, and
// which card to play. Pure functions -- no React, no database, no network --
// with an injectable random source so tests can seed it.
//
// FAIR PLAY BY CONSTRUCTION. The inputs carry only what a player at the table
// knows: their own hand, the starter, the cards played so far, and how many
// cards the opponent still holds. There is NO field for the deck, the
// opponent's discards or the crib, so none can be passed by accident. The one
// exceptions are the human's cards, each read only for a level that allows
// it: opponentRemaining (their unplayed cards) in decidePlay, read ONLY when
// LEVELS[level].peek -- Medium and Hard; and opponentKept (their kept
// four-card hand, once they have discarded) in decideDiscard, read ONLY when
// LEVELS[level].peekDiscard -- Hard only, which therefore discards after the
// human (lib/computer/next.ts). Otherwise both are ignored.
//
// MEDIUM'S PEGGING (peek without search): the best card one move ahead --
// its points now minus the human's best reply, from their actual cards.
//
// THE PEGGING SEARCH (LEVELS[level].search, so Hard only): with the
// opponent's exact unplayed cards known, evaluatePlays searches every line
// to the end of the pegging (minimax, both sides playing their best, under
// the server's rules in rules.ts) and values each card as my points minus
// the opponent's from here to the last card. Without search, or without
// those cards, it uses the one-move-ahead branch below, unchanged.
//
// HARD'S DISCARD (peekDiscard): with the human's kept hand known, each of
// the 15 keeps also gets its EXACT pegging value against that hand (the
// same search, the pone leading), and the starters and crib samples come
// from the 42 cards neither hand holds.
//
// PLAYING TO WIN (search only): when the input carries the game state
// (the public scores and dealer, plus both kept hands) and either player
// could reach 121 by the end of this deal's count, the same search plays for
// the WIN: a line that pegs a player out ends the game for that player, and
// a line whose count is CERTAIN to finish the game (the pone's hand, then
// the dealer's hand; never the crib, which is partly unknown) is a win or a
// loss; every other line still counts as the points difference. Wins rank
// above any points and sooner wins above later ones; losses the reverse.
// The scores are public; everything about the opponent's cards is still
// read only when the level allows it (peek; peekDiscard at the discard).
//
// Points here are estimates for choosing a move. The server scores every
// play and count itself (score_pegging, score_hand); nothing from this file
// is ever sent as a score.

import { RANKS, SUITS, cardPlayValue, sortHand } from "../cards";
import { scoreHand, scorePegging } from "../scoring";
import { LEVELS, type ComputerLevel } from "./config";
import { applyPlay, legalCards, type PegState, type Seat } from "./rules";

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
  // How many crib samples to draw; undefined = the level's cribSamples.
  // (For measuring -- the simulator pits counts against each other.)
  cribSamples?: number;
  // The opponent's kept four-card hand (they have discarded already). Read
  // ONLY when LEVELS[level].peekDiscard, and only if it is four real,
  // distinct cards, none of them mine; otherwise ignored.
  opponentKept?: string[];
};

export type DiscardOption = {
  discard: [string, string];
  keep: string[];
  handValue: number; // average score of the kept four over the possible starters
  cribValue: number; // estimated crib score (my two cards + two unknown)
  // With the opponent's kept hand known: the exact pegging result (my points
  // minus theirs, both playing their best, the pone leading); 0 otherwise.
  peggingValue: number;
  value: number; // handValue + cribValue (dealer) or - cribValue (pone), + peggingValue
};

// Every one of the 15 discards with its expected value, best first. The
// crib is estimated by Monte Carlo: the level's cribSamples (or the input's
// override) random (starter, two unknown cards) draws from the unseen cards
// (46; 42 when the opponent's kept hand is known), the SAME draws for every
// discard, scored with the crib rule. Uses rng for the draws only. With the
// opponent's kept hand (peekDiscard only), each keep also gets its exact
// pegging value against that hand.
export function evaluateDiscards(input: DiscardInput): DiscardOption[] {
  const { hand, isDealer } = input;
  const rng = input.rng ?? Math.random;
  if (!Array.isArray(hand) || hand.length !== 6) {
    throw new Error("decideDiscard needs exactly six cards.");
  }
  assertCards(hand, "decideDiscard");

  const sorted = sortHand(hand);
  const held = new Set(sorted);
  // The opponent's kept hand: read only for a level that peeks at discard.
  const theirs =
    LEVELS[input.level].peekDiscard && validKeptHand(input.opponentKept, held) ? (input.opponentKept as string[]) : null;
  const theirSet = new Set(theirs ?? []);
  const unseen = FULL_DECK.filter((card) => !held.has(card) && !theirSet.has(card));
  const memo = new Map<string, number>();
  // The pone leads the pegging: the opponent when I deal.
  const peggingOf = (keep: string[]) => {
    if (!theirs) return 0;
    const state: PegState = { hands: [[...keep], [...theirs]], segment: [], count: 0, turn: isDealer ? 1 : 0 };
    const v = bestDifference(state, memo);
    return state.turn === 0 ? v : -v;
  };

  // The shared crib samples: three distinct unseen cards each.
  const samples: [string, string, string][] = [];
  const sampleCount = input.cribSamples ?? LEVELS[input.level].cribSamples;
  for (let s = 0; s < sampleCount; s++) {
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
      const peggingValue = peggingOf(keep);

      options.push({
        discard,
        keep,
        handValue,
        cribValue,
        peggingValue,
        value: (isDealer ? handValue + cribValue : handValue - cribValue) + peggingValue,
      });
    }
  }
  // Best first; equal values keep the enumeration order (stable sort).
  return options.sort((p, q) => q.value - p.value);
}

// The opponent's kept hand is usable at discard if it is four real,
// distinct cards and none of them is in my six.
function validKeptHand(cards: string[] | undefined, mine: Set<string>) {
  if (!Array.isArray(cards) || cards.length !== 4) return false;
  if (new Set(cards).size !== 4) return false;
  return cards.every((card) => DECK_SET.has(card) && !mine.has(card));
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
  // THE GAME STATE, for playing to win near 121. Read ONLY when
  // LEVELS[level].peek (and only with opponentRemaining). The scores and
  // the dealer are public; the kept four-card hands (each player's whole
  // hand this deal: the remaining cards plus the ones already played) are
  // used for the count after the pegging.
  game?: {
    myScore: number;
    opponentScore: number;
    iAmDealer: boolean;
    myKept?: string[];
    opponentKept?: string[];
  };
};

export type PlayOption = {
  card: string;
  points: number; // what this card scores now
  risk: number; // the opponent's expected best reply (searched: points - value)
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

// THE SEARCH'S PIECES. The opponent's cards are usable for the search only
// if they are real, unrepeated cards that are none of mine, none already
// played and not the starter.
function validOpponentCards(cards: string[], mine: string[], allPlayed: string[], starter: string) {
  const seen = new Set([...mine, ...allPlayed, starter]);
  for (const card of cards) {
    if (!DECK_SET.has(card) || seen.has(card)) return false;
    seen.add(card);
  }
  return cards.length <= 4;
}

// The best (my points - the opponent's points) to the end of the pegging
// for the player whose turn it is in state, both sides playing their best.
// Memoised on the position (whose turn, the segment, both hands).
function bestDifference(state: PegState, memo: Map<string, number>): number {
  const key = `${state.turn}|${state.segment.join(",")}|${[...state.hands[0]].sort().join(",")}|${[...state.hands[1]].sort().join(",")}`;
  const known = memo.get(key);
  if (known !== undefined) return known;
  let best = -Infinity;
  for (const card of legalCards(state.hands[state.turn], state.count)) {
    const { points, next } = applyPlay(state, card);
    const rest = next === null ? 0 : next.turn === state.turn ? bestDifference(next, memo) : -bestDifference(next, memo);
    best = Math.max(best, points + rest);
  }
  // Unreachable (the player on turn always holds a legal card), but safe.
  if (best === -Infinity) best = 0;
  memo.set(key, best);
  return best;
}

// PLAYING TO WIN: the value scale. A win is worth WIN minus STEP for every
// play (or count) it takes, so any win outranks any points difference and a
// sooner win outranks a later one; a loss is the negative, so a later loss
// outranks a sooner one. |value| >= DECIDED means the line is decided.
const WIN = 100000;
const STEP = 100;
const DECIDED = WIN / 2;
// Either player this close to 121 (pegging plus a hand can be worth this
// much in one deal): play to win. Further away no line can end the game, so
// the points-difference search is used, unchanged.
const ENDGAME_REACH = 61;

type Endgame = {
  dealer: Seat; // seat 0 is me, seat 1 the opponent
  handPoints: [number, number] | null; // each kept hand's count, if both are known
};

// The count after the pegging, where it is CERTAIN: the pone counts first,
// then the dealer's hand. The crib (partly unknown) never decides.
function countResult(scores: [number, number], eg: Endgame): { winner: Seat; steps: number } | null {
  if (!eg.handPoints) return null;
  const pone: Seat = eg.dealer === 0 ? 1 : 0;
  if (scores[pone] + eg.handPoints[pone] >= 121) return { winner: pone, steps: 1 };
  if (scores[eg.dealer] + eg.handPoints[eg.dealer] >= 121) return { winner: eg.dealer, steps: 2 };
  return null;
}

// The value of one play for the player making it, in a game to 121.
function playToWinMove(
  state: PegState,
  card: string,
  scores: [number, number],
  depth: number,
  eg: Endgame,
  memo: Map<string, number>
): { points: number; value: number } {
  const p = state.turn;
  const { points, next } = applyPlay(state, card);
  const after: [number, number] = [scores[0], scores[1]];
  after[p] += points;
  if (after[p] >= 121) return { points, value: WIN - STEP * (depth + 1) }; // pegged out
  if (next === null) {
    const result = countResult(after, eg);
    if (!result) return { points, value: points };
    const size = WIN - STEP * (depth + 1 + result.steps);
    return { points, value: result.winner === p ? size : -size };
  }
  const child = bestToWin(next, after, depth + 1, eg, memo);
  const rest = next.turn === p ? child : -child;
  return { points, value: Math.abs(rest) >= DECIDED ? rest : points + rest };
}

// The best value for the player whose turn it is, in a game to 121.
// Memoised on the position and the running scores.
function bestToWin(state: PegState, scores: [number, number], depth: number, eg: Endgame, memo: Map<string, number>): number {
  const key = `${state.turn}|${scores[0]},${scores[1]}|${state.segment.join(",")}|${[...state.hands[0]].sort().join(",")}|${[...state.hands[1]].sort().join(",")}`;
  const known = memo.get(key);
  if (known !== undefined) return known;
  let best = -Infinity;
  for (const card of legalCards(state.hands[state.turn], state.count)) {
    best = Math.max(best, playToWinMove(state, card, scores, depth, eg, memo).value);
  }
  if (best === -Infinity) best = 0; // unreachable, as above
  memo.set(key, best);
  return best;
}

// The kept four-card hands, if they are usable for the count: four real,
// unrepeated cards each, holding that player's remaining cards, the rest of
// each among the cards played, no card in both, and not the starter.
function keptHandsValid(
  myKept: string[] | undefined,
  oppKept: string[] | undefined,
  myRemaining: string[],
  oppRemaining: string[],
  allPlayed: string[],
  starter: string
) {
  if (!Array.isArray(myKept) || !Array.isArray(oppKept) || myKept.length !== 4 || oppKept.length !== 4) return false;
  const all = [...myKept, ...oppKept];
  if (new Set(all).size !== 8 || all.some((c) => !DECK_SET.has(c) || c === starter)) return false;
  const played = new Set(allPlayed);
  const fits = (kept: string[], remaining: string[]) =>
    remaining.every((c) => kept.includes(c)) && kept.every((c) => remaining.includes(c) || played.has(c));
  return fits(myKept, myRemaining) && fits(oppKept, oppRemaining);
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

  let options: PlayOption[];
  if (peek && LEVELS[level].search && validOpponentCards(opponentCards, myRemaining, allPlayed, starter)) {
    // THE SEARCH (peek only): every line to the end of the pegging. points
    // is this play's own points (a go or last-card point included); value
    // is my points minus the opponent's from here to the end; risk is
    // points - value, what the rest of the hand costs me (negative when the
    // rest of the hand gains).
    const root: PegState = { hands: [[...myRemaining], [...opponentCards]], segment: [...segmentCards], count, turn: 0 };
    const memo = new Map<string, number>();
    // PLAYING TO WIN, when the game state is given and 121 is within reach
    // of either player; otherwise the points difference, as before.
    const g = input.game;
    const toWin =
      g !== undefined &&
      Number.isFinite(g.myScore) &&
      Number.isFinite(g.opponentScore) &&
      Math.max(g.myScore, g.opponentScore) + ENDGAME_REACH >= 121;
    if (toWin && g) {
      const handsKnown = keptHandsValid(g.myKept, g.opponentKept, myRemaining, opponentCards, allPlayed, starter);
      const eg: Endgame = {
        dealer: g.iAmDealer ? 0 : 1,
        handPoints: handsKnown
          ? [
              scoreHand(g.myKept as string[], starter, false).points,
              scoreHand(g.opponentKept as string[], starter, false).points,
            ]
          : null,
      };
      const scores: [number, number] = [g.myScore, g.opponentScore];
      options = legal.map((card) => {
        const { points, value } = playToWinMove(root, card, scores, 0, eg, memo);
        return { card, points, risk: points - value, value };
      });
    } else {
      options = legal.map((card) => {
        const { points, next } = applyPlay(root, card);
        const rest = next === null ? 0 : next.turn === 0 ? bestDifference(next, memo) : -bestDifference(next, memo);
        const value = points + rest;
        return { card, points, risk: points - value, value };
      });
    }
  } else {
    options = legal.map((card) => {
      const segment = [...segmentCards, card];
      const points = scorePegging(segment).points;
      const risk = replyRisk(segment, count + cardPlayValue(card), opponentCards, n, peek);
      return { card, points, risk, value: points - risk };
    });
  }

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
