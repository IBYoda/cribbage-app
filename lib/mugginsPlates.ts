// THE SELF-SCORING PLATES (3 and 4 players): on a Self-Scoring (Muggins)
// table of 3 or 4 the plates ARE the win controls -- there is no score to
// show. Pure: what each plate says and does, from the games row
// (win_claim_by, win_confirmed_by, winner_id). Drawn by
// components/table/MugginsPlates.tsx; tested by scripts/test-phase3.ts.
// 2-player Self-Scoring keeps its win bar (MugginsWinBar) and never comes
// here.
//
// MY PLATE is my button:
//   * nobody has claimed: "I win" (claim_win);
//   * I claimed: "Waiting… (tap to cancel)" (clear_win_claim);
//   * someone else claimed: "Confirm loss" (confirm_win), then, once I have,
//     "✓ Confirmed" (nothing to tap);
//   * the match is over: "Won" if I won it, else just my name.
// EVERY OTHER PLATE is their name, plus:
//   * the claimant's: "Claims the win";
//   * a player (not the claimant) who has confirmed: a tick;
//   * the match is over: "Won" on the winner's.
// The match ends on the last confirmation (confirm_win), which clears the
// claim and the confirmations -- so a final board has a winner and nothing
// else.

export type MugginsPlateKind =
  // Mine.
  | "i-win"
  | "waiting"
  | "confirm-loss"
  | "confirmed-mine"
  | "won-mine"
  | "over-mine"
  // Everyone else's.
  | "idle"
  | "claims"
  | "confirmed"
  | "won"
  | "over";

export type MugginsPlateAction = "claim" | "cancel" | "confirm";

export type MugginsPlateState = {
  userId: string;
  name: string;
  mine: boolean;
  kind: MugginsPlateKind;
  // The plate's words besides the name (mine: the button's words), or null.
  label: string | null;
  // What tapping my plate does; null: nothing (other plates are never
  // buttons).
  action: MugginsPlateAction | null;
  // A tick after the name: they have confirmed someone else's claim.
  tick: boolean;
};

export function mugginsPlateStates(input: {
  // The plates, in the order they're drawn (me first, then clockwise).
  order: { userId: string; name: string }[];
  myId: string;
  claimBy: string | null;
  // games.win_confirmed_by. Undefined or null on a row read before the
  // column existed (a stale row): nobody has confirmed.
  confirmedBy?: readonly string[] | null;
  // The final board: who won the match. Null while it is live.
  winnerId?: string | null;
}): MugginsPlateState[] {
  const { order, myId, claimBy } = input;
  const confirmed = new Set(input.confirmedBy ?? []);
  const winnerId = input.winnerId ?? null;

  return order.map(({ userId, name }): MugginsPlateState => {
    const mine = userId === myId;
    const plate = (kind: MugginsPlateKind, label: string | null, action: MugginsPlateAction | null = null, tick = false) => ({
      userId,
      name,
      mine,
      kind,
      label,
      action,
      tick,
    });

    if (winnerId) {
      if (mine) return userId === winnerId ? plate("won-mine", "Won") : plate("over-mine", null);
      return userId === winnerId ? plate("won", "Won") : plate("over", null);
    }

    if (mine) {
      if (!claimBy) return plate("i-win", "I win", "claim");
      if (claimBy === myId) return plate("waiting", "Waiting… (tap to cancel)", "cancel");
      return confirmed.has(myId) ? plate("confirmed-mine", "✓ Confirmed") : plate("confirm-loss", "Confirm loss", "confirm");
    }

    if (claimBy === userId) return plate("claims", "Claims the win");
    if (claimBy && confirmed.has(userId)) return plate("confirmed", null, null, true);
    return plate("idle", null);
  });
}
