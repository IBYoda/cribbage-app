// Tests for computerNextAction (lib/computer/next.ts): what the computer
// opponent owes next. Zero dependencies, like the other scripts. Part of
// `npm run test:quick`, and alone:
//
//   npm run test:computer-next
//
// which wraps `node --import ./scripts/ts-resolve.mjs scripts/test-computer-next.ts`.

import { deepStrictEqual, notStrictEqual, ok, strictEqual } from "node:assert";
import { computerNextAction, type NextGame, type NextState } from "../lib/computer/next";

let passed = 0;
function check(name: string, fn: () => void) {
  try {
    fn();
    passed++;
  } catch (e) {
    console.error(`FAIL ${name}`);
    throw e;
  }
}

const H = "human";
const C = "computer";

// An active game in the given phase; override any field.
function game(over: Partial<NextGame> = {}): NextGame {
  return {
    id: "g1",
    status: "active",
    phase: "discard",
    hand_no: 1,
    players: [H, C],
    dealer_id: H,
    current_player: null,
    play_count: 0,
    play_segment: 0,
    count_step: 0,
    discarded_by: [],
    deal_cut: null,
    deal_cut_ack_by: [],
    ready_by: [],
    ...over,
  };
}
function state(over: Partial<NextState> = {}): NextState {
  return { computerId: C, tableFull: true, humanHoldsPegging: false, game: null, finished: null, ...over };
}
const won = (over: Partial<NonNullable<NextState["finished"]>> = {}) => ({
  id: "g0",
  ended_reason: "won",
  players: [H, C],
  ready_by: [] as string[],
  ...over,
});
const kindOf = (s: NextState) => computerNextAction(s)?.kind ?? null;

