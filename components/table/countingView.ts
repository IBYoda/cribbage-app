import { scoreHand, type HandScore } from "@/lib/scoring";

// WHAT THE COUNTING PHASE SHOWS, AND WHERE (open hands in the count).
//
// A pure function of the game state, so the table page and the layout mock
// show exactly the same thing. 2-player: the pone (non-dealer) counts first,
// then the dealer's hand, then the crib (count_step 0, 1, 2).
//
//   * Both hands are face-up for the WHOLE count, and nothing clears after a
//     confirm -- they stay until Next Hand. Mine is in my hand row at full
//     hand size; the opponent's is in the middle region, at hand-card size.
//     The opponent's strip shows only their name and the dealer chip.
//   * The crib is a face-down pile in its spot until its count is up (step
//     2), then a face-up fan there, through 'done'.
//   * Every card here is readable by RLS only from counting on
//     (phase2-open-hands-in-count.sql) -- and by then every card of both
//     hands was played face-up in pegging. Anything not readable yet (the
//     policies not applied, or the read still in flight) shows face-down.
//   * A headline says whose count it is. Confirm Count appears only on MY
//     turn; otherwise "X is counting". There is no Show Hand / Show Crib:
//     the dealer's Confirm at step 2 shows the crib itself.
//   * POINTS ONLY AFTER A CONFIRM. Nothing here scores the hand or crib being
//     counted -- players count out loud first. The recap has one line per
//     count already confirmed.
//   * HIDE COUNT NUMBERS (hideNumbers): the recap keeps one line per
//     confirmed count but says only that it was counted ("Your hand
//     counted") -- no points, no breakdown. Nothing else changes.

export type CountingInput = {
  myId: string;
  dealerId: string;
  oppName: string;
  phase: "counting" | "done";
  step: number; // games.count_step
  myHand: string[]; // my four kept cards
  oppCards: string[] | null; // the opponent's hand, if readable
  cribCards: string[] | null; // the crib, if readable
  starter: string | null;
  // The table page's one hideCountNumbers value (the player's Hide counts
  // setting). Optional: absent means numbers shown, as before.
  hideNumbers?: boolean;
};

export type CardSlot =
  | { kind: "none" }
  | { kind: "full"; cards: string[] } // face-up, hand-card size
  | { kind: "faceDown"; count: number }; // not readable (yet)

export type CountingView = {
  myTurn: boolean;
  myRow: CardSlot; // my hand row: always my four, at full size
  myRowCounting: boolean; // my hand is the one being counted
  middle: CardSlot; // the opponent's hand
  middleLabel: string;
  // The crib pile: face-down until its count is up, then the cards.
  cribFan: string[] | null;
  headline: string; // whose count it is
  hint: string;
  waitingOn: string | null; // "X is counting", when it isn't my turn
  canConfirm: boolean;
  recap: string[]; // one small line per count already confirmed
};

// A hand or crib count award, by the reason confirm_count writes ("hand:
// ..." / "crib: ..."). Pegging and his heels are never count awards.
export function isCountReason(reason: string | null | undefined) {
  return !!reason && (reason.startsWith("hand:") || reason.startsWith("crib:"));
}

// "15s 4 · pairs 2 · runs 3", matching the reason confirm_count writes.
export function formatBreakdown(score: HandScore) {
  const parts = [
    score.fifteens > 0 && `15s ${score.fifteens}`,
    score.pairs > 0 && `pairs ${score.pairs}`,
    score.runs > 0 && `runs ${score.runs}`,
    score.flush > 0 && `flush ${score.flush}`,
    score.nobs > 0 && `nobs ${score.nobs}`,
  ].filter(Boolean);
  return parts.length > 0 ? parts.join(" · ") : "nothing";
}

export function countingView(input: CountingInput): CountingView {
  const { myId, dealerId, oppName, phase, step, myHand, oppCards, cribCards, starter, hideNumbers } = input;
  const done = phase === "done";
  const iAmDealer = myId === dealerId;

  // Whose count is up: the pone at step 0, the dealer at steps 1 and 2.
  const myTurn = !done && (step === 0 ? !iAmDealer : iAmDealer);

  // A hand is counted once the step has moved past it.
  const ponesCounted = done || step >= 1;
  const dealersCounted = done || step >= 2;

  // The crib turns face-up when its count is up, and stays up.
  const cribUp = done || step === 2;

  // WHOSE COUNT IT IS.
  let headline: string;
  let hint = "";
  if (done) {
    headline = "Every hand and the crib are counted.";
  } else if (step === 2) {
    headline = iAmDealer ? "Counting: your crib" : `Counting: ${oppName}'s crib`;
  } else {
    headline = myTurn ? "Counting: your hand" : `Counting: ${oppName}'s hand`;
  }
  if (myTurn) {
    hint = "Count it out loud, then Confirm Count.";
  }

  // RECAP: a small line per CONFIRMED count, in counting order -- never the
  // count in progress. With the numbers hidden, just "<label> counted".
  const line = (label: string, cards: string[] | null, isCrib: boolean) => {
    if (hideNumbers) return `${label} counted`;
    if (!cards || cards.length !== 4 || !starter) return null;
    const score = scoreHand(cards, starter, isCrib);
    return `${label}: ${score.points} — ${formatBreakdown(score)}`;
  };
  const oppLabel = `${oppName}'s`;
  const recap = [
    ponesCounted ? line(`${iAmDealer ? oppLabel : "Your"} hand`, iAmDealer ? oppCards : myHand, false) : null,
    dealersCounted ? line(`${iAmDealer ? "Your" : oppLabel} hand`, iAmDealer ? myHand : oppCards, false) : null,
    done ? line(`${iAmDealer ? "Your" : oppLabel} crib`, cribCards, true) : null,
  ].filter((l): l is string => l !== null);

  return {
    myTurn,
    myRow: { kind: "full", cards: myHand },
    myRowCounting: myTurn && step < 2,
    middle: oppCards ? { kind: "full", cards: oppCards } : { kind: "faceDown", count: 4 },
    middleLabel: `${oppName}'s hand`,
    cribFan: cribUp && cribCards ? cribCards : null,
    headline,
    hint,
    waitingOn: done || myTurn ? null : `${oppName} is counting`,
    canConfirm: myTurn,
    recap,
  };
}
