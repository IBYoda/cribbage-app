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
} from "../lib/boardLayout";
import {
  DEAL_CARD_MS,
  DEAL_TOTAL_MS,
  FAN_TOTAL_MS,
  TOSS_CARD_MS,
  TOSS_STAGGER_MS,
  dealLength,
  dealPlan,
  discardPlan,
  liveDealStep,
  liveDiscardStep,
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

// WHICH LAYOUT (chooseTableLayout): square by default for 2 players, not
// Muggins, on its screens; ?layout=classic is the way out.
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
check("layout: 3 and 4 players, and Muggins, are classic with or without the param", () => {
  for (const param of [null, "square", "classic", "x"]) {
    for (const s of [...SQUARE_SCREENS, ...CLASSIC_SCREENS]) {
      strictEqual(layoutFor(param, 3, false, s), "classic", `3p ${param} ${s}`);
      strictEqual(layoutFor(param, 4, false, s), "classic", `4p ${param} ${s}`);
      strictEqual(layoutFor(param, 2, true, s), "classic", `muggins ${param} ${s}`);
    }
  }
  strictEqual(isSquareTable({ layoutParam: null, playerCount: 2, isMuggins: false }), true);
  strictEqual(isSquareTable({ layoutParam: "classic", playerCount: 2, isMuggins: false }), false);
  strictEqual(isSquareTable({ layoutParam: null, playerCount: 4, isMuggins: false }), false);
  strictEqual(isSquareTable({ layoutParam: null, playerCount: 2, isMuggins: true }), false);
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

console.log(`All ${passed} Phase 3 helper checks passed.`);
