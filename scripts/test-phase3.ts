// Tests for the Phase 3 helpers in lib/phase3.ts. Zero dependencies, like
// scripts/test-scoring.ts:
//
//   npm run test:phase3
//
// which wraps `node --import ./scripts/ts-resolve.mjs scripts/test-phase3.ts`.
//
// The 2-player cases are the point: each one is checked against what the
// table screen did before Phase 3 (written out here as the reference), so a
// 2-player table can't change through these helpers.

import { deepStrictEqual, strictEqual } from "node:assert";
import { displayedRun, goSayers, type PlayEvent } from "../lib/pegging";
import { countingOrder, countingViewN } from "../lib/countingN";
import { countingView } from "../components/table/countingView";
import {
  buildPlates,
  cardsLeft,
  cribCountDuringDiscard,
  handSizes,
  nextSeat,
  winHeadline,
  seatOrderFrom,
  seatPlaces,
  teamOfPosition,
  type PlateRow,
} from "../lib/phase3";
import {
  chooseTableLayout,
  isSquareTable,
  playedBySeat,
  seatGeometry,
  countingReveals,
  countingStarterPlace,
  laneForPlayer,
  ringLayout,
  seatPositionOf,
  seatsOnScreen,
  type TableScreen,
} from "../lib/tableLayout";
import {
  boardGeometry,
  boardHoles,
  clampScore,
  holePosition,
  holeSpot,
  laneOf,
  nextPegs,
  PEG_MIN_R,
} from "../lib/boardLayout";
import {
  BOARD_SKIN_LIST,
  BOARD_SETTING_KEY,
  CLASSIC_WOOD,
  HOLE_CONTRAST_MIN,
  LANE_DISTANCE_MIN,
  PEG_CONTRAST_MIN,
  bannerTextColor,
  boardSkinById,
  contrastRatio,
  holeContrast,
  holeContrastExempt,
  isHexColor,
  laneRingColor,
  laneSeparation,
  pegContrast,
  pegContrastExempt,
  readBoardSkinId,
  writeBoardSkinId,
} from "../lib/boardSkins";
import {
  DEAL_CARD_MS,
  DEAL_CARD_MS_FOUR,
  dealCardMsFor,
  DEAL_TOTAL_MS,
  FAN_TOTAL_MS,
  TOSS_CARD_MS,
  TOSS_STAGGER_MS,
  dealLength,
  dealPlan,
  flightTurn,
  discardPlan,
  liveDealStep,
  liveDiscardStep,
  liveStarterStep,
  markDiscardSeen,
  COMPUTER_DISCARD_SHOW_MS,
  discardShowStep,
  discardShown,
  discardShowKey,
  fireDiscardShow,
  shownCribIds,
  type DiscardSeen,
  type DiscardShow,
} from "../lib/dealAnimation";

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

// ---- Hand sizes -------------------------------------------------------------
check("2 players: 6 dealt, 2 discarded, 4 kept (the old constants)", () => {
  deepStrictEqual(handSizes(2), { dealt: 6, discard: 2, kept: 4 });
});
check("3 and 4 players: 5 dealt, 1 discarded, 4 kept", () => {
  deepStrictEqual(handSizes(3), { dealt: 5, discard: 1, kept: 4 });
  deepStrictEqual(handSizes(4), { dealt: 5, discard: 1, kept: 4 });
});
check("crib during the discard: 2 players = discards x 2 (the old formula)", () => {
  for (let d = 0; d <= 2; d++) strictEqual(cribCountDuringDiscard(2, d), d * 2);
});
check("crib during the discard: 3 players start with the deck card", () => {
  deepStrictEqual([0, 1, 2, 3].map((d) => cribCountDuringDiscard(3, d)), [1, 2, 3, 4]);
});
check("crib during the discard: 4 players", () => {
  deepStrictEqual([0, 1, 2, 3, 4].map((d) => cribCountDuringDiscard(4, d)), [0, 1, 2, 3, 4]);
});

// ---- Seats --------------------------------------------------------------------
const P4 = ["s1", "s2", "s3", "s4"];
check("seat order starts with me and goes clockwise", () => {
  deepStrictEqual(seatOrderFrom(P4, "s1"), ["s1", "s2", "s3", "s4"]);
  deepStrictEqual(seatOrderFrom(P4, "s3"), ["s3", "s4", "s1", "s2"]);
  deepStrictEqual(seatOrderFrom(P4, "nobody"), P4);
});
check("2 players: the other player across the top", () => {
  deepStrictEqual(seatPlaces(["a", "b"], "a"), { left: null, top: "b", right: null });
  deepStrictEqual(seatPlaces(["a", "b"], "b"), { left: null, top: "a", right: null });
});
check("3 players: next clockwise on my left, the other on my right", () => {
  deepStrictEqual(seatPlaces(["a", "b", "c"], "a"), { left: "b", top: null, right: "c" });
  deepStrictEqual(seatPlaces(["a", "b", "c"], "c"), { left: "a", top: null, right: "b" });
});
check("4 players: left, top (partner), right", () => {
  deepStrictEqual(seatPlaces(P4, "s1"), { left: "s2", top: "s3", right: "s4" });
  deepStrictEqual(seatPlaces(P4, "s2"), { left: "s3", top: "s4", right: "s1" });
});
check("teams by position: 1 and 3 against 2 and 4", () => {
  deepStrictEqual(P4.map((id) => teamOfPosition(P4, id)), [1, 2, 1, 2]);
  strictEqual(teamOfPosition(P4, "x"), null);
  // My partner always sits across the top.
  for (const me of P4) strictEqual(teamOfPosition(P4, seatPlaces(P4, me).top!), teamOfPosition(P4, me));
});

// ---- Plates -------------------------------------------------------------------
const row = (id: string, name: string, score: number, last: [number, string, string] | null = null): PlateRow => ({
  user_id: id,
  name,
  avatar_url: id === "a" ? "https://example.test/a.png" : null,
  score,
  last_points: last ? last[0] : null,
  last_reason: last ? last[1] : null,
  last_awarded_at: last ? last[2] : null,
});

// THE REFERENCE: the plates the table page built before Phase 3, verbatim
// apart from displayName (the rows carry the name already).
function oldPlates(list: PlateRow[], myId: string, handDealerId: string | null) {
  return list.map((m) => ({
    key: m.user_id,
    members: [{ userId: m.user_id, name: m.name, avatarUrl: m.avatar_url }],
    score: m.score,
    isMine: m.user_id === myId,
    hasDealer: handDealerId === m.user_id,
    lastPoints: m.last_points,
    lastReason: m.last_reason,
    lastAwardedAt: m.last_awarded_at,
  }));
}

check("2 players: plates equal the old list, every dealer and award case", () => {
  const cases: PlateRow[][] = [
    [row("a", "Walt", 0), row("b", "Elsa", 0)],
    [row("a", "Walt", 40, [2, "pair", "2026-01-01T00:00:01Z"]), row("b", "Elsa", 38, [1, "go", "2026-01-01T00:00:00Z"])],
    [row("a", "Walt", 121, [6, "hand: 15s 4", "2026-01-01T00:00:02Z"]), row("b", "Elsa", 90)],
    [row("a", "Walt", 5)], // alone
  ];
  for (const list of cases) {
    for (const dealer of ["a", "b", null]) {
      deepStrictEqual(buildPlates({ rows: list, myId: "a", dealerId: dealer, teamsPlayers: null }), oldPlates(list, "a", dealer));
    }
  }
});
check("3 players and 4 Solo: one plate per player, in the order given", () => {
  const list = [row("a", "Walt", 3), row("b", "Elsa", 7), row("c", "Sam", 1), row("d", "Kim", 0)];
  const plates = buildPlates({ rows: list, myId: "a", dealerId: "c", teamsPlayers: null });
  deepStrictEqual(plates.map((p) => p.key), ["a", "b", "c", "d"]);
  deepStrictEqual(plates.map((p) => p.hasDealer), [false, false, true, false]);
  strictEqual(plates.every((p) => p.flashName === undefined), true);
});
check("Teams: one plate per team, my team first, shared total, scorer named", () => {
  // Seats: a(1) b(2) c(3) d(4): a+c against b+d. I am b.
  const players = ["a", "b", "c", "d"];
  const list = [
    row("b", "Elsa", 19, [11, "hand: runs 3", "2026-01-01T00:00:01Z"]),
    row("c", "Sam", 17, [6, "hand: pairs 2", "2026-01-01T00:00:03Z"]),
    row("d", "Kim", 19, [5, "crib: flush 5", "2026-01-01T00:00:04Z"]),
    row("a", "Walt", 17, [11, "hand: 15s 8", "2026-01-01T00:00:02Z"]),
  ];
  const plates = buildPlates({ rows: list, myId: "b", dealerId: "d", teamsPlayers: players });
  deepStrictEqual(plates.map((p) => p.key), ["team-2", "team-1"]);
  deepStrictEqual(plates[0].members.map((m) => m.name), ["Elsa", "Kim"]); // me first
  deepStrictEqual(plates[1].members.map((m) => m.name), ["Sam", "Walt"]);
  deepStrictEqual(plates.map((p) => p.score), [19, 17]);
  deepStrictEqual(plates.map((p) => p.isMine), [true, false]);
  deepStrictEqual(plates.map((p) => p.hasDealer), [true, false]); // d deals: my team's chip
  // The newest award on each team is the scorer's, and the flash names them.
  deepStrictEqual(plates.map((p) => [p.lastPoints, p.lastReason, p.flashName]), [
    [5, "crib: flush 5", "Kim"],
    [6, "hand: pairs 2", "Sam"],
  ]);
});
check("Teams: no award yet -- no flash name; a lagging partner row can't lower the total", () => {
  const players = ["a", "b", "c", "d"];
  const plates = buildPlates({
    rows: [row("a", "Walt", 12), row("b", "Elsa", 0), row("c", "Sam", 10), row("d", "Kim", 0)],
    myId: "a",
    dealerId: null,
    teamsPlayers: players,
  });
  deepStrictEqual(plates.map((p) => [p.key, p.score, p.flashName, p.hasDealer]), [
    ["team-1", 12, undefined, false],
    ["team-2", 0, undefined, false],
  ]);
});

// ---- Pegging (A4): cards held, the run on the table, who said Go ---------------
// A 3-player hand, players a (dealer's left), b, c, as play_card writes it
// (E3): a go row for each player passed over who still holds cards.
let seq = 0;
const play = (segment: number, user: string, card: string, count: number): PlayEvent => ({
  seq: ++seq, segment, user_id: user, kind: "play", card, count_after: count,
});
const go = (segment: number, user: string, count: number): PlayEvent => ({
  seq: ++seq, segment, user_id: user, kind: "go", card: null, count_after: count,
});
const run3: PlayEvent[] = [
  play(0, "a", "KS", 10), play(0, "b", "QS", 20), play(0, "c", "9S", 29),
  go(0, "a", 29), go(0, "b", 29), // a and b can't play at 29; c plays on
  play(0, "c", "2S", 31), // 31: the count resets, segment 1
];

