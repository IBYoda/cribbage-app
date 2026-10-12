import { scoreHand, type HandScore } from "@/lib/scoring";

// WHAT THE COUNTING PHASE SHOWS, AND WHERE (UI polish, stage 3).
//
// A pure function of the game state, so the table page and the layout mock
// show exactly the same thing. 2-player: the pone (non-dealer) counts first,
// then the dealer's hand, then the crib (count_step 0, 1, 2).
//
//   * Only the hand being counted is shown at full size. Mine is in my hand
//     row; the opponent's is in the middle region, at hand-card size.
//   * A hand clears from the table once its count is confirmed.
//   * The crib appears in the DEALER'S slot: my hand row if I deal, the
//     middle if the opponent does. The crib pile at bottom-left becomes an
//     empty outline while its cards are out, and stays so once counted.
//   * A hand that's still waiting for its count (mine while the pone counts)
//     stays visible, collapsed to small cards.
//   * Show Hand / Show Crib / Confirm Count appear only on MY turn; otherwise
//     a plain "X is counting".

export type CountingInput = {
  myId: string;
  dealerId: string;
  oppName: string;
  phase: "counting" | "done";
  step: number; // games.count_step
  myHand: string[]; // my four kept cards
  oppCards: string[] | null; // the opponent's hand, if it has been shown
  cribCards: string[] | null; // the crib, if it has been shown
  starter: string | null;
  iHaveShown: boolean;
  cribRevealed: boolean;
};

export type CardSlot =
  | { kind: "none" }
  | { kind: "collapsed"; cards: string[] } // waiting its turn: small cards
  | { kind: "full"; cards: string[] } // being counted, face-up
  | { kind: "faceDown"; count: number }; // being counted, not shown yet

export type CountingView = {
  myTurn: boolean;
  myRow: CardSlot; // what my hand row holds
  middle: CardSlot; // the opponent's hand or crib being counted, if any
  middleLabel: string | null;
  oppBandCount: number; // face-down cards left in the opponent's strip
  cribPile: "pile" | "outline";
  headline: string;
  hint: string;
  showHandButton: boolean;
  showCribButton: boolean;
  canConfirm: boolean;
  recap: string[]; // one small line per count already confirmed
};

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
  const { myId, dealerId, oppName, phase, step, myHand, oppCards, cribCards, starter } = input;
  const done = phase === "done";
  const iAmDealer = myId === dealerId;

  // Whose count is up: the pone at step 0, the dealer at steps 1 and 2.
  const myTurn = !done && (step === 0 ? !iAmDealer : iAmDealer);

  // A hand is counted once the step has moved past it.
  const ponesCounted = done || step >= 1;
  const dealersCounted = done || step >= 2;
  const myHandCounted = iAmDealer ? dealersCounted : ponesCounted;

  // MY ROW.
  let myRow: CardSlot = { kind: "none" };
  if (!done && step === 2 && iAmDealer) {
    // The crib, in my slot. Face-down until I show it.
    myRow =
      input.cribRevealed && cribCards
        ? { kind: "full", cards: cribCards }
        : { kind: "faceDown", count: 4 };
  } else if (myTurn) {
    myRow = { kind: "full", cards: myHand };
  } else if (!myHandCounted) {
    myRow = { kind: "collapsed", cards: myHand };
  }

  // THE MIDDLE: the opponent's hand or crib, while they count it.
  let middle: CardSlot = { kind: "none" };
  let middleLabel: string | null = null;
  if (!done && !myTurn) {
    if (step === 2) {
      middle =
        input.cribRevealed && cribCards
          ? { kind: "full", cards: cribCards }
          : { kind: "faceDown", count: 4 };
      middleLabel = `${oppName}'s crib`;
    } else {
      middle = oppCards ? { kind: "full", cards: oppCards } : { kind: "faceDown", count: 4 };
      middleLabel = `${oppName}'s hand`;
    }
  }

  // THE OPPONENT'S STRIP keeps their hand only while it still waits to be
  // counted -- i.e. they deal and I (the pone) am counting first.
  const oppBandCount = !done && step === 0 && !iAmDealer ? 4 : 0;

  // HEADLINE.
  let headline: string;
  let hint = "";
  if (done) {
    headline = "Every hand and the crib are counted.";
  } else if (myTurn && step < 2) {
    headline = "Your count";
    hint = "Count your hand out loud, then Confirm Count.";
  } else if (myTurn) {
    headline = "Your crib";
    hint = input.cribRevealed
      ? "Count the crib out loud, then Confirm Count."
      : "Show the crib, count it out loud, then Confirm Count.";
  } else {
    headline = step === 2 ? `${oppName} is counting the crib` : `${oppName} is counting`;
  }

  // RECAP: a small line per confirmed count, in counting order.
  const line = (label: string, cards: string[] | null, isCrib: boolean) => {
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
    myRow,
    middle,
    middleLabel,
    oppBandCount,
    cribPile: done || step === 2 ? "outline" : "pile",
    headline,
    hint,
    showHandButton: myTurn && step < 2 && !input.iHaveShown,
    showCribButton: myTurn && step === 2 && !input.cribRevealed,
    canConfirm: myTurn && (step < 2 || input.cribRevealed),
    recap,
  };
}
