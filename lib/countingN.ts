import { scoreHand } from "@/lib/scoring";
import { formatBreakdown, type CardSlot } from "@/components/table/countingView";

// WHAT THE COUNTING PHASE SHOWS, AND WHERE -- for 3 and 4 players (Phase 3,
// stage A5a). The 2-player count is countingView (components/table/
// countingView.ts), unchanged; this is its N-player twin, a pure function of
// the game state, checked by scripts/test-phase3.ts.
//
// THE ORDER (the server's confirm_count, docs/sql/phase3-e4-counting.sql):
// clockwise from the dealer's left. Step k (0 .. N-1) is the hand of the
// (k+1)-th player clockwise from the dealer, so the dealer's own hand is step
// N-1; step N is the crib, which the dealer counts; 'done' comes after.
// Whose count it is follows from count_step and the dealer's place in the
// game's players (seat order) -- the same rule the server holds
// current_player to (its Guard 7).
//
// WHAT MOVES WHERE, as with 2 players:
//   * The hand being counted by someone else moves to the middle, labelled
//     "<name>'s hand"; that player's seat keeps no cards meanwhile.
//   * My own hand stays in my hand row, marked "Counting" on my turn.
//   * Every other hand is face-up on its seat for the whole count (every
//     hand is readable from counting on -- each card was played face-up).
//   * The crib: a face-down pile until its step, N. At step N it is the
//     middle ("Your crib" / "<dealer>'s crib") and its pile is an empty
//     slot; once everything is counted ('done') it is fanned in the pile
//     row, as with 2 players.
//   * POINTS ONLY AFTER A CONFIRM: one recap line per count already
//     confirmed, in counting order -- N hands, then the crib -- with the
//     numbers hidden ("<label> counted") when hideNumbers is on.

export type CountingInputN = {
  players: string[]; // games.players, seat order (clockwise)
  myId: string;
  dealerId: string;
  names: Record<string, string>; // display names by player id
  phase: "counting" | "done";
  step: number; // games.count_step
  myHand: string[]; // my four kept cards
  hands: Record<string, string[] | null>; // the others' hands, if readable
  cribCards: string[] | null; // the crib, if readable
  starter: string | null;
  hideNumbers?: boolean;
};

export type RecapLine = { key: string; text: string };

export type CountingViewN = {
  counterId: string | null; // whose count is up (the dealer at the crib); null when done
  isCribStep: boolean;
  myTurn: boolean;
  myRow: CardSlot;
  myRowCounting: boolean; // my hand is the one being counted
  middle: CardSlot; // the hand (or crib) being counted, unless it is mine
  middleLabel: string | null;
  cribFan: string[] | null; // the crib fanned in the pile row ('done')
  // The crib pile in the pile row: face-down while the hands are counted,
  // an EMPTY slot while the crib itself is in the middle (step N), fanned
  // once everything is counted.
  cribPile: "faceDown" | "empty" | "fan";
  headline: string;
  hint: string;
  waitingOn: string | null; // "<name> is counting", when it isn't my turn
  canConfirm: boolean;
  recap: RecapLine[]; // one per count already confirmed, keyed by whose
  // Every other player's seat: their hand face-up (null = not readable yet,
  // drawn face-down), or nothing while it is in the middle.
  seatCards: Record<string, { shown: string[] | null; count: number }>;
};

// The counting order: the players clockwise from the dealer's left, the
// dealer last. order[k] is whose hand step k counts.
export function countingOrder(players: string[], dealerId: string): string[] {
  const n = players.length;
  const d = players.indexOf(dealerId);
  if (d < 0) return [...players];
  return Array.from({ length: n }, (_, k) => players[(d + 1 + k) % n]);
}

export function countingViewN(input: CountingInputN): CountingViewN {
  const { players, myId, dealerId, names, phase, step, myHand, hands, cribCards, starter, hideNumbers } = input;
  const n = players.length;
  const done = phase === "done";
  const order = countingOrder(players, dealerId);
  const name = (id: string) => names[id] ?? "A player";
  const iAmDealer = myId === dealerId;

  const isCribStep = !done && step >= n;
  const counterId = done ? null : isCribStep ? dealerId : (order[step] ?? null);
  const myTurn = counterId === myId;

  // WHOSE COUNT IT IS.
  let headline: string;
  if (done) headline = "Every hand and the crib are counted.";
  else if (isCribStep) headline = iAmDealer ? "Counting: your crib" : `Counting: ${name(dealerId)}'s crib`;
  else headline = myTurn ? "Counting: your hand" : `Counting: ${name(counterId!)}'s hand`;
  const hint = myTurn ? "Count it out loud, then Confirm Count." : "";

  // THE MIDDLE: the hand being counted, unless it's mine (that one is in my
  // row); the crib at its step.
  let middle: CardSlot = { kind: "none" };
  let middleLabel: string | null = null;
  if (isCribStep) {
    middle = cribCards ? { kind: "full", cards: cribCards } : { kind: "faceDown", count: 4 };
    middleLabel = iAmDealer ? "Your crib" : `${name(dealerId)}'s crib`;
  } else if (counterId && counterId !== myId) {
    const cards = hands[counterId] ?? null;
    middle = cards ? { kind: "full", cards } : { kind: "faceDown", count: 4 };
    middleLabel = `${name(counterId)}'s hand`;
  }

  // THE SEATS: everyone else's hand face-up, except the one in the middle.
  const seatCards: CountingViewN["seatCards"] = {};
  for (const id of players) {
    if (id === myId) continue;
    const inMiddle = !done && !isCribStep && id === counterId;
    seatCards[id] = inMiddle ? { shown: null, count: 0 } : { shown: hands[id] ?? null, count: 4 };
  }

  // RECAP: a line per CONFIRMED count, in counting order -- never the count
  // in progress. With the numbers hidden, just "<label> counted".
  const line = (key: string, label: string, cards: string[] | null, isCrib: boolean): RecapLine | null => {
    if (hideNumbers) return { key, text: `${label} counted` };
    if (!cards || cards.length !== 4 || !starter) return null;
    const score = scoreHand(cards, starter, isCrib);
    return { key, text: `${label}: ${score.points} — ${formatBreakdown(score)}` };
  };
  const counted = done ? n : Math.min(step, n);
  const recap: RecapLine[] = [];
  for (let k = 0; k < counted; k++) {
    const id = order[k];
    const l = line(`hand-${id}`, id === myId ? "Your hand" : `${name(id)}'s hand`, id === myId ? myHand : (hands[id] ?? null), false);
    if (l) recap.push(l);
  }
  if (done) {
    const l = line("crib", iAmDealer ? "Your crib" : `${name(dealerId)}'s crib`, cribCards, true);
    if (l) recap.push(l);
  }

  return {
    counterId,
    isCribStep,
    myTurn,
    myRow: { kind: "full", cards: myHand },
    myRowCounting: myTurn && !isCribStep,
    middle,
    middleLabel,
    cribFan: done && cribCards ? cribCards : null,
    cribPile: done ? "fan" : isCribStep ? "empty" : "faceDown",
    headline,
    hint,
    waitingOn: done || myTurn ? null : `${name(counterId!)} is counting`,
    canConfirm: myTurn,
    recap,
    seatCards,
  };
}