// ---- Each kind fires in its situation -------------------------------------------
check("draw: cutting, the computer has no card in the round", () => {
  const a = computerNextAction(state({ game: game({ status: "cutting", phase: null, hand_no: null, deal_cut: [[]] }) }));
  deepStrictEqual(a, { kind: "draw", key: "g1:cut:1:draw" });
  // Also when only the human has cut.
  strictEqual(kindOf(state({ game: game({ status: "cutting", deal_cut: [[{ user_id: H, card: "5S" }]] }) })), "draw");
});
check("ack: the round is complete and the computer hasn't acknowledged", () => {
  const round = [{ user_id: H, card: "5S" }, { user_id: C, card: "9D" }];
  deepStrictEqual(computerNextAction(state({ game: game({ status: "cutting", deal_cut: [round] }) })), { kind: "ack", key: "g1:cut:1:ack" });
  // Acknowledged already -> nothing; the human's ack alone doesn't matter.
  strictEqual(kindOf(state({ game: game({ status: "cutting", deal_cut: [round], deal_cut_ack_by: [C] }) })), null);
  strictEqual(kindOf(state({ game: game({ status: "cutting", deal_cut: [round], deal_cut_ack_by: [H] }) })), "ack");
});
check("cut: a tie opens round 2 -> a new draw key", () => {
  const tie = [{ user_id: H, card: "5S" }, { user_id: C, card: "5D" }];
  const a = computerNextAction(state({ game: game({ status: "cutting", deal_cut: [tie, []] }) }));
  deepStrictEqual(a, { kind: "draw", key: "g1:cut:2:draw" });
});
check("cut: the computer has cut but the human hasn't -> nothing", () => {
  strictEqual(kindOf(state({ game: game({ status: "cutting", deal_cut: [[{ user_id: C, card: "5S" }]] }) })), null);
});
check("discard: not yet in discarded_by", () => {
  deepStrictEqual(computerNextAction(state({ game: game() })), { kind: "discard", key: "g1:1:discard" });
  strictEqual(kindOf(state({ game: game({ discarded_by: [H] }) })), "discard");
  strictEqual(kindOf(state({ game: game({ discarded_by: [C] }) })), null);
  strictEqual(kindOf(state({ game: game({ discarded_by: [H, C] }) })), null);
});
check("discard: a level that reads the human's kept hand (Hard) waits for the human's discard", () => {
  // Hard: nothing until the human is in discarded_by, then the discard.
  strictEqual(kindOf(state({ discardAfterOpponent: true, game: game({ discarded_by: [] }) })), null);
  deepStrictEqual(computerNextAction(state({ discardAfterOpponent: true, game: game({ discarded_by: [H] }) })), {
    kind: "discard",
    key: "g1:1:discard",
  });
  strictEqual(kindOf(state({ discardAfterOpponent: true, game: game({ discarded_by: [H, C] }) })), null);
  // Easy and Medium (the flag off or absent): discard straight away, as before.
  strictEqual(kindOf(state({ discardAfterOpponent: false, game: game({ discarded_by: [] }) })), "discard");
  strictEqual(kindOf(state({ game: game({ discarded_by: [] }) })), "discard");
  // The flag only affects the discard.
  strictEqual(kindOf(state({ discardAfterOpponent: true, game: game({ phase: "play", current_player: C }) })), "play");
});
check("play: only on the computer's turn", () => {
  deepStrictEqual(
    computerNextAction(state({ game: game({ phase: "play", current_player: C, play_segment: 1, play_count: 17 }) })),
    { kind: "play", key: "g1:1:play:1:17" }
  );
  strictEqual(kindOf(state({ game: game({ phase: "play", current_player: H }) })), null);
});
check("confirm: the computer's count, the human not on the pegging hold", () => {
  deepStrictEqual(
    computerNextAction(state({ game: game({ phase: "counting", current_player: C, count_step: 0 }) })),
    { kind: "confirm", key: "g1:1:count:0", step: 0, crib: false }
  );
  deepStrictEqual(
    computerNextAction(state({ game: game({ phase: "counting", current_player: C, count_step: 1, dealer_id: C }) })),
    { kind: "confirm", key: "g1:1:count:1", step: 1, crib: false }
  );
});
check("confirm: step 2 is the crib -- a confirm that shows the crib first", () => {
  deepStrictEqual(
    computerNextAction(state({ game: game({ phase: "counting", current_player: C, count_step: 2, dealer_id: C }) })),
    { kind: "confirm", key: "g1:1:count:2", step: 2, crib: true }
  );
});
check("next_hand: done and not yet in ready_by", () => {
  deepStrictEqual(
    computerNextAction(state({ game: game({ phase: "done", hand_no: 3, ready_by: [H] }) })),
    { kind: "next_hand", key: "g1:3:next", handNo: 3 }
  );
  strictEqual(kindOf(state({ game: game({ phase: "done", ready_by: [C] }) })), null);
  strictEqual(kindOf(state({ game: game({ phase: "done", ready_by: [H, C] }) })), null);
});
check("rematch: only after a won game the computer hasn't tapped", () => {
  deepStrictEqual(computerNextAction(state({ finished: won() })), { kind: "rematch", key: "g0:rematch" });
  strictEqual(kindOf(state({ finished: won({ ready_by: [H] }) })), "rematch");
  strictEqual(kindOf(state({ finished: won({ ready_by: [C] }) })), null);
  strictEqual(kindOf(state({ finished: won({ ready_by: [H, C] }) })), null);
  // A won game the computer didn't play in (a changed roster): nothing.
  strictEqual(kindOf(state({ finished: won({ players: [H, "someone"] }) })), null);
});

// ---- Nothing on the human's turn, nothing while they hold pegging ------------------
check("nothing on the human's turn: play and every count step", () => {
  strictEqual(kindOf(state({ game: game({ phase: "play", current_player: H }) })), null);
  for (const step of [0, 1, 2]) {
    strictEqual(kindOf(state({ game: game({ phase: "counting", current_player: H, count_step: step }) })), null);
  }
});
check("nothing in counting while the human holds the pegging view", () => {
  for (const step of [0, 1, 2]) {
    strictEqual(
      kindOf(state({ humanHoldsPegging: true, game: game({ phase: "counting", current_player: C, count_step: step }) })),
      null
    );
  }
  // The hold only affects counting.
  strictEqual(kindOf(state({ humanHoldsPegging: true, game: game({ phase: "done", ready_by: [H] }) })), "next_hand");
});