check("cards held: kept minus plays, go rows don't count, never below 0", () => {
  deepStrictEqual(["a", "b", "c", "d"].map((id) => cardsLeft(4, run3, id)), [3, 3, 2, 4]);
  strictEqual(cardsLeft(4, [play(0, "a", "1", 1), play(0, "a", "2", 2), play(0, "a", "3", 3), play(0, "a", "4", 4), play(0, "a", "5", 5)], "a"), 0);
});
check("cards held: 2 players, the old formula (4 - plays)", () => {
  const two = [play(0, "a", "5H", 5), play(0, "b", "5C", 10), play(0, "a", "6H", 16), go(0, "b", 16)];
  for (const id of ["a", "b"]) {
    const old = Math.max(4 - two.filter((p) => p.kind === "play" && p.user_id === id).length, 0);
    strictEqual(cardsLeft(4, two, id), old);
  }
});
check("Go labels: every player who said go in the run on the table (3 players)", () => {
  // Still in segment 0 (before the 31): a and b said go.
  const live = run3.slice(0, 5);
  deepStrictEqual([...goSayers(displayedRun(live, 0, false).events)].sort(), ["a", "b"]);
});
check("Go labels clear when the count resets", () => {
  // After the 31 the server is on segment 1 with no cards yet: the finished
  // run stays up (dimmed) with its Go labels...
  deepStrictEqual([...goSayers(displayedRun(run3, 1, false).events)].sort(), ["a", "b"]);
  // ...until the first card of the new run replaces it: no labels.
  const next = [...run3, play(1, "a", "AH", 1)];
  deepStrictEqual([...goSayers(displayedRun(next, 1, false).events)], []);
});
check("4 players: three go rows in one run, then the last card's run", () => {
  const run4: PlayEvent[] = [
    play(0, "a", "TC", 10), play(0, "b", "6C", 16), play(0, "c", "9H", 25), play(0, "d", "2S", 27),
    play(0, "a", "AS", 28), go(0, "b", 28), go(0, "c", 28), play(0, "d", "AC", 29),
    go(0, "a", 29), go(0, "b", 29), go(0, "c", 29), // d played last: the go point is d's
    play(1, "a", "KS", 10),
  ];
  deepStrictEqual([...goSayers(displayedRun(run4.slice(0, 11), 0, false).events)].sort(), ["a", "b", "c"]);
  deepStrictEqual([...goSayers(displayedRun(run4, 1, false).events)], []);
  // The hold after the last card shows the newest run with any plays.
  deepStrictEqual(displayedRun(run4, 1, true).events.map((p) => p.seq), [run4.at(-1)!.seq]);
});

// ---- Counting (A5a) and the next dealer ------------------------------------------
check("nextSeat: clockwise, wrapping; null for a stranger", () => {
  deepStrictEqual(["a", "b"].map((d) => nextSeat(["a", "b"], d)), ["b", "a"]);
  deepStrictEqual(["a", "b", "c"].map((d) => nextSeat(["a", "b", "c"], d)), ["b", "c", "a"]);
  deepStrictEqual(P4.map((d) => nextSeat(P4, d)), ["s2", "s3", "s4", "s1"]);
  strictEqual(nextSeat(P4, "x"), null);
  strictEqual(nextSeat(P4, null), null);
  // 2 players: the same person as the old rule (the player who isn't dealing).
  for (const d of ["a", "b"]) strictEqual(nextSeat(["a", "b"], d), ["a", "b"].find((p) => p !== d));
});

const NAMES: Record<string, string> = { a: "Ann", b: "Bob", c: "Cy", d: "Dee" };
const HANDS: Record<string, string[]> = {
  a: ["5S", "5C", "JH", "KD"], b: ["2S", "3S", "6S", "QS"], c: ["7D", "8D", "8C", "AD"], d: ["9S", "TC", "JC", "3H"],
};
const CRIB = ["2H", "6H", "8H", "KH"];
const STARTER = "4H";
function viewFor(players: string[], dealer: string, me: string, step: number, done = false, hideNumbers = false) {
  return countingViewN({
    players, myId: me, dealerId: dealer, names: NAMES,
    phase: done ? "done" : "counting", step,
    myHand: HANDS[me],
    hands: Object.fromEntries(players.filter((p) => p !== me).map((p) => [p, HANDS[p]])),
    cribCards: CRIB, starter: STARTER, hideNumbers,
  });
}

