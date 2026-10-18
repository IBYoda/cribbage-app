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
import {
  buildPlates,
  cardsLeft,
  cribCountDuringDiscard,
  handSizes,
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

console.log(`All ${passed} Phase 3 helper checks passed.`);