// ---- Half-updated and missing data ---------------------------------------------------
check("half-updated rows: null or the safe action", () => {
  // phase play, current_player not set yet (discard_to_crib writes the row in steps)
  strictEqual(kindOf(state({ game: game({ phase: "play", current_player: null }) })), null);
  // play with no segment or count
  strictEqual(kindOf(state({ game: game({ phase: "play", current_player: C, play_count: null }) })), null);
  // counting with no step
  strictEqual(kindOf(state({ game: game({ phase: "counting", current_player: C, count_step: null }) })), null);
  // discard with only the human in -> the computer's discard (safe: it owes it)
  strictEqual(kindOf(state({ game: game({ discarded_by: [H] }) })), "discard");
  // discarded_by missing -> nothing
  strictEqual(kindOf(state({ game: game({ discarded_by: null }) })), null);
  // done with ready_by missing -> nothing
  strictEqual(kindOf(state({ game: game({ phase: "done", ready_by: null }) })), null);
  // cutting with no rounds, or a broken round
  strictEqual(kindOf(state({ game: game({ status: "cutting", deal_cut: null }) })), null);
  strictEqual(kindOf(state({ game: game({ status: "cutting", deal_cut: [] }) })), null);
  // active with no hand number, an unknown phase, no players, the computer not a player
  strictEqual(kindOf(state({ game: game({ hand_no: null }) })), null);
  strictEqual(kindOf(state({ game: game({ phase: "shuffling" }) })), null);
  strictEqual(kindOf(state({ game: game({ phase: null }) })), null);
  strictEqual(kindOf(state({ game: game({ players: null }) })), null);
  strictEqual(kindOf(state({ game: game({ players: [H, "someone"] }) })), null);
});
check("no action when the table is not full, or there is no computer id", () => {
  strictEqual(kindOf(state({ tableFull: false, game: game() })), null);
  strictEqual(kindOf(state({ tableFull: false, finished: won() })), null);
  strictEqual(kindOf(state({ computerId: "", game: game() })), null);
});
check("no action for ended games: won (as a live row), admin, player_left, timeout", () => {
  for (const status of ["ended", "won", "finished"]) {
    strictEqual(kindOf(state({ game: game({ status }) })), null);
    strictEqual(kindOf(state({ game: game({ status, phase: "play", current_player: C }) })), null);
  }
  for (const ended_reason of ["admin", "player_left", "timeout", null]) {
    strictEqual(kindOf(state({ finished: won({ ended_reason }) })), null);
  }
  // No game and no result: the human starts the first game.
  strictEqual(kindOf(state()), null);
});

// ---- Keys --------------------------------------------------------------------------
check("keys: the same state gives the same key", () => {
  const s = state({ game: game({ phase: "play", current_player: C, play_segment: 2, play_count: 9 }) });
  strictEqual(computerNextAction(s)?.key, computerNextAction({ ...s })?.key);
});
check("keys: different moments give different keys", () => {
  const keys = [
    computerNextAction(state({ game: game({ status: "cutting", deal_cut: [[]] }) })),
    computerNextAction(state({ game: game({ status: "cutting", deal_cut: [[{ user_id: H, card: "5S" }, { user_id: C, card: "5D" }]] }) })),
    computerNextAction(state({ game: game({ status: "cutting", deal_cut: [[{ user_id: H, card: "5S" }, { user_id: C, card: "5D" }], []] }) })),
    computerNextAction(state({ game: game() })),
    computerNextAction(state({ game: game({ hand_no: 2 }) })),
    computerNextAction(state({ game: game({ id: "g2" }) })),
    computerNextAction(state({ game: game({ phase: "play", current_player: C, play_segment: 0, play_count: 5 }) })),
    computerNextAction(state({ game: game({ phase: "play", current_player: C, play_segment: 0, play_count: 15 }) })),
    computerNextAction(state({ game: game({ phase: "play", current_player: C, play_segment: 1, play_count: 5 }) })),
    computerNextAction(state({ game: game({ phase: "counting", current_player: C, count_step: 0 }) })),
    computerNextAction(state({ game: game({ phase: "counting", current_player: C, count_step: 2 }) })),
    computerNextAction(state({ game: game({ phase: "done" }) })),
    computerNextAction(state({ game: game({ phase: "done", hand_no: 2 }) })),
    computerNextAction(state({ finished: won() })),
    computerNextAction(state({ finished: won({ id: "g9" }) })),
  ].map((a) => a?.key);
  ok(keys.every((k) => typeof k === "string"), `a state gave no action: ${keys}`);
  strictEqual(new Set(keys).size, keys.length, `duplicate keys: ${keys}`);
  notStrictEqual(keys[6], keys[7]);
});
check("pure: the input is not changed", () => {
  const g = game({ phase: "counting", current_player: C, count_step: 2 });
  const s = state({ game: g, finished: null });
  const copy = JSON.parse(JSON.stringify(s));
  computerNextAction(s);
  deepStrictEqual(s, copy);
});

console.log(`All ${passed} computer next-action checks passed.`);
