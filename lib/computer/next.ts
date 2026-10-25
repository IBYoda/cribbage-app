// WHAT DOES THE COMPUTER OWE NEXT? One pure function: given what the human's
// screen knows about the table, the one action the computer opponent should
// take now -- or null. No React, no network: the driver hook
// (components/table/useComputerDriver.ts) runs it on every state change and
// performs what it returns.
//
// THE KEY names the exact moment, so the driver never sends the same action
// twice for one moment (React runs effects twice in development, and
// realtime events repeat):
//   draw       <game>:cut:<round>:draw
//   ack        <game>:cut:<round>:ack
//   discard    <game>:<hand>:discard
//   play       <game>:<hand>:play:<segment>:<count>
//              (segment and count come from the same games row as
//              current_player, so they always agree with it; within a hand
//              each play moves one of them, so no two moments share a key)
//   confirm    <game>:<hand>:count:<step>
//   next_hand  <game>:<hand>:next
//   rematch    <won game>:rematch

export type ComputerActionKind = "draw" | "ack" | "discard" | "play" | "confirm" | "next_hand" | "rematch";

export type ComputerAction = {
  kind: ComputerActionKind;
  key: string;
  step?: number; // confirm: the count step
  crib?: boolean; // confirm: this step is the crib -- show it first
  handNo?: number; // next_hand: the hand being finished
};

type CutEntry = { user_id: string; card: string };

// The games row fields this needs (the table page's Game has them all).
export type NextGame = {
  id: string;
  status: string;
  phase: string | null;
  hand_no: number | null;
  players: string[] | null;
  dealer_id: string | null;
  current_player: string | null;
  play_count: number | null;
  play_segment: number | null;
  count_step: number | null;
  discarded_by: string[] | null;
  deal_cut: CutEntry[][] | null;
  deal_cut_ack_by: string[] | null;
  ready_by: string[] | null;
};

export type NextState = {
  computerId: string;
  tableFull: boolean; // every seat taken (the human and the computer)
  humanHoldsPegging: boolean; // the human hasn't tapped "Count hands" yet
  game: NextGame | null; // the LIVE game (cutting or active), or none
  // The last game's result when no game is live (the page only keeps a
  // result for a won game; ended_reason is checked anyway).
  finished: { id: string; ended_reason: string | null; players: string[]; ready_by: string[] } | null;
};

export function computerNextAction(state: NextState): ComputerAction | null {
  const { computerId: me, game, finished } = state;
  if (!me || !state.tableFull) return null;

  // No live game: only a rematch after a WON game the computer hasn't tapped.
  // The human starts the first game (and any game after a non-win ending).
  if (!game) {
    if (
      finished &&
      finished.ended_reason === "won" &&
      Array.isArray(finished.players) &&
      finished.players.includes(me) &&
      Array.isArray(finished.ready_by) &&
      !finished.ready_by.includes(me)
    ) {
      return { kind: "rematch", key: `${finished.id}:rematch` };
    }
    return null;
  }

  if (!game.id || !Array.isArray(game.players) || !game.players.includes(me)) return null;

  // THE CUT.
  if (game.status === "cutting") {
    const rounds = game.deal_cut;
    if (!Array.isArray(rounds) || rounds.length === 0) return null;
    const round = rounds[rounds.length - 1];
    if (!Array.isArray(round)) return null;
    const roundNo = rounds.length;
    if (!round.some((entry) => entry?.user_id === me)) {
      return { kind: "draw", key: `${game.id}:cut:${roundNo}:draw` };
    }
    if (round.length === game.players.length && !(game.deal_cut_ack_by ?? []).includes(me)) {
      return { kind: "ack", key: `${game.id}:cut:${roundNo}:ack` };
    }
    return null;
  }

  if (game.status !== "active" || game.hand_no == null) return null;
  const hand = game.hand_no;

  switch (game.phase) {
    case "discard":
      if (!Array.isArray(game.discarded_by)) return null;
      if (game.discarded_by.includes(me)) return null;
      return { kind: "discard", key: `${game.id}:${hand}:discard` };

    case "play":
      if (game.current_player !== me) return null;
      if (game.play_segment == null || game.play_count == null) return null;
      return { kind: "play", key: `${game.id}:${hand}:play:${game.play_segment}:${game.play_count}` };

    case "counting": {
      if (game.current_player !== me || state.humanHoldsPegging) return null;
      const step = game.count_step;
      if (step == null) return null;
      // The crib is counted at step N (N players), after every hand.
      const crib = step === game.players.length;
      return { kind: "confirm", key: `${game.id}:${hand}:count:${step}`, step, crib };
    }

    case "done":
      if (!Array.isArray(game.ready_by) || game.ready_by.includes(me)) return null;
      return { kind: "next_hand", key: `${game.id}:${hand}:next`, handNo: hand };

    default:
      return null;
  }
}
