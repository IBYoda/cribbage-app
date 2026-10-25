// THE PEGGING RULES, as the server plays them (play_card_as, 2 players) --
// one pure helper shared by the Hard search (brain.ts) and the simulator
// (scripts/sim-computer.ts), so the two can never disagree.
//
// After player p plays a card (the server's order, docs/sql/phase3-e3-pegging.sql):
//   1. The card joins the current segment and is scored (score_pegging:
//      15 or 31 for 2, pairs, runs).
//   2. Exactly 31: the count resets. No go point -- the 2 for 31 replaces it.
//   3. Otherwise the turn goes to the other player if they can legally play
//      at the new count; else p keeps playing if p can (the other said go);
//      else nobody can: the count resets and p gets the go point.
//   4. After a reset, the first player after p who still holds a card leads
//      (the other player, else p). If nobody holds a card the pegging is
//      over -- and a go point on that last play is the "last card" point.
//   5. All of p's points from that one play are awarded together.
// The player whose turn it is always has a legal card (the server never
// leaves a player on turn who must say go), so there is no explicit go move.

import { cardPlayValue } from "../cards";
import { scorePegging } from "../scoring";

export type Seat = 0 | 1;

export type PegState = {
  hands: [string[], string[]]; // each player's unplayed cards
  segment: string[]; // the current run since the last reset, in order
  count: number;
  turn: Seat; // whose turn (always holds a legal card)
};

export type PlayResult = {
  points: number; // all of the mover's points for this play (incl. go / last card)
  next: PegState | null; // null: the pegging is over
};

export function legalCards(hand: string[], count: number): string[] {
  return hand.filter((card) => count + cardPlayValue(card) <= 31);
}

export function applyPlay(state: PegState, card: string): PlayResult {
  const p = state.turn;
  const o: Seat = p === 0 ? 1 : 0;
  if (!state.hands[p].includes(card)) throw new Error(`applyPlay: ${card} is not in the player's hand.`);
  const count = state.count + cardPlayValue(card);
  if (count > 31) throw new Error(`applyPlay: ${card} takes the count to ${count}.`);

  const hands: [string[], string[]] = [state.hands[0], state.hands[1]];
  hands[p] = hands[p].filter((c) => c !== card);
  const segment = [...state.segment, card];
  let points = scorePegging(segment).points;

  let reset = false;
  let next: Seat = o;
  if (count === 31) {
    reset = true;
  } else if (legalCards(hands[o], count).length > 0) {
    next = o;
  } else if (legalCards(hands[p], count).length > 0) {
    next = p;
  } else {
    reset = true;
    points += 1; // the go point -- the "last card" point if nothing follows
  }

  if (reset) {
    if (hands[o].length > 0) next = o;
    else if (hands[p].length > 0) next = p;
    else return { points, next: null };
    return { points, next: { hands, segment: [], count: 0, turn: next } };
  }
  return { points, next: { hands, segment, count, turn: next } };
}