for (const players of [["a", "b", "c"], ["a", "b", "c", "d"]]) {
  const n = players.length;
  check(`${n} players: the counting order from every dealer (left first, the dealer last)`, () => {
    for (let di = 0; di < n; di++) {
      const dealer = players[di];
      const order = countingOrder(players, dealer);
      deepStrictEqual(order, Array.from({ length: n }, (_, k) => players[(di + 1 + k) % n]));
      strictEqual(order[n - 1], dealer); // the dealer counts their own hand at step N-1
    }
  });
  check(`${n} players: whose count it is, every dealer, every step, every viewer`, () => {
    for (const dealer of players) {
      const order = countingOrder(players, dealer);
      for (let step = 0; step <= n; step++) {
        const counter = step < n ? order[step] : dealer; // the crib is the dealer's
        for (const me of players) {
          const v = viewFor(players, dealer, me, step);
          strictEqual(v.counterId, counter);
          strictEqual(v.myTurn, me === counter);
          strictEqual(v.canConfirm, me === counter);
          strictEqual(v.isCribStep, step === n);
          strictEqual(v.myRowCounting, me === counter && step < n);
          strictEqual(v.waitingOn, me === counter ? null : `${NAMES[counter]} is counting`);
          // The middle: the hand being counted by someone else, or the crib at N.
          if (step === n) {
            deepStrictEqual(v.middle, { kind: "full", cards: CRIB });
            strictEqual(v.middleLabel, me === dealer ? "Your crib" : `${NAMES[dealer]}'s crib`);
          } else if (counter === me) {
            deepStrictEqual(v.middle, { kind: "none" });
          } else {
            deepStrictEqual(v.middle, { kind: "full", cards: HANDS[counter] });
            strictEqual(v.middleLabel, `${NAMES[counter]}'s hand`);
          }
          // Seats: the counted hand's seat is empty while it's in the middle.
          for (const p of players.filter((x) => x !== me)) {
            const inMiddle = step < n && p === counter;
            deepStrictEqual(v.seatCards[p], inMiddle ? { shown: null, count: 0 } : { shown: HANDS[p], count: 4 });
          }
          // The crib fans in the pile row only once everything is counted;
          // its pile is face-down until step N, an empty slot at step N
          // (the crib is in the middle).
          strictEqual(v.cribFan, null);
          strictEqual(v.cribPile, step === n ? "empty" : "faceDown");
          // Recap: one line per confirmed count, in order.
          deepStrictEqual(v.recap.map((r) => r.key), order.slice(0, Math.min(step, n)).map((p) => `hand-${p}`));
        }
      }
    }
  });
  check(`${n} players: done -- N+1 recap lines, the crib last and the dealer's`, () => {
    for (const dealer of players) {
      const me = players[0];
      const v = viewFor(players, dealer, me, n, true);
      strictEqual(v.counterId, null);
      strictEqual(v.myTurn, false);
      strictEqual(v.waitingOn, null);
      strictEqual(v.headline, "Every hand and the crib are counted.");
      deepStrictEqual(v.cribFan, CRIB);
      strictEqual(v.cribPile, "fan");
      strictEqual(v.recap.length, n + 1);
      deepStrictEqual(v.recap.map((r) => r.key), [...countingOrder(players, dealer).map((p) => `hand-${p}`), "crib"]);
      const cribLine = v.recap[n].text;
      strictEqual(cribLine.startsWith(dealer === me ? "Your crib: " : `${NAMES[dealer]}'s crib: `), true);
      // Each hand's line: "Your hand" for mine, "<name>'s hand" otherwise.
      for (const [i, p] of countingOrder(players, dealer).entries()) {
        strictEqual(v.recap[i].text.startsWith(p === me ? "Your hand: " : `${NAMES[p]}'s hand: `), true);
      }
    }
  });
  check(`${n} players: hidden numbers say only "<label> counted"`, () => {
    const v = viewFor(players, players[n - 1], players[0], n, true, true);
    strictEqual(v.recap.length, n + 1);
    strictEqual(v.recap.every((r) => /^(Your|[A-Z][a-z]+'s) (hand|crib) counted$/.test(r.text)), true);
  });
}
check("headlines: my hand, someone's hand, the crib", () => {
  const P = ["a", "b", "c"];
  strictEqual(viewFor(P, "c", "a", 0).headline, "Counting: your hand");
  strictEqual(viewFor(P, "c", "b", 0).headline, "Counting: Ann's hand");
  strictEqual(viewFor(P, "c", "c", 3).headline, "Counting: your crib");
  strictEqual(viewFor(P, "c", "a", 3).headline, "Counting: Cy's crib");
  strictEqual(viewFor(P, "c", "a", 0).hint, "Count it out loud, then Confirm Count.");
  strictEqual(viewFor(P, "c", "b", 0).hint, "");
});
check("2 players: countingViewN says what countingView says (turn, headline, hint, waiting, recap)", () => {
  const P = ["a", "b"];
  for (const dealer of P) {
    for (const me of P) {
      const opp = P.find((p) => p !== me)!;
      for (const [step, done] of [[0, false], [1, false], [2, false], [2, true]] as const) {
        for (const hideNumbers of [false, true]) {
          const n2 = viewFor(P, dealer, me, step, done, hideNumbers);
          const old = countingView({
            myId: me, dealerId: dealer, oppName: NAMES[opp], phase: done ? "done" : "counting", step,
            myHand: HANDS[me], oppCards: HANDS[opp], cribCards: CRIB, starter: STARTER, hideNumbers,
          });
          deepStrictEqual(
            [n2.myTurn, n2.canConfirm, n2.myRowCounting, n2.headline, n2.hint, n2.waitingOn, n2.recap.map((r) => r.text)],
            [old.myTurn, old.canConfirm, old.myRowCounting, old.headline, old.hint, old.waitingOn, old.recap]
          );
        }
      }
    }
  }
});

// ---- The win headline (A5b) ---------------------------------------------------------
const WN: Record<string, string> = { a: "Ann", b: "Bob", c: "Cy", d: "Dee" };
const seatedName = (id: string) => WN[id] ?? null;
check("win headline, 2 and 3 players: the old wording for every winner and viewer", () => {
  for (const players of [["a", "b"], ["a", "b", "c"]]) {
    for (const winner of players) {
      for (const me of players) {
        const old = winner === me ? "You win!" : `${WN[winner]} wins!`;
        strictEqual(winHeadline({ players, winnerId: winner, myId: me, nameOf: seatedName, teams: false }), old);
        // teams is ignored below 4 players
        strictEqual(winHeadline({ players, winnerId: winner, myId: me, nameOf: seatedName, teams: true }), old);
      }
    }
  }
});
check("win headline, 4-player Teams: every winner position, me on every seat", () => {
  const players = ["a", "b", "c", "d"]; // a+c against b+d
  const expected: Record<string, Record<string, string>> = {
    a: { a: "You and Cy win!", b: "Ann and Cy win!", c: "You and Ann win!", d: "Ann and Cy win!" },
    c: { a: "You and Cy win!", b: "Ann and Cy win!", c: "You and Ann win!", d: "Ann and Cy win!" },
    b: { a: "Bob and Dee win!", b: "You and Dee win!", c: "Bob and Dee win!", d: "You and Bob win!" },
    d: { a: "Bob and Dee win!", b: "You and Dee win!", c: "Bob and Dee win!", d: "You and Bob win!" },
  };
  for (const winner of players) {
    for (const me of players) {
      strictEqual(winHeadline({ players, winnerId: winner, myId: me, nameOf: seatedName, teams: true }), expected[winner][me]);
    }
  }
});
check("win headline, 4-player Solo: the winner alone", () => {
  const players = ["a", "b", "c", "d"];
  strictEqual(winHeadline({ players, winnerId: "c", myId: "a", nameOf: seatedName, teams: false }), "Cy wins!");
  strictEqual(winHeadline({ players, winnerId: "a", myId: "a", nameOf: seatedName, teams: false }), "You win!");
});
check("win headline: a winner or partner who has left; a winner not in the game", () => {
  const players = ["a", "b", "c", "d"];
  const gone = (id: string) => (id === "c" ? null : WN[id]);
  strictEqual(winHeadline({ players, winnerId: "a", myId: "b", nameOf: gone, teams: true }), "Ann and A player who has left win!");
  strictEqual(winHeadline({ players, winnerId: "a", myId: "a", nameOf: gone, teams: true }), "You and A player who has left win!");
  strictEqual(winHeadline({ players: ["a", "b", "c"], winnerId: "c", myId: "a", nameOf: gone, teams: false }), "A player who has left wins!");
  // Not in the game's players (shouldn't happen): the plain wording.
  strictEqual(winHeadline({ players, winnerId: "z", myId: "a", nameOf: seatedName, teams: true }), "A player who has left wins!");
  strictEqual(winHeadline({ players, winnerId: null, myId: "a", nameOf: seatedName, teams: true }), "A player who has left wins!");
});

// ---- The square table (lib/tableLayout.ts) -------------------------------------
check("square table: each seat's rotation and pile sides", () => {
  deepStrictEqual(seatGeometry("bottom"), { rotation: 0, crib: "left", deck: "right" });
  deepStrictEqual(seatGeometry("left"), { rotation: 90, crib: "top", deck: "bottom" });
  deepStrictEqual(seatGeometry("top"), { rotation: 180, crib: "right", deck: "left" });
  deepStrictEqual(seatGeometry("right"), { rotation: -90, crib: "bottom", deck: "top" });
});
check("square table: who sits where (2, 3 and 4 players; a non-player viewer)", () => {
  deepStrictEqual(seatsOnScreen(["a", "b"], "a"), { bottom: "a", left: null, top: "b", right: null });
  deepStrictEqual(seatsOnScreen(["a", "b"], "b"), { bottom: "b", left: null, top: "a", right: null });
  deepStrictEqual(seatsOnScreen(["a", "b", "c"], "b"), { bottom: "b", left: "c", top: null, right: "a" });
  deepStrictEqual(seatsOnScreen(P4, "s3"), { bottom: "s3", left: "s4", top: "s1", right: "s2" });
  strictEqual(seatsOnScreen(["a", "b"], "z").bottom, null);
});

// Plays for the square-table checks: "me" and "op", either one dealing.
const sq = (seq: number, segment: number, user_id: string, card: string | null, count_after = 0): PlayEvent => ({
  seq, segment, user_id, kind: card ? "play" : "go", card, count_after,
});
const seatCards = (r: ReturnType<typeof playedBySeat>) => ({
  bottom: r.seats.bottom.cards, top: r.seats.top.cards, left: r.seats.left.cards, right: r.seats.right.cards,
});
check("square table, 2 players: I deal (the opponent leads) -- each seat's cards in play order", () => {
  const plays = [sq(1, 0, "op", "KH", 10), sq(2, 0, "me", "5D", 15), sq(3, 0, "op", "4C", 19), sq(4, 0, "me", "2S", 21)];
  for (const players of [["me", "op"], ["op", "me"]]) {
    const r = playedBySeat({ plays, playSegment: 0, handOver: false, players, myId: "me" });
    deepStrictEqual(seatCards(r), { bottom: ["5D", "2S"], top: ["KH", "4C"], left: [], right: [] });
    strictEqual(r.seats.bottom.userId, "me");
    strictEqual(r.seats.top.userId, "op");
    strictEqual(r.finished, false);
  }
  // The other screen: the same run, the seats swapped.
  const theirs = playedBySeat({ plays, playSegment: 0, handOver: false, players: ["me", "op"], myId: "op" });
  deepStrictEqual(seatCards(theirs), { bottom: ["KH", "4C"], top: ["5D", "2S"], left: [], right: [] });
});
check("square table, 2 players: the opponent deals (I lead)", () => {
  const plays = [sq(1, 0, "me", "7H", 7), sq(2, 0, "op", "8D", 15), sq(3, 0, "me", "9C", 24)];
  const r = playedBySeat({ plays, playSegment: 0, handOver: false, players: ["op", "me"], myId: "me" });
  deepStrictEqual(seatCards(r), { bottom: ["7H", "9C"], top: ["8D"], left: [], right: [] });
});
check("square table: a run that reset after 31 -- only the new run's cards", () => {
  const plays = [
    sq(1, 0, "op", "KH", 10), sq(2, 0, "me", "TD", 20), sq(3, 0, "op", "5C", 25), sq(4, 0, "me", "6S", 31),
    sq(5, 1, "op", "9H", 9), sq(6, 1, "me", "8D", 17),
  ];
  const r = playedBySeat({ plays, playSegment: 1, handOver: false, players: ["me", "op"], myId: "me" });
  deepStrictEqual(seatCards(r), { bottom: ["8D"], top: ["9H"], left: [], right: [] });
  strictEqual(r.finished, false);
  // Between runs (31 made, nothing in the new run yet): the finished run stays up.
  const between = playedBySeat({ plays: plays.slice(0, 4), playSegment: 1, handOver: false, players: ["me", "op"], myId: "me" });
  deepStrictEqual(seatCards(between), { bottom: ["TD", "6S"], top: ["KH", "5C"], left: [], right: [] });
  strictEqual(between.finished, true);
});
check("square table: a run that reset after a Go -- the go is not a card, and the old run clears", () => {
  const plays = [
    sq(1, 0, "op", "KH", 10), sq(2, 0, "me", "QD", 20), sq(3, 0, "op", "9C", 29), sq(4, 0, "me", null, 29),
  ];
  const ended = playedBySeat({ plays, playSegment: 1, handOver: false, players: ["me", "op"], myId: "me" });
  deepStrictEqual(seatCards(ended), { bottom: ["QD"], top: ["KH", "9C"], left: [], right: [] });
  strictEqual(ended.finished, true);
  const next = playedBySeat({
    plays: [...plays, sq(5, 1, "me", "4S", 4)], playSegment: 1, handOver: false, players: ["me", "op"], myId: "me",
  });
  deepStrictEqual(seatCards(next), { bottom: ["4S"], top: [], left: [], right: [] });
});
check("square table: the hold after the last card makes 31 -- the run that made it", () => {
  const plays = [
    sq(1, 0, "op", "KH", 10), sq(2, 0, "me", "TD", 20), sq(3, 0, "op", "9C", 29), sq(4, 0, "me", null, 29),
    sq(5, 1, "me", "9H", 9), sq(6, 1, "op", "8D", 17), sq(7, 1, "me", "7C", 24), sq(8, 1, "op", "7S", 31),
  ];
  const r = playedBySeat({ plays, playSegment: 2, handOver: true, players: ["me", "op"], myId: "me" });
  deepStrictEqual(seatCards(r), { bottom: ["9H", "7C"], top: ["8D", "7S"], left: [], right: [] });
  strictEqual(r.finished, true);
});
check("square table: plays arriving out of order are shown in play order; 4 players fill every seat", () => {
  const plays = [sq(3, 0, "s3", "3C"), sq(1, 0, "s1", "AC"), sq(4, 0, "s4", "4C"), sq(2, 0, "s2", "2C"), sq(5, 0, "s1", "5C")];
  const r = playedBySeat({ plays, playSegment: 0, handOver: false, players: P4, myId: "s1" });
  deepStrictEqual(seatCards(r), { bottom: ["AC", "5C"], left: ["2C"], top: ["3C"], right: ["4C"] });
});

// WHICH LAYOUT (chooseTableLayout): square by default for 2 and 3 players,
// not Muggins, on its screens; ?layout=classic is the way out.
const layoutFor = (layoutParam: string | null, playerCount: number, isMuggins: boolean, screen: TableScreen) =>
  chooseTableLayout({ layoutParam, playerCount, isMuggins, screen });
const SQUARE_SCREENS: TableScreen[] = ["discard", "pegging", "counting", "won"];
const CLASSIC_SCREENS: TableScreen[] = ["waiting-room", "cut", "ended", "other"];
check("layout: 2 players, no param -- square on its screens, classic elsewhere", () => {
  for (const s of SQUARE_SCREENS) strictEqual(layoutFor(null, 2, false, s), "square", s);
  for (const s of CLASSIC_SCREENS) strictEqual(layoutFor(null, 2, false, s), "classic", s);
});
check("layout: ?layout=classic always classic; ?layout=square and unknown values are the default", () => {
  for (const s of SQUARE_SCREENS) {
    strictEqual(layoutFor("classic", 2, false, s), "classic", s);
    strictEqual(layoutFor("square", 2, false, s), "square", s);
    strictEqual(layoutFor("round", 2, false, s), "square", s);
    strictEqual(layoutFor("", 2, false, s), "square", s);
  }
  for (const s of CLASSIC_SCREENS) strictEqual(layoutFor("square", 2, false, s), "classic", s);
});
check("layout: 4-player Solo (not Teams), and 3- or 4-player Muggins, are classic with or without the param", () => {
  for (const param of [null, "square", "classic", "x"]) {
    for (const s of [...SQUARE_SCREENS, ...CLASSIC_SCREENS]) {
      strictEqual(layoutFor(param, 4, false, s), "classic", `4p ${param} ${s}`);
      strictEqual(layoutFor(param, 3, true, s), "classic", `3p muggins ${param} ${s}`);
      strictEqual(layoutFor(param, 4, true, s), "classic", `4p muggins ${param} ${s}`);
      strictEqual(
        chooseTableLayout({ layoutParam: param, playerCount: 4, isMuggins: true, teams: true, screen: s }),
        "classic",
        `4p teams muggins ${param} ${s}`
      );
    }
  }
  strictEqual(isSquareTable({ layoutParam: null, playerCount: 2, isMuggins: false }), true);
  strictEqual(isSquareTable({ layoutParam: "classic", playerCount: 2, isMuggins: false }), false);
  strictEqual(isSquareTable({ layoutParam: null, playerCount: 4, isMuggins: false }), false);
  strictEqual(isSquareTable({ layoutParam: "square", playerCount: 4, isMuggins: false }), false);
});
check("layout: 2-player self-scoring (Muggins) -- the 2-player rule: square by default, ?layout=classic classic", () => {
  for (const param of [null, "square", "x", "", "Square"]) {
    for (const s of SQUARE_SCREENS) strictEqual(layoutFor(param, 2, true, s), "square", `muggins ${param} ${s}`);
    for (const s of CLASSIC_SCREENS) strictEqual(layoutFor(param, 2, true, s), "classic", `muggins ${param} ${s}`);
  }
  for (const s of [...SQUARE_SCREENS, ...CLASSIC_SCREENS]) strictEqual(layoutFor("classic", 2, true, s), "classic", s);
  // Exactly the 2-player rule.
  for (const param of [null, "square", "classic", "x"]) {
    for (const s of [...SQUARE_SCREENS, ...CLASSIC_SCREENS]) {
      strictEqual(layoutFor(param, 2, true, s), layoutFor(param, 2, false, s), `${param} ${s}`);
    }
  }
  strictEqual(isSquareTable({ layoutParam: null, playerCount: 2, isMuggins: true }), true);
  strictEqual(isSquareTable({ layoutParam: "classic", playerCount: 2, isMuggins: true }), false);
});
check("layout: 3 players -- square by default on its screens, classic elsewhere", () => {
  // No param, ?layout=square and unknown values are all the default.
  for (const param of [null, "square", "x", "", "Square"]) {
    for (const s of SQUARE_SCREENS) strictEqual(layoutFor(param, 3, false, s), "square", `3p ${param} ${s}`);
    for (const s of CLASSIC_SCREENS) strictEqual(layoutFor(param, 3, false, s), "classic", `3p ${param} ${s}`);
  }
  strictEqual(isSquareTable({ layoutParam: null, playerCount: 3, isMuggins: false }), true);
  strictEqual(isSquareTable({ layoutParam: "square", playerCount: 3, isMuggins: false }), true);
});
check("layout: 3 players -- ?layout=classic always classic", () => {
  for (const s of [...SQUARE_SCREENS, ...CLASSIC_SCREENS]) strictEqual(layoutFor("classic", 3, false, s), "classic", s);
  strictEqual(isSquareTable({ layoutParam: "classic", playerCount: 3, isMuggins: false }), false);
});
check("layout: 2 and 3 players follow the same rule; other table sizes (and 4-player Solo) never square", () => {
  for (const param of [null, "square", "classic", "x"]) {
    for (const s of [...SQUARE_SCREENS, ...CLASSIC_SCREENS]) {
      strictEqual(layoutFor(param, 3, false, s), layoutFor(param, 2, false, s), `${param} ${s}`);
      for (const n of [0, 1, 4, 5]) strictEqual(layoutFor(param, n, false, s), "classic", `${n}p ${param} ${s}`);
    }
  }
});
check("layout: 4-player Teams -- square by default on its screens, classic elsewhere", () => {
  const teams4 = (layoutParam: string | null, screen: TableScreen, isMuggins = false) =>
    chooseTableLayout({ layoutParam, playerCount: 4, isMuggins, teams: true, screen });
  // No param, ?layout=square and unknown values are all the default.
  for (const param of [null, "square", "x", "", "Square"]) {
    for (const s of SQUARE_SCREENS) strictEqual(teams4(param, s), "square", `${param} ${s}`);
    for (const s of CLASSIC_SCREENS) strictEqual(teams4(param, s), "classic", `${param} ${s}`);
  }
  // ?layout=classic: always classic.
  for (const s of [...SQUARE_SCREENS, ...CLASSIC_SCREENS]) strictEqual(teams4("classic", s), "classic", s);
  // Muggins never; 4-player Solo (not Teams) never.
  for (const param of [null, "square", "classic", "x"]) {
    for (const s of SQUARE_SCREENS) {
      strictEqual(teams4(param, s, true), "classic", `muggins ${param} ${s}`);
      strictEqual(chooseTableLayout({ layoutParam: param, playerCount: 4, isMuggins: false, teams: false, screen: s }), "classic");
    }
  }
  strictEqual(isSquareTable({ layoutParam: null, playerCount: 4, isMuggins: false, teams: true }), true);
  strictEqual(isSquareTable({ layoutParam: "square", playerCount: 4, isMuggins: false, teams: true }), true);
  strictEqual(isSquareTable({ layoutParam: "classic", playerCount: 4, isMuggins: false, teams: true }), false);
  // 4-player Teams follows the 2- and 3-player rule exactly.
  for (const param of [null, "square", "classic", "x", ""]) {
    for (const s of [...SQUARE_SCREENS, ...CLASSIC_SCREENS]) strictEqual(teams4(param, s), layoutFor(param, 2, false, s), `${param} ${s}`);
  }
  // The teams flag changes nothing for 2 and 3 players.
  for (const param of [null, "square", "classic"]) {
    for (const n of [2, 3]) {
      strictEqual(
        isSquareTable({ layoutParam: param, playerCount: n, isMuggins: false, teams: true }),
        isSquareTable({ layoutParam: param, playerCount: n, isMuggins: false }),
        `${n}p ${param}`
      );
    }
  }
});

// 4-PLAYER TEAMS ON THE SQUARE TABLE: me at the bottom, then clockwise left,
// top (my partner) and right. (Its own block: P4 here is a different list.)
{
const P4 = ["a", "b", "c", "d"];
check("square table, 4 players: left, top (partner), right from every viewpoint", () => {
  deepStrictEqual(seatsOnScreen(P4, "a"), { bottom: "a", left: "b", top: "c", right: "d" });
  deepStrictEqual(seatsOnScreen(P4, "b"), { bottom: "b", left: "c", top: "d", right: "a" });
  deepStrictEqual(seatsOnScreen(P4, "c"), { bottom: "c", left: "d", top: "a", right: "b" });
  deepStrictEqual(seatsOnScreen(P4, "d"), { bottom: "d", left: "a", top: "b", right: "c" });
  for (const me of P4) {
    // My partner (same team) is always across.
    const top = seatsOnScreen(P4, me).top!;
    strictEqual(teamOfPosition(P4, top), teamOfPosition(P4, me), me);
    strictEqual(seatPositionOf(P4, me, me), "bottom");
  }
});
check("board lanes: Teams by team (red 0 / blue 1) for every seat and viewer; 2/3 players by seat", () => {
  for (const id of ["a", "c"]) strictEqual(laneForPlayer({ players: P4, userId: id, teams: true }), 0, id);
  for (const id of ["b", "d"]) strictEqual(laneForPlayer({ players: P4, userId: id, teams: true }), 1, id);
  strictEqual(laneForPlayer({ players: P4, userId: "z", teams: true }), null);
  // From the game's own list (the same array on every screen), never from a
  // viewer's "me first" order: seatOrderFrom(P4, me) would put every viewer
  // in lane 0.
  for (const me of P4) {
    const meFirst = seatOrderFrom(P4, me);
    strictEqual(laneForPlayer({ players: meFirst, userId: me, teams: true }), 0);
  }
  strictEqual(laneForPlayer({ players: P4, userId: "b", teams: true }), 1);
  // 2 and 3 players (and teams off): the seat lanes, as before.
  deepStrictEqual(["a", "b", "c"].map((id) => laneForPlayer({ players: ["a", "b", "c"], userId: id, teams: false })), [0, 1, 2]);
  deepStrictEqual(["a", "b"].map((id) => laneForPlayer({ players: ["a", "b"], userId: id, teams: true })), [0, 1]);
  strictEqual(laneForPlayer({ players: P4, userId: "d", teams: false }), null);
});
check("ring layout: side names and columns keyed on whether the top seat is filled", () => {
  deepStrictEqual(ringLayout({ top: false, sides: true }), {
    hasTop: false,
    sideTags: "under-header",
    sideColumns: "above-mine",
    acrossPiles: "hanging",
  });
  deepStrictEqual(ringLayout({ top: true, sides: true }), {
    hasTop: true,
    sideTags: "under-top-row",
    sideColumns: "full-height",
    acrossPiles: "level",
  });
  // 2 players: the top seat alone -- its piles hang, as always.
  strictEqual(ringLayout({ top: true, sides: false }).acrossPiles, "hanging");
});
check("square table, 4 players: each seat's played cards, from every view", () => {
  // Dealer d: a leads. One run: a b c d a.
  const plays: PlayEvent[] = ["a", "b", "c", "d", "a"].map((u, i) => ({
    seq: i + 1, segment: 0, user_id: u, kind: "play", card: ["AH", "2H", "3H", "4H", "5H"][i], count_after: 0,
  }));
  for (const me of P4) {
    const { seats } = playedBySeat({ plays, playSegment: 0, handOver: false, players: P4, myId: me });
    const on = seatsOnScreen(P4, me);
    for (const pos of ["bottom", "left", "top", "right"] as const) {
      deepStrictEqual(seats[pos].cards, plays.filter((p) => p.user_id === on[pos]).map((p) => p.card), `${me} ${pos}`);
    }
  }
});
check("counting reveals, 4 players: clockwise from the dealer's left, the dealer last, crib at step 4", () => {
  for (const dealer of P4) {
    const order = countingOrder(P4, dealer);
    strictEqual(order.at(-1), dealer);
    strictEqual(order[0], P4[(P4.indexOf(dealer) + 1) % 4]);
    for (let step = 0; step <= 4; step++) {
      const r = countingReveals({ players: P4, dealerId: dealer, step, done: false });
      order.forEach((id, k) => strictEqual(r.hands[id], step >= k, `${dealer} ${step} ${id}`));
      strictEqual(r.crib, step >= 4);
    }
    const done = countingReveals({ players: P4, dealerId: dealer, step: 0, done: true });
    strictEqual(Object.values(done.hands).every(Boolean) && done.crib, true);
  }
});
check("starter in counting, 4 players: my deal above my hand; left, top or right in the middle", () => {
  for (const me of P4) {
    for (const dealer of P4) {
      strictEqual(
        countingStarterPlace(seatPositionOf(P4, me, dealer), true),
        dealer === me ? "above-hand" : "middle",
        `${me} ${dealer}`
      );
    }
  }
});
check("discard toss, 4 players: one card from each of the other three seats, in order", () => {
  const steps = discardPlan([{ seat: "left", cards: 1 }, { seat: "top", cards: 1 }, { seat: "right", cards: 1 }]);
  deepStrictEqual(steps.map((s) => s.seat), ["left", "top", "right"]);
  strictEqual(handSizes(4).discard, 1);
  strictEqual(cribCountDuringDiscard(4, 0), 0);
  strictEqual(cribCountDuringDiscard(4, 4), 4);
});
}

// 3 PLAYERS ON THE SQUARE TABLE: me at the bottom, the next player clockwise
// on my left, the one after on my right, nobody across.
const P3 = ["a", "b", "c"];
check("square table, 3 players: left is the next seat clockwise, right the one after, top empty", () => {
  deepStrictEqual(seatsOnScreen(P3, "a"), { bottom: "a", left: "b", top: null, right: "c" });
  deepStrictEqual(seatsOnScreen(P3, "b"), { bottom: "b", left: "c", top: null, right: "a" });
  deepStrictEqual(seatsOnScreen(P3, "c"), { bottom: "c", left: "a", top: null, right: "b" });
  // A viewer who isn't a player: nobody at the bottom.
  strictEqual(seatsOnScreen(P3, "z").bottom, null);
});
check("square table: seatPositionOf for 2, 3 and 4 players", () => {
  deepStrictEqual(["a", "b", "c", "z"].map((id) => seatPositionOf(P3, "a", id)), ["bottom", "left", "right", null]);
  deepStrictEqual(["a", "b", "c"].map((id) => seatPositionOf(P3, "c", id)), ["left", "right", "bottom"]);
  deepStrictEqual(["a", "b"].map((id) => seatPositionOf(["a", "b"], "b", id)), ["top", "bottom"]);
  deepStrictEqual(P4.map((id) => seatPositionOf(P4, "s2", id)), ["right", "bottom", "left", "top"]);
});
check("square table, 3 players: each seat's played cards, from every seat's point of view", () => {
  // Pegging starts left of the dealer (c deals: a leads), then b, c, a.
  const plays = [sq(1, 0, "a", "5H"), sq(2, 0, "b", "TD"), sq(3, 0, "c", "6S"), sq(4, 0, "a", "4C")];
  const view = (myId: string) => seatCards(playedBySeat({ plays, playSegment: 0, handOver: false, players: P3, myId }));
  deepStrictEqual(view("a"), { bottom: ["5H", "4C"], left: ["TD"], top: [], right: ["6S"] });
  deepStrictEqual(view("b"), { bottom: ["TD"], left: ["6S"], top: [], right: ["5H", "4C"] });
  deepStrictEqual(view("c"), { bottom: ["6S"], left: ["5H", "4C"], top: [], right: ["TD"] });
});
check("square table, 3 players: a Go leaves no card; the next run clears the seats", () => {
  const plays = [
    sq(1, 0, "a", "KH", 10),
    sq(2, 0, "b", "QD", 20),
    sq(3, 0, "c", "9C", 29),
    sq(4, 0, "a", null, 29),
    sq(5, 0, "b", null, 29),
    sq(6, 1, "c", "3S", 3),
  ];
  const during = playedBySeat({ plays: plays.slice(0, 5), playSegment: 0, handOver: false, players: P3, myId: "a" });
  deepStrictEqual(seatCards(during), { bottom: ["KH"], left: ["QD"], top: [], right: ["9C"] });
  const next = playedBySeat({ plays, playSegment: 1, handOver: false, players: P3, myId: "a" });
  deepStrictEqual(seatCards(next), { bottom: [], left: [], top: [], right: ["3S"] });
});
check("square table: counting reveals -- 3 players, the dealer at each seat", () => {
  // order: clockwise from the dealer's left, the dealer last; the crib at step 3.
  for (const dealer of P3) {
    const order = countingOrder(P3, dealer);
    strictEqual(order[2], dealer);
    for (let step = 0; step <= 3; step++) {
      const r = countingReveals({ players: P3, dealerId: dealer, step, done: false });
      deepStrictEqual(
        order.map((id) => r.hands[id]),
        order.map((_, k) => step >= k),
        `dealer ${dealer} step ${step}`
      );
      strictEqual(r.crib, step >= 3, `crib, dealer ${dealer} step ${step}`);
    }
    const done = countingReveals({ players: P3, dealerId: dealer, step: 0, done: true });
    deepStrictEqual(P3.map((id) => done.hands[id]), [true, true, true]);
    strictEqual(done.crib, true);
  }
  // Concretely: b deals -- c counts first, then a, then b, then b's crib.
  const at = (step: number) => countingReveals({ players: P3, dealerId: "b", step, done: false });
  deepStrictEqual(at(0).hands, { c: true, a: false, b: false });
  deepStrictEqual(at(1).hands, { c: true, a: true, b: false });
  deepStrictEqual(at(2).hands, { c: true, a: true, b: true });
  strictEqual(at(2).crib, false);
  strictEqual(at(3).crib, true);
});
check("square table: counting reveals -- 2 players match the square table's pone-then-dealer rule", () => {
  // The 2-player square table turns the other hand up at step 0 if they're
  // the pone, step 1 if they dealt; the crib at step 2.
  const r0 = countingReveals({ players: ["me", "op"], dealerId: "me", step: 0, done: false });
  deepStrictEqual(r0, { hands: { op: true, me: false }, crib: false });
  const r1 = countingReveals({ players: ["me", "op"], dealerId: "op", step: 0, done: false });
  deepStrictEqual(r1, { hands: { me: true, op: false }, crib: false });
  strictEqual(countingReveals({ players: ["me", "op"], dealerId: "op", step: 2, done: false }).crib, true);
});

// THE CRIBBAGE BOARD (lib/boardLayout.ts).
check("board: scores clamp to 0 .. 121", () => {
  deepStrictEqual([-5, 0, 1, 60, 61, 120, 121, 122, 400].map(clampScore), [0, 0, 1, 60, 61, 120, 121, 121, 121]);
  strictEqual(clampScore(Number.NaN), 0);
});
check("board: start, out row 1-60 left to right, back row 61-120 right to left, game hole", () => {
  deepStrictEqual(holeSpot(0), { kind: "start" });
  deepStrictEqual(holeSpot(-3), { kind: "start" });
  deepStrictEqual(holeSpot(1), { kind: "hole", row: "out", column: 0 });
  deepStrictEqual(holeSpot(60), { kind: "hole", row: "out", column: 59 });
  deepStrictEqual(holeSpot(61), { kind: "hole", row: "back", column: 59 });
  deepStrictEqual(holeSpot(120), { kind: "hole", row: "back", column: 0 });
  deepStrictEqual(holeSpot(121), { kind: "game" });
  deepStrictEqual(holeSpot(130), { kind: "game" });
});
check("board: hole positions -- the turn at 60/61, the home end at 120/121, lanes stacked", () => {
  const g = boardGeometry(375, 80);
  const at = (lane: number, s: number, slot: 0 | 1 = 0) => holePosition(g, lane, s, slot);
  // 60 and 61 face each other at the far end; 1 and 120 at the home end.
  strictEqual(at(0, 60).x, at(0, 61).x);
  strictEqual(at(0, 1).x, at(0, 120).x);
  strictEqual(at(0, 60).y, g.rows[0].out);
  strictEqual(at(0, 61).y, g.rows[0].back);
  // Out runs left to right, back right to left.
  strictEqual(at(0, 2).x > at(0, 1).x, true);
  strictEqual(at(0, 62).x < at(0, 61).x, true);
  // The game hole is beside 120, under the two start holes; the start holes
  // are left of hole 1, one per peg.
  strictEqual(at(0, 121).y, g.rows[0].back);
  strictEqual(at(0, 121).x < at(0, 120).x, true);
  strictEqual(at(0, 0, 0).x < at(0, 0, 1).x, true);
  strictEqual(at(0, 0, 1).x < at(0, 1).x, true);
  deepStrictEqual(at(0, 200), at(0, 121));
  deepStrictEqual(at(0, -1), at(0, 0));
  // Lane 1 is below lane 0, lane 2 below lane 1, same columns.
  strictEqual(at(1, 1).y > at(0, 61).y, true);
  strictEqual(at(2, 1).y > at(1, 61).y, true);
  strictEqual(at(2, 37).x, at(0, 37).x);
});
check("board: groups of five, a wider gap between groups", () => {
  const g = boardGeometry(375, 80);
  const x = (s: number) => holePosition(g, 0, s).x;
  const inGroup = x(2) - x(1);
  const across = x(6) - x(5);
  strictEqual(Math.abs(x(5) - x(4) - inGroup) < 1e-9, true);
  strictEqual(across > inGroup, true);
  strictEqual(Math.abs(across - (inGroup + g.groupGap)) < 1e-9, true);
});
check("board: 123 holes a lane, every one inside the board, none touching", () => {
  for (const [w, h] of [[375, 66], [375, 80], [390, 84], [502, 108], [896, 108]]) {
    const g = boardGeometry(w, h);
    const holes = boardHoles(g);
    strictEqual(holes.length, 3 * 123);
    for (const hole of holes) {
      strictEqual(hole.x - g.pegR >= 0 && hole.x + g.pegR <= w, true, `x in ${w}x${h}`);
      strictEqual(hole.y - g.pegR >= 0 && hole.y + g.pegR <= h, true, `y in ${w}x${h}`);
    }
    strictEqual(g.holeR * 2 < g.pitch, true);
    strictEqual(g.pitch >= 5.4, true, `pitch ${g.pitch} at ${w}`);
  }
});
check("board: pegs at least 9.8px on a phone, bigger than a hole, inside the board", () => {
  // 343 wide: a 375px phone less a 16px gutter each side (the strip itself
  // is the full 375 today).
  for (const [w, h] of [[343, 67], [375, 67], [390, 84], [502, 108], [896, 108]]) {
    const g = boardGeometry(w, h);
    strictEqual(g.pegR >= PEG_MIN_R && g.pegR * 2 >= 9.8, true, `peg ${g.pegR * 2} at ${w}x${h}`);
    strictEqual(g.pegR > g.holeR * 1.5, true);
    for (const row of g.rows) strictEqual(row.out - g.pegR >= 0 && row.back + g.pegR <= h, true, `rows at ${w}x${h}`);
    // Clear of the next lane's pegs.
    for (let lane = 1; lane < g.rows.length; lane++) {
      strictEqual(g.rows[lane].out - g.rows[lane - 1].back >= 2 * g.pegR, true, `lanes at ${w}x${h}`);
    }
  }
});

// THE BOARD SKINS (lib/boardSkins.ts).
const NEW_SKINS = BOARD_SKIN_LIST.filter((s) => s.id !== CLASSIC_WOOD.id);
check("board skins: six, unique ids, 3 lanes and 3 pegs each, every colour valid hex", () => {
  strictEqual(BOARD_SKIN_LIST.length, 6);
  deepStrictEqual(
    BOARD_SKIN_LIST.map((s) => s.id),
    ["classic-wood", "midnight", "espresso", "mahogany", "heritage", "metallic"]
  );
  strictEqual(new Set(BOARD_SKIN_LIST.map((s) => s.id)).size, BOARD_SKIN_LIST.length);
  strictEqual(CLASSIC_WOOD.name, "Classic Pine");
  for (const s of BOARD_SKIN_LIST) {
    strictEqual(s.lanes.length, 3, s.id);
    const colors = [
      ...s.lanes.flatMap((l) => [l.color, l.peg, ...(l.paint ? [l.paint] : [])]),
      s.wood.top,
      s.wood.bottom,
      ...(s.wood.grain ? [s.wood.grain] : []),
      s.rim.edge,
      s.rim.highlight,
      ...(s.rim.chrome ?? []),
      s.hole.fill,
      ...(s.hole.lip ? [s.hole.lip] : []),
      ...(s.panel ? [s.panel] : []),
    ];
    for (const c of colors) strictEqual(isHexColor(c), true, `${s.id}: ${c}`);
    strictEqual(s.lanes.filter((l) => isHexColor(l.peg)).length, 3, s.id);
    // An outline board needs its panel colour.
    if (s.laneStyle === "outline") strictEqual(s.panel !== undefined, true, s.id);
  }
});
check("board skins: the exact colours asked for", () => {
  const lanes = (id: string) => boardSkinById(id).lanes.map((l) => l.color);
  const pegs = (id: string) => boardSkinById(id).lanes.map((l) => l.peg);
  deepStrictEqual(lanes("midnight"), ["#f2f2f2", "#e0b443", "#6cc4ff"]);
  deepStrictEqual(pegs("midnight"), ["#ffffff", "#e0b443", "#6cc4ff"]);
  deepStrictEqual(lanes("espresso"), ["#e5413b", "#34b857", "#3578ec"]);
  deepStrictEqual(pegs("espresso"), ["#e9edf2", "#17110e", "#f2cf63"]);
  deepStrictEqual(lanes("mahogany"), ["#d8302f", "#f4f1ea", "#2c63c8"]);
  deepStrictEqual(pegs("mahogany"), ["#d9dde2", "#1b1b1f", "#f6d57a"]);
  deepStrictEqual(lanes("heritage"), ["#8c5a44", "#c8a47c", "#efe6d4"]);
  deepStrictEqual(pegs("heritage"), ["#f3e3c3", "#2c1d17", "#a8622f"]);
  deepStrictEqual(lanes("metallic"), ["#b9733a", "#d9b44c", "#c9cdd3"]);
  deepStrictEqual(pegs("metallic"), ["#f5f7fa", "#2b3038", "#a85a26"]);
  // Classic Pine: today's colours; its rings stay today's peg colours.
  deepStrictEqual(pegs("classic-wood"), ["#d32f2f", "#1e63d6", "#2e9b4b"]);
  deepStrictEqual([0, 1, 2].map((i) => laneRingColor(CLASSIC_WOOD, i)), ["#d32f2f", "#1e63d6", "#2e9b4b"]);
});
check("board skins: every peg reads on its lane (2.5:1), Classic Pine the one exception", () => {
  for (const s of BOARD_SKIN_LIST) {
    strictEqual(pegContrastExempt(s), s.id === CLASSIC_WOOD.id, s.id);
    if (pegContrastExempt(s)) continue;
    for (const lane of [0, 1, 2]) {
      const ratio = pegContrast(s, lane);
      strictEqual(ratio >= PEG_CONTRAST_MIN, true, `${s.id} lane ${lane}: ${ratio.toFixed(2)}`);
    }
  }
  // The outline board measures against its dark panel, not the outline.
  const midnight = boardSkinById("midnight");
  strictEqual(pegContrast(midnight, 0), contrastRatio("#ffffff", "#1d1d23"));
});
check("board skins: holes read on their lane (2.9:1); outlined lanes exempt", () => {
  for (const s of NEW_SKINS) {
    strictEqual(holeContrastExempt(s), s.laneStyle === "outline", s.id);
    if (holeContrastExempt(s)) continue;
    for (const lane of [0, 1, 2]) {
      const ratio = holeContrast(s, lane);
      strictEqual(ratio >= HOLE_CONTRAST_MIN, true, `${s.id} lane ${lane}: ${ratio.toFixed(2)}`);
    }
  }
});
check("board skins: a board's three lane colours are clearly different", () => {
  for (const s of BOARD_SKIN_LIST) {
    const d = laneSeparation(s);
    strictEqual(d >= LANE_DISTANCE_MIN, true, `${s.id}: ${d.toFixed(1)}`);
  }
});
check("board skins: the self-scoring banner's text reads on every new board", () => {
  for (const s of NEW_SKINS) {
    const text = bannerTextColor(s);
    const worst = Math.min(contrastRatio(text, s.wood.top), contrastRatio(text, s.wood.bottom));
    strictEqual(worst >= 4.5, true, `${s.id}: ${worst.toFixed(2)}`);
  }
  // Classic Pine keeps its rim-coloured text.
  strictEqual(bannerTextColor(CLASSIC_WOOD), CLASSIC_WOOD.rim.edge);
});
check("board setting: unknown or missing falls back to Classic Pine, storage never throws", () => {
  strictEqual(boardSkinById(null).id, "classic-wood");
  strictEqual(boardSkinById(undefined).id, "classic-wood");
  strictEqual(boardSkinById("").id, "classic-wood");
  strictEqual(boardSkinById("walnut").id, "classic-wood");
  strictEqual(boardSkinById("toString").id, "classic-wood");
  strictEqual(boardSkinById("metallic").id, "metallic");
  // No localStorage at all (as here, in Node): reads Classic Pine, writes
  // quietly do nothing.
  strictEqual(readBoardSkinId(), "classic-wood");
  writeBoardSkinId("midnight");
  // A working store.
  const store = new Map<string, string>();
  const g = globalThis as unknown as { localStorage?: unknown };
  g.localStorage = {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v),
    removeItem: (k: string) => void store.delete(k),
  };
  try {
    strictEqual(readBoardSkinId(), "classic-wood");
    writeBoardSkinId("espresso");
    strictEqual(store.get(BOARD_SETTING_KEY), "espresso");
    strictEqual(readBoardSkinId(), "espresso");
    store.set(BOARD_SETTING_KEY, "no-such-board");
    strictEqual(readBoardSkinId(), "classic-wood");
    // Back to Classic Pine clears the key.
    writeBoardSkinId("classic-wood");
    strictEqual(store.has(BOARD_SETTING_KEY), false);
    // A store that throws on every call.
    g.localStorage = {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("blocked");
      },
      removeItem: () => {
        throw new Error("blocked");
      },
    };
    strictEqual(readBoardSkinId(), "classic-wood");
    writeBoardSkinId("heritage");
  } finally {
    delete g.localStorage;
  }
});
check("board: lanes by seat order, never 'me first'", () => {
  strictEqual(laneOf(["a", "b"], "a"), 0);
  strictEqual(laneOf(["a", "b"], "b"), 1);
  strictEqual(laneOf(["a", "b", "c"], "c"), 2);
  strictEqual(laneOf(["a", "b", "c", "d"], "d"), null);
  strictEqual(laneOf(["a", "b"], "x"), null);
});
check("board: pegs -- front on the score, back on the score before the last award, leapfrogging", () => {
  // A new game: both on the start holes.
  deepStrictEqual(nextPegs(null, 0, null), [0, 0]);
  // First award (+2): one peg moves, the other stays on the start.
  const p1 = nextPegs([0, 0], 2, 2);
  deepStrictEqual(p1, [0, 2]);
  // +3: the back peg jumps over the front one.
  const p2 = nextPegs(p1, 5, 3);
  deepStrictEqual(p2, [5, 2]);
  // A 0 count (hand: nothing): nothing moves.
  deepStrictEqual(nextPegs(p2, 5, 0), p2);
  // Settled: the same scores again give the same pegs.
  deepStrictEqual(nextPegs(p2, 5, 3), p2);
  // A reload: the back peg from the last award alone.
  deepStrictEqual(nextPegs(null, 19, 2), [17, 19]);
  // A reload after a 0 award: the back peg can't be known -- the start hole.
  deepStrictEqual(nextPegs(null, 19, 0), [0, 19]);
  // The win: the front in the game hole, however far past 121 (the peg on
  // 118 stays, the one on 115 jumps).
  deepStrictEqual(nextPegs([118, 115], 124, 6), [118, 121]);
  // A new game after it: both back on the start.
  deepStrictEqual(nextPegs([121, 118], 0, null), [0, 0]);
  // Negative or odd data never puts the back peg ahead of the front.
  deepStrictEqual(nextPegs(null, 10, -4), [0, 10]);
});

// THE DEALING ANIMATION (lib/dealAnimation.ts).
type Plan = ReturnType<typeof dealPlan>;
const dealTargets = (plan: Plan) => plan.deal.map((s) => s.target);
const dealCounts = (plan: Plan) =>
  plan.deal.reduce<Record<string, number>>((c, s) => ({ ...c, [String(s.target)]: (c[String(s.target)] ?? 0) + 1 }), {});
const increasing = (steps: { delayMs: number }[], what: string) => {
  for (let i = 1; i < steps.length; i++) strictEqual(steps[i].delayMs > steps[i - 1].delayMs, true, `${what} ${i}`);
};
const checkTiming = (plan: Plan) => {
  increasing(plan.deal, "deal delay");
  increasing(plan.fan, "fan delay");
  strictEqual(plan.deal[0].delayMs, 0);
  strictEqual(plan.dealMs <= DEAL_TOTAL_MS + 0.01, true, `deal ${plan.dealMs}`);
  strictEqual(dealLength(plan.deal), plan.dealMs);
  // The fan starts when the last card is down and keeps to its own cap.
  if (plan.fan.length) {
    strictEqual(plan.fan[0].delayMs, plan.dealMs);
    strictEqual(dealLength(plan.fan) <= plan.dealMs + FAN_TOTAL_MS + 0.01, true, `fan ${dealLength(plan.fan)}`);
    strictEqual(plan.totalMs, plan.dealMs + FAN_TOTAL_MS);
  } else {
    strictEqual(plan.totalMs, plan.dealMs);
  }
};
check("deal: 2 seats -- the dealer's opponent first, alternating, 6 each; my 6 stack, then fan", () => {
  const fromSeat0 = dealPlan({ seatCount: 2, dealerIndex: 0, cardsPerSeat: 6, stackSeat: 0 });
  deepStrictEqual(dealTargets(fromSeat0), [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0]);
  const fromSeat1 = dealPlan({ seatCount: 2, dealerIndex: 1, cardsPerSeat: 6, stackSeat: 0 });
  deepStrictEqual(dealTargets(fromSeat1), [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]);
  deepStrictEqual(dealCounts(fromSeat0), { 0: 6, 1: 6 });
  // Each seat's cards numbered 0..5 in the order they arrive.
  deepStrictEqual(fromSeat0.deal.filter((s) => s.target === 1).map((s) => s.cardIndex), [0, 1, 2, 3, 4, 5]);
  // Only my seat stacks (and fans).
  deepStrictEqual(fromSeat0.deal.filter((s) => s.stack).map((s) => s.target), [0, 0, 0, 0, 0, 0]);
  deepStrictEqual(fromSeat0.fan.map((f) => f.cardIndex), [0, 1, 2, 3, 4, 5]);
  checkTiming(fromSeat0);
  checkTiming(fromSeat1);
  // 450ms flights, the last landing at 3000: 11 gaps of 231.8ms; the fan
  // runs 3000-4000, each card 600ms, 80ms apart.
  strictEqual(fromSeat0.deal[0].durationMs, DEAL_CARD_MS);
  strictEqual(Math.abs(fromSeat0.deal[1].delayMs - 2550 / 11) < 0.001, true);
  strictEqual(Math.abs(fromSeat0.dealMs - 3000) < 0.01, true);
  strictEqual(Math.abs(fromSeat0.fan[0].delayMs - 3000) < 0.01, true);
  strictEqual(Math.abs(fromSeat0.fan[1].delayMs - fromSeat0.fan[0].delayMs - 80) < 0.01, true);
  strictEqual(Math.abs(fromSeat0.totalMs - 4000) < 0.01, true);
});
check("deal: no stack seat (a spectator) -- no stack, no fan", () => {
  const plan = dealPlan({ seatCount: 2, dealerIndex: 0, cardsPerSeat: 6 });
  strictEqual(plan.deal.some((s) => s.stack), false);
  deepStrictEqual(plan.fan, []);
  checkTiming(plan);
});
check("deal: 3 seats -- clockwise from the dealer's left, 5 each, then one to the crib", () => {
  const plan = dealPlan({ seatCount: 3, dealerIndex: 1, cardsPerSeat: 5, cribExtras: 1, stackSeat: 2 });
  deepStrictEqual(dealTargets(plan).slice(0, 6), [2, 0, 1, 2, 0, 1]);
  deepStrictEqual(plan.deal[plan.deal.length - 1].target, "crib");
  deepStrictEqual(dealCounts(plan), { 0: 5, 1: 5, 2: 5, crib: 1 });
  strictEqual(plan.deal.length, 16);
  // The crib's card never stacks; only seat 2's five do.
  deepStrictEqual(plan.deal.filter((s) => s.stack).length, 5);
  strictEqual(plan.fan.length, 5);
  checkTiming(plan);
});
check("deal: 4 seats -- 20 cards clockwise from the dealer's left, my 5 stack then fan, 380ms flights", () => {
  strictEqual(dealCardMsFor(2), DEAL_CARD_MS);
  strictEqual(dealCardMsFor(3), DEAL_CARD_MS);
  strictEqual(dealCardMsFor(4), DEAL_CARD_MS_FOUR);
  // Seats a, b, c, d; I am a (stack seat 0): b left, c top, d right.
  for (const [dealerIndex, firstFour] of [
    [0, [1, 2, 3, 0]], // I deal: left, top, right, me
    [1, [2, 3, 0, 1]], // left deals: top first
    [2, [3, 0, 1, 2]], // top deals: right first
    [3, [0, 1, 2, 3]], // right deals: me first
  ] as const) {
    const plan = dealPlan({ seatCount: 4, dealerIndex, cardsPerSeat: 5, cribExtras: cribCountDuringDiscard(4, 0), stackSeat: 0 });
    strictEqual(plan.deal.length, 20);
    deepStrictEqual(dealTargets(plan).slice(0, 4), [...firstFour], `dealer ${dealerIndex}`);
    deepStrictEqual(dealCounts(plan), { 0: 5, 1: 5, 2: 5, 3: 5 });
    deepStrictEqual(plan.deal.filter((s) => s.stack).map((s) => s.target), [0, 0, 0, 0, 0]);
    strictEqual(plan.fan.length, 5);
    strictEqual(plan.deal[0].durationMs, 380);
    // 19 gaps of (3000 - 380) / 19 = ~137.9ms; the last lands at 3000.
    strictEqual(Math.abs(plan.deal[1].delayMs - 2620 / 19) < 0.001, true);
    strictEqual(Math.abs(plan.dealMs - 3000) < 0.01, true);
    checkTiming(plan);
  }
});
check("deal: 3 seats, the dealer at each of my bottom/left/right -- clockwise from the dealer's left, then the crib card", () => {
  // Seats in order a, b, c; I am a (stack seat 0). On my screen b is left, c right.
  for (const [dealerIndex, firstThree] of [
    [0, [1, 2, 0]], // I deal: left (b) first, then right (c), then me
    [1, [2, 0, 1]], // left (b) deals: right (c) first, then me
    [2, [0, 1, 2]], // right (c) deals: me first
  ] as const) {
    const plan = dealPlan({ seatCount: 3, dealerIndex, cardsPerSeat: 5, cribExtras: 1, stackSeat: 0 });
    deepStrictEqual(dealTargets(plan).slice(0, 3), [...firstThree], `dealer ${dealerIndex}`);
    strictEqual(plan.deal.at(-1)!.target, "crib");
    deepStrictEqual(plan.deal.filter((s) => s.stack).map((s) => s.target), [0, 0, 0, 0, 0]);
    strictEqual(plan.fan.length, 5);
    checkTiming(plan);
  }
});
check("deal: a flying card's turn -- a half turn, plus a quarter between upright and sideways places", () => {
  // Upright to upright: the 2-player table's -180 -> 0, unchanged.
  strictEqual(flightTurn(0, 0), -180);
  // The left dealer's sideways deck (90) to my hand (0), to the right seat (-90), to the left seat (90).
  strictEqual(flightTurn(90, 0), -270);
  strictEqual(flightTurn(90, -90), -270);
  strictEqual(flightTurn(90, 90), -90);
  // My deck (0) to a side seat: lands sideways.
  strictEqual(flightTurn(0, 90), -180);
  strictEqual(flightTurn(0, -90), -360);
  for (const from of [0, 90, -90, 180]) {
    for (const to of [0, 90, -90]) {
      const start = flightTurn(from, to);
      // Starts lined up with where it leaves (a back looks the same either way up) ...
      strictEqual((((start - from) % 180) + 180) % 180, 0, `${from} -> ${to}`);
      // ... and turns at least half a turn, at most three quarters, to land at `to`.
      const spin = to - start;
      strictEqual(spin === 180 || spin === 270, true, `${from} -> ${to}: ${spin}`);
    }
  }
});
check("discard toss: 3 players, one card each, seat after seat", () => {
  const steps = discardPlan([
    { seat: "left", cards: 1 },
    { seat: "right", cards: 1 },
    { seat: "bottom", cards: 1 },
  ]);
  deepStrictEqual(steps.map((s) => [s.seat, s.cardIndex, s.delayMs]), [
    ["left", 0, 0],
    ["right", 0, TOSS_STAGGER_MS],
    ["bottom", 0, 2 * TOSS_STAGGER_MS],
  ]);
});
check("deal: 4 seats -- 5 each, 20 cards still within the cap", () => {
  const plan = dealPlan({ seatCount: 4, dealerIndex: 3, cardsPerSeat: 5, stackSeat: 1 });
  deepStrictEqual(dealTargets(plan).slice(0, 5), [0, 1, 2, 3, 0]);
  deepStrictEqual(dealCounts(plan), { 0: 5, 1: 5, 2: 5, 3: 5 });
  checkTiming(plan);
  strictEqual(Math.abs(plan.dealMs - DEAL_TOTAL_MS) < 0.01, true);
  strictEqual(plan.deal[1].delayMs < plan.deal[1].durationMs, true); // overlapping in the air
});
check("deal: odd inputs -- a wrapped dealer index, no seats, a custom cap", () => {
  deepStrictEqual(dealTargets(dealPlan({ seatCount: 2, dealerIndex: 3, cardsPerSeat: 1 })), [0, 1]);
  deepStrictEqual(dealTargets(dealPlan({ seatCount: 2, dealerIndex: -1, cardsPerSeat: 1 })), [0, 1]);
  deepStrictEqual(dealPlan({ seatCount: 0, dealerIndex: 0, cardsPerSeat: 6 }), { deal: [], fan: [], dealMs: 0, totalMs: 0 });
  const fast = dealPlan({ seatCount: 2, dealerIndex: 0, cardsPerSeat: 6, totalMs: 1000 });
  strictEqual(fast.dealMs <= 1000, true);
  strictEqual(fast.deal.length, 12);
});

// THE DISCARD TOSS.
check("toss: one seat's two cards, then several seats in order, staggered", () => {
  const mine = discardPlan([{ seat: "me", cards: 2 }]);
  deepStrictEqual(
    mine.map((s) => [s.seat, s.cardIndex, s.delayMs, s.durationMs]),
    [["me", 0, 0, TOSS_CARD_MS], ["me", 1, TOSS_STAGGER_MS, TOSS_CARD_MS]]
  );
  const three = discardPlan([{ seat: 2, cards: 1 }, { seat: 0, cards: 1 }, { seat: 1, cards: 1 }]);
  deepStrictEqual(three.map((s) => s.seat), [2, 0, 1]);
  increasing(three, "toss delay");
  const four = discardPlan([{ seat: "a", cards: 1 }, { seat: "b", cards: 1 }, { seat: "c", cards: 1 }, { seat: "d", cards: 1 }]);
  strictEqual(four.length, 4);
  increasing(four, "toss delay");
  deepStrictEqual(discardPlan([]), []);
  deepStrictEqual(discardPlan([{ seat: "x", cards: 0 }]), []);
});

// A LIVE DISCARD: a screen's renders, as liveDiscardStep sees them.
type DiscardFrame = { tableRead?: boolean; hand: string | null; by: string[]; dealing?: boolean; on?: boolean };
const discardsThrown = (frames: DiscardFrame[]) => {
  let seen: Parameters<typeof liveDiscardStep>[0]["seen"] = undefined;
  const thrown: string[][] = [];
  for (const f of frames) {
    const step = liveDiscardStep({
      tableRead: f.tableRead ?? true,
      seen,
      handKey: f.hand,
      discardedBy: f.by,
      dealInFlight: f.dealing ?? false,
      animationOn: f.on ?? true,
    });
    if (step.live.length) thrown.push(step.live);
    seen = step.seen;
  }
  return thrown;
};
check("live discard: a reload, a late join or a hand past the discard throws nothing", () => {
  deepStrictEqual(discardsThrown([{ tableRead: false, hand: null, by: [] }, { hand: "g:3", by: ["op"] }, { hand: "g:3", by: ["op"] }]), []);
  deepStrictEqual(discardsThrown([{ hand: "g:3", by: ["me", "op"] }, { hand: "g:3", by: ["me", "op"] }]), []);
  // A new hand that turns up with discards already in it (missed while away).
  deepStrictEqual(discardsThrown([{ hand: "g:3", by: [] }, { hand: "g:4", by: ["op"] }]), []);
});
check("live discard: each discard seen live is thrown once, echoes or not", () => {
  deepStrictEqual(
    discardsThrown([{ hand: "g:3", by: [] }, { hand: "g:3", by: ["op"] }, { hand: "g:3", by: ["op"] }, { hand: "g:3", by: ["op", "me"] }]),
    [["op"], ["me"]]
  );
  // Next hand: its discards are live again.
  deepStrictEqual(
    discardsThrown([{ hand: "g:3", by: ["op", "me"] }, { hand: "g:4", by: [] }, { hand: "g:4", by: ["op"] }]),
    [["op"]]
  );
});
check("live discard: not while a deal is shown, not with the animations off -- and never later", () => {
  deepStrictEqual(
    discardsThrown([{ hand: "g:3", by: [] }, { hand: "g:3", by: ["op"], dealing: true }, { hand: "g:3", by: ["op"] }]),
    []
  );
  deepStrictEqual(discardsThrown([{ hand: "g:3", by: [] }, { hand: "g:3", by: ["op"], on: false }, { hand: "g:3", by: ["op"] }]), []);
});

// A LIVE DEAL: a screen's renders, one after another, as liveDealStep sees
// them. Returns the hands it would animate.
type DealFrame = { tableRead?: boolean; hand: string | null; phase?: string; discarded?: boolean; on?: boolean };
const dealsAnimated = (frames: DealFrame[]) => {
  let seenKey: string | null | undefined = undefined;
  const live: string[] = [];
  for (const f of frames) {
    const step = liveDealStep({
      tableRead: f.tableRead ?? true,
      seenKey,
      handKey: f.hand,
      phase: f.phase ?? "discard",
      iHaveDiscarded: f.discarded ?? false,
      animationOn: f.on ?? true,
    });
    if (step.liveKey) live.push(step.liveKey);
    seenKey = step.seenKey;
  }
  return live;
};
check("live deal: a load, reload or late join mid-hand never animates", () => {
  // Loading straight into a freshly dealt hand (a reload right after the deal).
  deepStrictEqual(dealsAnimated([{ tableRead: false, hand: null }, { hand: "g:3" }, { hand: "g:3" }]), []);
  // The hand before the first read is in: still not live.
  deepStrictEqual(dealsAnimated([{ tableRead: false, hand: "g:3" }, { hand: "g:3" }]), []);
  // A late join in pegging, then counting.
  deepStrictEqual(dealsAnimated([{ hand: "g:3", phase: "play" }, { hand: "g:3", phase: "counting" }]), []);
});
check("live deal: Next Hand, the first hand after the cut, New Game -- once each", () => {
  // Next Hand while watching, with realtime echoes of the same row.
  deepStrictEqual(
    dealsAnimated([{ hand: "g:3", phase: "done" }, { hand: "g:4" }, { hand: "g:4" }, { hand: "g:4", discarded: true }]),
    ["g:4"]
  );
  // The cut (no dealt hand) then the deal.
  deepStrictEqual(dealsAnimated([{ hand: null }, { hand: null }, { hand: "g:1" }]), ["g:1"]);
  // A won game's board (no hand), then New Game.
  deepStrictEqual(dealsAnimated([{ hand: "g:9", phase: "done" }, { hand: null }, { hand: "h:1" }]), ["h:1"]);
});
check("live deal: not once I've discarded, not past the discard, not with the animation off", () => {
  deepStrictEqual(dealsAnimated([{ hand: "g:3", phase: "done" }, { hand: "g:4", discarded: true }]), []);
  deepStrictEqual(dealsAnimated([{ hand: "g:3", phase: "done" }, { hand: "g:4", phase: "play" }]), []);
  deepStrictEqual(dealsAnimated([{ hand: "g:3", phase: "done" }, { hand: "g:4", on: false }, { hand: "g:4" }]), []);
});

// THE STARTER IN COUNTING: keyed on the dealer's seat, any table size.
check("starter in counting: my crib above my hand; any other dealer's in the middle", () => {
  strictEqual(countingStarterPlace("bottom", true), "above-hand");
  strictEqual(countingStarterPlace("left", true), "middle");
  strictEqual(countingStarterPlace("top", true), "middle");
  strictEqual(countingStarterPlace("right", true), "middle");
});
check("starter outside counting (or no dealer): on the deck", () => {
  for (const p of ["bottom", "left", "top", "right"] as const) strictEqual(countingStarterPlace(p, false), "deck");
  strictEqual(countingStarterPlace(null, true), "deck");
});
check("starter in counting: each table size's dealer seats", () => {
  // 2 players: me or across; 3: me, left, right (from every viewpoint).
  strictEqual(countingStarterPlace(seatPositionOf(["a", "b"], "a", "b"), true), "middle");
  strictEqual(countingStarterPlace(seatPositionOf(["a", "b"], "a", "a"), true), "above-hand");
  for (const me of ["a", "b", "c"]) {
    for (const dealer of ["a", "b", "c"]) {
      strictEqual(
        countingStarterPlace(seatPositionOf(["a", "b", "c"], me, dealer), true),
        dealer === me ? "above-hand" : "middle"
      );
    }
  }
});

// The starter's slide: only when this screen sees counting begin.
const startersSlid = (steps: { tableRead?: boolean; hand: string | null; counting?: boolean; on?: boolean }[]) => {
  let seenKey: string | null | undefined = undefined;
  const live: string[] = [];
  for (const s of steps) {
    const step = liveStarterStep({
      tableRead: s.tableRead ?? true,
      seenKey,
      handKey: s.hand,
      counting: s.counting ?? false,
      animationOn: s.on ?? true,
    });
    if (step.liveKey) live.push(step.liveKey);
    seenKey = step.seenKey;
  }
  return live;
};
check("starter slide: pegging then counting, once (echoes don't replay it)", () => {
  deepStrictEqual(
    startersSlid([{ hand: "g:3" }, { hand: "g:3" }, { hand: "g:3", counting: true }, { hand: "g:3", counting: true }]),
    ["g:3"]
  );
  // Then the next hand's counting too.
  deepStrictEqual(
    startersSlid([{ hand: "g:3" }, { hand: "g:3", counting: true }, { hand: "g:4" }, { hand: "g:4", counting: true }]),
    ["g:3", "g:4"]
  );
});
check("starter slide: never on a load, reload or late join in counting, nor with the animations off", () => {
  deepStrictEqual(startersSlid([{ tableRead: false, hand: null }, { hand: "g:3", counting: true }]), []);
  deepStrictEqual(startersSlid([{ tableRead: false, hand: "g:3" }, { hand: "g:3", counting: true }]), []);
  deepStrictEqual(startersSlid([{ hand: "g:3" }, { hand: "g:3", counting: true, on: false }]), []);
  // A hand first seen in counting (Next Hand dealt while away, then counting):
  // only a change seen within one hand counts.
  deepStrictEqual(startersSlid([{ hand: "g:3", counting: true }, { hand: "g:4", counting: true }]), []);
  // A won game (no hand on show) is never a slide.
  deepStrictEqual(startersSlid([{ hand: "g:3" }, { hand: null }]), []);
});

// THE COMPUTER'S DISCARD, SHOWN ON TIME.
type ShowInput = Parameters<typeof discardShowStep>[0];
const showBase: ShowInput = {
  eligible: true,
  handKey: "g:3",
  phase: "discard",
  handShown: true,
  dealInFlight: false,
  computerDiscarded: false,
  iDiscarding: false,
  remembered: false,
  state: null,
  now: 1000,
};
// Runs the steps in time order; a due timer fires before the next step.
const runShow = (steps: Partial<ShowInput>[]) => {
  let state: DiscardShow = null;
  let due: number | null = null;
  const shown: boolean[] = [];
  for (const s of steps) {
    const input = { ...showBase, ...s, state };
    if (due !== null && input.now >= due) state = fireDiscardShow(state, input.handKey as string);
    const step = discardShowStep({ ...input, state });
    state = step.state;
    due = step.fireInMs === null ? null : input.now + step.fireInMs;
    shown.push(discardShown({ ...input, state }));
  }
  return { state, shown };
};
check("computer discard shown: 7 s after my hand shows, not before", () => {
  strictEqual(COMPUTER_DISCARD_SHOW_MS, 7000);
  const first = discardShowStep(showBase);
  strictEqual(first.fireInMs, 7000);
  // Not yet at 6.9 s; shown from 7 s.
  deepStrictEqual(runShow([{ now: 1000 }, { now: 7900 }, { now: 8000 }, { now: 9000 }]).shown, [false, false, true, true]);
});
check("computer discard shown: the clock starts when the hand first appears, the deal included", () => {
  // The deal starts at 1000 and takes 4 s: shown at 8000, 3 s after it ends.
  deepStrictEqual(
    runShow([{ now: 1000, dealInFlight: true }, { now: 5000 }, { now: 7900 }, { now: 8000 }]).shown,
    [false, false, false, true]
  );
  // Nothing before the hand is here; then 7 s from its arrival (a reload or
  // late join: from when it shows on this load).
  deepStrictEqual(
    runShow([{ now: 0, handShown: false }, { now: 2000 }, { now: 8900 }, { now: 9000 }]).shown,
    [false, false, false, true]
  );
  // Started, it keeps counting even if the hand is briefly not reported.
  deepStrictEqual(runShow([{ now: 1000 }, { now: 3000, handShown: false }, { now: 8000 }]).shown, [false, false, true]);
});
check("computer discard shown: never while a deal is still shown -- then as it ends", () => {
  // A 9 s deal (longer than 7 s): due at 8000, held until the deal ends at 10000.
  const r = runShow([{ now: 1000, dealInFlight: true }, { now: 8000, dealInFlight: true }, { now: 9000, dealInFlight: true }]);
  deepStrictEqual(r.shown, [false, false, false]);
  strictEqual(discardShowStep({ ...showBase, state: r.state, dealInFlight: true, now: 9500 }).fireInMs, null);
  // The deal ends: due already, so at once.
  strictEqual(discardShowStep({ ...showBase, state: r.state, now: 10000 }).fireInMs, 0);
});
check("computer discard shown: my discard first cancels it for the hand", () => {
  const r = runShow([{ now: 1000 }, { now: 4000, iDiscarding: true }, { now: 9000, iDiscarding: true }]);
  deepStrictEqual(r.shown, [false, false, false]);
  strictEqual(r.state?.cancelled, true);
  // Even if my discard were refused, it doesn't come back this hand.
  deepStrictEqual(runShow([{ now: 1000 }, { now: 4000, iDiscarding: true }, { now: 9000 }, { now: 20000 }]).shown, [
    false,
    false,
    false,
    false,
  ]);
});
check("computer discard shown: the real discard before 7 s -- nothing to show", () => {
  deepStrictEqual(runShow([{ now: 1000 }, { now: 3000, computerDiscarded: true }, { now: 9000, computerDiscarded: true }]).shown, [
    false,
    false,
    false,
  ]);
});
check("computer discard shown: the real discard after it showed -- the real state takes over", () => {
  const r = runShow([{ now: 1000 }, { now: 8000 }, { now: 9000, computerDiscarded: true }]);
  deepStrictEqual(r.shown, [false, true, false]);
  // Still fired for the hand: nothing restarts.
  strictEqual(r.state?.fired, true);
  strictEqual(discardShowStep({ ...showBase, state: r.state, computerDiscarded: true, now: 20000 }).fireInMs, null);
});
check("computer discard shown: a reload after it showed shows it at once", () => {
  deepStrictEqual(runShow([{ now: 1000, remembered: true }]).shown, [true]);
  // Even before the hand is on screen (the deal never replays on a load).
  deepStrictEqual(runShow([{ now: 1000, remembered: true, handShown: false }]).shown, [true]);
});
check("computer discard shown: not across hands, not past the discard, not for anyone else", () => {
  // Shown in hand 3; hand 4 starts afresh.
  const r = runShow([{ now: 1000 }, { now: 8000 }, { now: 9000, handKey: "g:4" }]);
  deepStrictEqual(r.shown, [false, true, false]);
  strictEqual(r.state?.handKey, "g:4");
  strictEqual(r.state?.fired, false);
  deepStrictEqual(runShow([{ now: 1000, phase: "play" }, { now: 9000, phase: "play" }]).shown, [false, false]);
  // Not a computer opponent at a 2-player square table: never.
  deepStrictEqual(runShow([{ now: 1000, eligible: false }, { now: 9000, eligible: false }]).shown, [false, false]);
  strictEqual(discardShowStep({ ...showBase, eligible: false }).fireInMs, null);
});
check("computer discard shown: steady state returns the same object (render-safe)", () => {
  const a = discardShowStep(showBase).state;
  strictEqual(discardShowStep({ ...showBase, state: a, now: 3000 }).state, a);
  const fired = fireDiscardShow(a, "g:3");
  strictEqual(discardShowStep({ ...showBase, state: fired, now: 9000 }).state, fired);
  // A timer from an older hand does nothing.
  strictEqual(fireDiscardShow(a, "g:4"), a);
});
check("computer discard shown: its real discard is never thrown a second time", () => {
  const seen: DiscardSeen = { handKey: "g:3", ids: [] };
  const marked = markDiscardSeen(seen, "g:3", "cpu");
  deepStrictEqual(marked, { handKey: "g:3", ids: ["cpu"] });
  strictEqual(markDiscardSeen(marked, "g:3", "cpu"), marked);
  strictEqual(markDiscardSeen(seen, "g:4", "cpu"), seen);
  strictEqual(markDiscardSeen(undefined, "g:3", "cpu"), undefined);
  // The real discard arrives: nothing live.
  deepStrictEqual(
    liveDiscardStep({ tableRead: true, seen: marked, handKey: "g:3", discardedBy: ["cpu"], dealInFlight: false, animationOn: true })
      .live,
    []
  );
  // Unmarked, it would have been thrown.
  deepStrictEqual(
    liveDiscardStep({ tableRead: true, seen, handKey: "g:3", discardedBy: ["cpu"], dealInFlight: false, animationOn: true }).live,
    ["cpu"]
  );
});
check("crib pile: real + shown discards, each once, less what is flying", () => {
  const n = (input: Parameters<typeof shownCribIds>[0]) => cribCountDuringDiscard(2, shownCribIds(input).size);
  strictEqual(n({ discardedBy: [], mineSending: null, shownComputer: null, tossing: [] }), 0);
  // Shown: its 2 backs.
  strictEqual(n({ discardedBy: [], mineSending: null, shownComputer: "cpu", tossing: [] }), 2);
  // Still flying: not yet.
  strictEqual(n({ discardedBy: [], mineSending: null, shownComputer: "cpu", tossing: ["cpu"] }), 0);
  // The real one arrives: still 2, not 4.
  strictEqual(n({ discardedBy: ["cpu"], mineSending: null, shownComputer: "cpu", tossing: [] }), 2);
  // Mine too: 4.
  strictEqual(n({ discardedBy: ["cpu"], mineSending: "me", shownComputer: "cpu", tossing: [] }), 4);
  strictEqual(n({ discardedBy: ["me", "cpu"], mineSending: "me", shownComputer: null, tossing: [] }), 4);
});
check("computer discard shown: remembered per game and hand", () => {
  strictEqual(discardShowKey("g:3"), "nobs:cpu-discard-shown:g:3");
  strictEqual(discardShowKey("g:3") === discardShowKey("g:4"), false);
});

console.log(`All ${passed} Phase 3 helper checks passed.`);
