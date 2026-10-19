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

console.log(`All ${passed} Phase 3 helper checks passed.`);
