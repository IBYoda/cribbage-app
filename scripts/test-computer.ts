// Tests for the computer opponent's brain (lib/computer). Zero dependencies,
// like scripts/test-phase3.ts. Part of `npm run test:quick`, and alone:
//
//   npm run test:computer
//
// which wraps `node --import ./scripts/ts-resolve.mjs scripts/test-computer.ts`.
//
// Every random choice goes through a seeded generator, so every run is the
// same run.

import { deepStrictEqual, ok, strictEqual, throws } from "node:assert";
import { cardPlayValue } from "../lib/cards";
import { scoreHand, scorePegging } from "../lib/scoring";

const scoreHandPoints = (hand: string[], starter: string) => scoreHand(hand, starter, false).points;
import {
  FULL_DECK,
  decideDiscard,
  decidePlay,
  evaluateDiscards,
  evaluatePlays,
  legalPlays,
  seededRng,
  type PlayInput,
} from "../lib/computer/brain";
import { LEVELS, type ComputerLevel } from "../lib/computer/config";

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

const LEVEL_NAMES: ComputerLevel[] = ["easy", "medium", "hard"];

function shuffled(rng: () => number) {
  const deck = [...FULL_DECK];
  for (let i = deck.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [deck[i], deck[j]] = [deck[j], deck[i]];
  }
  return deck;
}

const same = (a: string[], b: string[]) => [...a].sort().join() === [...b].sort().join();

// ---- Levels -------------------------------------------------------------------
check("levels: the three settings as specified", () => {
  deepStrictEqual(LEVELS, {
    easy: { mistakeRate: 0.55, peek: false, peekDiscard: false, search: false, cribSamples: 60 },
    medium: { mistakeRate: 0, peek: false, peekDiscard: false, search: false, cribSamples: 60 },
    hard: { mistakeRate: 0, peek: true, peekDiscard: true, search: true, cribSamples: 500 },
  });
});

// ---- legalPlays ---------------------------------------------------------------
check("legalPlays: held cards that keep the count at 31 or under", () => {
  deepStrictEqual(legalPlays(["5S", "TD", "KC", "AH"], ["TD"], 25), ["5S", "AH"]);
  deepStrictEqual(legalPlays(["5S", "TD", "KC", "AH"], [], 0), ["5S", "TD", "KC", "AH"]);
  deepStrictEqual(legalPlays(["5S", "TD"], [], 30), []);
  deepStrictEqual(legalPlays(["AH"], [], 30), ["AH"]);
  deepStrictEqual(legalPlays(["AH"], ["AH"], 0), []);
});

// ---- decideDiscard ------------------------------------------------------------
check("discard: 5-5-5-J is kept, dealer or not", () => {
  for (const isDealer of [true, false]) {
    for (let seed = 1; seed <= 5; seed++) {
      const out = decideDiscard({ hand: ["5S", "5H", "5D", "JC", "2S", "9C"], isDealer, level: "hard", rng: seededRng(seed) });
      ok(same(out, ["2S", "9C"]), `isDealer=${isDealer} seed=${seed}: discarded ${out}`);
    }
  }
});
check("discard: a pair of fives is never thrown (5-5-10-J)", () => {
  for (const isDealer of [true, false]) {
    for (let seed = 1; seed <= 5; seed++) {
      const out = decideDiscard({ hand: ["5S", "5H", "TD", "JC", "2S", "8C"], isDealer, level: "hard", rng: seededRng(seed) });
      ok(!out.includes("5S") && !out.includes("5H"), `isDealer=${isDealer} seed=${seed}: discarded ${out}`);
    }
  }
});
check("discard: always two different cards from the hand (500 random hands x 3 levels)", () => {
  const rng = seededRng(42);
  for (let t = 0; t < 500; t++) {
    const hand = shuffled(rng).slice(0, 6);
    for (const level of LEVEL_NAMES) {
      const out = decideDiscard({ hand, isDealer: t % 2 === 0, level, rng });
      strictEqual(out.length, 2);
      ok(out[0] !== out[1], `two equal cards: ${out}`);
      ok(hand.includes(out[0]) && hand.includes(out[1]), `not from the hand: ${out} / ${hand}`);
    }
  }
});
check("discard: the 15 options, keep + discard = the hand", () => {
  const hand = ["AS", "4D", "7H", "9C", "QS", "KD"];
  const options = evaluateDiscards({ hand, isDealer: true, level: "hard", rng: seededRng(3) });
  strictEqual(options.length, 15);
  for (const o of options) ok(same([...o.keep, ...o.discard], hand));
  strictEqual(new Set(options.map((o) => o.discard.join())).size, 15);
});
check("discard: hard never errs -- always the top option, and the same for the same seed", () => {
  const rng = seededRng(7);
  for (let t = 0; t < 200; t++) {
    const hand = shuffled(rng).slice(0, 6);
    const seed = 1000 + t;
    const best = evaluateDiscards({ hand, isDealer: t % 2 === 1, level: "hard", rng: seededRng(seed) })[0].discard;
    const a = decideDiscard({ hand, isDealer: t % 2 === 1, level: "hard", rng: seededRng(seed) });
    const b = decideDiscard({ hand, isDealer: t % 2 === 1, level: "hard", rng: seededRng(seed) });
    deepStrictEqual(a, best);
    deepStrictEqual(b, a);
  }
});
check("discard: medium never errs -- always the top discard, and the same for the same seed", () => {
  const rng = seededRng(11);
  const hands = Array.from({ length: 400 }, () => shuffled(rng).slice(0, 6));
  hands.forEach((hand, t) => {
    const seed = 5000 + t;
    const isDealer = t % 2 === 0;
    const best = evaluateDiscards({ hand, isDealer, level: "medium", rng: seededRng(seed) })[0].discard;
    const out = decideDiscard({ hand, isDealer, level: "medium", rng: seededRng(seed) });
    deepStrictEqual(out, best, `t=${t}`);
    deepStrictEqual(decideDiscard({ hand, isDealer, level: "medium", rng: seededRng(seed) }), out);
  });
});
check("discard: refuses anything but six different cards", () => {
  throws(() => decideDiscard({ hand: ["AS", "2S", "3S", "4S", "5S"], isDealer: true, level: "hard" }), /six/);
  throws(() => decideDiscard({ hand: ["AS", "AS", "3S", "4S", "5S", "6S"], isDealer: true, level: "hard" }), /twice/);
  throws(() => decideDiscard({ hand: ["AS", "ZZ", "3S", "4S", "5S", "6S"], isDealer: true, level: "hard" }), /not a card/);
});

// ---- decidePlay ---------------------------------------------------------------
const base = (over: Partial<PlayInput>): PlayInput => ({
  myRemaining: [],
  starter: "2C",
  segmentCards: [],
  count: 0,
  allPlayed: [],
  opponentCardCount: 4,
  level: "hard",
  rng: seededRng(1),
  ...over,
});

check("play: takes an available 31", () => {
  const out = decidePlay(base({ myRemaining: ["TD", "AS"], segmentCards: ["KS", "8H", "3D"], allPlayed: ["KS", "8H", "3D"], count: 21, opponentCardCount: 2 }));
  strictEqual(out, "TD");
});
check("play: takes an available 15 over a card that scores nothing", () => {
  const out = decidePlay(base({ myRemaining: ["9C", "5S"], segmentCards: ["TD"], allPlayed: ["TD"], count: 10, opponentCardCount: 3 }));
  strictEqual(out, "5S");
});
check("play: does not lead a 5 when it can avoid it", () => {
  for (const hand of [["5S", "4C", "9D", "KH"], ["5S", "5H", "TC", "JD"], ["5D", "8C"]]) {
    const out = decidePlay(base({ myRemaining: hand }));
    ok(out[0] !== "5", `led ${out} from ${hand}`);
  }
  // With nothing else, it leads the 5.
  strictEqual(decidePlay(base({ myRemaining: ["5D"] })), "5D");
});
check("play: with peek, hard avoids handing the opponent a 15 when an equal card exists", () => {
  // Leading 7 or 9 scores nothing, and blind they look equally risky (four
  // 8s and three 7s against four 6s and three 9s), so the tie-break plays the
  // higher 9 -- but the opponent holds a 6, which makes 15 on a 9.
  const scene = base({ myRemaining: ["7S", "9D"], opponentCardCount: 2 });
  strictEqual(decidePlay(scene), "9D");
  strictEqual(decidePlay({ ...scene, opponentRemaining: ["6H", "KD"] }), "7S");
  const peeked = evaluatePlays({ ...scene, opponentRemaining: ["6H", "KD"] });
  strictEqual(peeked.find((o) => o.card === "9D")?.risk, 2);
  strictEqual(peeked.find((o) => o.card === "7S")?.risk, 0);
});
check("play: easy ignores opponentRemaining (same seed, same card)", () => {
  const rng = seededRng(99);
  for (let t = 0; t < 300; t++) {
    const deck = shuffled(rng);
    const mine = deck.slice(0, 4);
    const theirs = deck.slice(4, 8);
    for (const level of ["easy"] as const) {
      const scene: PlayInput = { myRemaining: mine, starter: deck[8], segmentCards: [], count: 0, allPlayed: [], opponentCardCount: 4, level };
      const blind = decidePlay({ ...scene, rng: seededRng(t) });
      const shown = decidePlay({ ...scene, rng: seededRng(t), opponentRemaining: theirs });
      strictEqual(shown, blind, `${level} t=${t}`);
      deepStrictEqual(evaluatePlays({ ...scene, opponentRemaining: theirs }), evaluatePlays(scene));
    }
  }
});
check("play: no legal card is a clear error; a wrong count is refused", () => {
  throws(() => decidePlay(base({ myRemaining: ["KD"], segmentCards: ["TS", "TH", "5C"], allPlayed: ["TS", "TH", "5C"], count: 25 })), /no legal card/);
  throws(() => decidePlay(base({ myRemaining: ["AD"], segmentCards: ["TS"], allPlayed: ["TS"], count: 12 })), /does not match/);
});

// 1000 random scenarios from real deals: a random point in a random hand.
function randomScene(rng: () => number) {
  for (;;) {
    const deck = shuffled(rng);
    const mine = deck.slice(0, 4);
    const theirs = deck.slice(4, 8);
    const starter = deck[8];
    // Play some cards alternately at random, keeping each segment legal.
    const myLeft = [...mine];
    const theirLeft = [...theirs];
    const allPlayed: string[] = [];
    let segment: string[] = [];
    let count = 0;
    const steps = Math.floor(rng() * 7);
    for (let s = 0; s < steps; s++) {
      const pile = s % 2 === 0 ? theirLeft : myLeft;
      const legal = pile.filter((c) => count + cardPlayValue(c) <= 31);
      if (legal.length === 0) {
        segment = [];
        count = 0;
        continue;
      }
      const card = legal[Math.floor(rng() * legal.length)];
      pile.splice(pile.indexOf(card), 1);
      allPlayed.push(card);
      segment.push(card);
      count += cardPlayValue(card);
      if (count === 31) {
        segment = [];
        count = 0;
      }
    }
    if (legalPlays(myLeft, [], count).length === 0) continue;
    return { myRemaining: myLeft, theirLeft, starter, segmentCards: segment, count, allPlayed };
  }
}
check("play: 1000 random scenarios -- always a legal card from myRemaining, every level", () => {
  const rng = seededRng(2026);
  for (let t = 0; t < 1000; t++) {
    const s = randomScene(rng);
    // Every level, with and without the opponent's cards (with them, Hard
    // searches).
    for (const level of LEVEL_NAMES) {
      for (const shown of [true, false]) {
        const card = decidePlay({
          myRemaining: s.myRemaining,
          starter: s.starter,
          segmentCards: s.segmentCards,
          count: s.count,
          allPlayed: s.allPlayed,
          opponentCardCount: s.theirLeft.length,
          level,
          rng: seededRng(t),
          opponentRemaining: shown ? s.theirLeft : undefined,
        });
        ok(s.myRemaining.includes(card), `not held: ${card}`);
        ok(s.count + cardPlayValue(card) <= 31, `illegal: ${card} at ${s.count}`);
      }
    }
  }
});
check("deterministic: the same seed gives the same choices", () => {
  const run = () => {
    const rng = seededRng(314);
    const out: string[] = [];
    for (let t = 0; t < 50; t++) {
      const hand = shuffled(rng).slice(0, 6);
      out.push(decideDiscard({ hand, isDealer: t % 2 === 0, level: "medium", rng }).join());
      const s = randomScene(rng);
      out.push(decidePlay({ ...s, opponentCardCount: s.theirLeft.length, level: "easy", rng }));
    }
    return out;
  };
  deepStrictEqual(run(), run());
});

// ---- Easy: the original Medium with 55% mistakes ---------------------------------
check("easy deviates from the best discard at about its rate", () => {
  const rng = seededRng(11);
  const hands = Array.from({ length: 400 }, () => shuffled(rng).slice(0, 6));
  let deviations = 0;
  hands.forEach((hand, t) => {
    const seed = 5000 + t;
    const isDealer = t % 2 === 0;
    const best = evaluateDiscards({ hand, isDealer, level: "easy", rng: seededRng(seed) })[0].discard;
    const out = decideDiscard({ hand, isDealer, level: "easy", rng: seededRng(seed) });
    ok(out[0] !== out[1] && hand.includes(out[0]) && hand.includes(out[1]), `invalid: ${out}`);
    if (!same(out, best)) deviations++;
  });
  // Expected: mistakeRate x 14/15 (a random pick lands on the best 1 in 15).
  const rate = deviations / hands.length;
  console.log(`   easy discard: differs from the best ${rate.toFixed(3)} (expected ${(LEVELS.easy.mistakeRate * 14 / 15).toFixed(3)})`);
  ok(rate >= 0.4 && rate <= 0.62, `deviated ${rate.toFixed(3)}, expected 0.40-0.62`);
});
check("easy deviates from the best card at about its rate (2000 pegging scenes)", () => {
  const rng = seededRng(77);
  let deviations = 0;
  let expected = 0;
  const N = 2000;
  for (let t = 0; t < N; t++) {
    const s = randomScene(rng);
    const scene: PlayInput = {
      myRemaining: s.myRemaining,
      starter: s.starter,
      segmentCards: s.segmentCards,
      count: s.count,
      allPlayed: s.allPlayed,
      opponentCardCount: s.theirLeft.length,
      level: "easy",
    };
    const options = evaluatePlays(scene);
    if (decidePlay({ ...scene, rng: seededRng(t) }) !== options[0].card) deviations++;
    // A random pick lands on the best card 1 in (legal cards).
    expected += LEVELS.easy.mistakeRate * (1 - 1 / options.length);
  }
  const rate = deviations / N;
  const want = expected / N;
  console.log(`   easy play: differs from the best ${rate.toFixed(3)} (expected ${want.toFixed(3)})`);
  // About three standard errors over 2000 scenes.
  ok(Math.abs(rate - want) <= 0.035, `deviated ${rate.toFixed(3)}, expected ${want.toFixed(3)} +- 0.035`);
});
check("easy never searches and ignores opponentKept and the game state", () => {
  const rng = seededRng(222);
  for (let t = 0; t < 200; t++) {
    const s = randomScene(rng);
    const scene: PlayInput = {
      myRemaining: s.myRemaining,
      starter: s.starter,
      segmentCards: s.segmentCards,
      count: s.count,
      allPlayed: s.allPlayed,
      opponentCardCount: s.theirLeft.length,
      level: "easy",
      opponentRemaining: s.theirLeft,
    };
    // The one-move-ahead estimate from the unseen cards, whatever is passed.
    deepStrictEqual(evaluatePlays(scene), evaluatePlays({ ...scene, opponentRemaining: undefined }));
    strictEqual(
      decidePlay({ ...scene, rng: seededRng(t), game: { myScore: 115, opponentScore: 118, iAmDealer: true } }),
      decidePlay({ ...scene, rng: seededRng(t), opponentRemaining: undefined })
    );
  }
});
check("easy: the same seed gives the same choices", () => {
  const run = () => {
    const rng = seededRng(99);
    const out: string[] = [];
    for (let t = 0; t < 60; t++) {
      out.push(decideDiscard({ hand: shuffled(rng).slice(0, 6), isDealer: t % 2 === 0, level: "easy", rng }).join());
      const s = randomScene(rng);
      out.push(decidePlay({ ...s, opponentCardCount: s.theirLeft.length, level: "easy", rng }));
    }
    return out;
  };
  deepStrictEqual(run(), run());
});
check("easy ignores opponentRemaining (same seed, same card)", () => {
  const rng = seededRng(111);
  for (let t = 0; t < 500; t++) {
    const s = randomScene(rng);
    const scene: PlayInput = {
      myRemaining: s.myRemaining,
      starter: s.starter,
      segmentCards: s.segmentCards,
      count: s.count,
      allPlayed: s.allPlayed,
      opponentCardCount: s.theirLeft.length,
      level: "easy",
    };
    strictEqual(
      decidePlay({ ...scene, rng: seededRng(t), opponentRemaining: s.theirLeft }),
      decidePlay({ ...scene, rng: seededRng(t) }),
      `t=${t}`
    );
  }
});

// ---- Hard: the pegging search ------------------------------------------------------
// An independent brute force, written from the rules (not lib/computer/rules.ts),
// with no memo: hands[0] is the player to move first ("me").
type Naive = { hands: string[][]; seg: string[]; count: number; turn: number };
function naiveMove(s: Naive, card: string): { pts: number; next: Naive | null } {
  const me = s.turn;
  const them = 1 - me;
  const hands = s.hands.map((h, i) => (i === me ? h.filter((c) => c !== card) : [...h]));
  const seg = s.seg.concat(card);
  const count = s.count + cardPlayValue(card);
  let pts = scorePegging(seg).points;
  const canPlay = (who: number, at: number) => hands[who].some((c) => at + cardPlayValue(c) <= 31);
  if (count !== 31 && canPlay(them, count)) return { pts, next: { hands, seg, count, turn: them } };
  if (count !== 31 && canPlay(me, count)) return { pts, next: { hands, seg, count, turn: me } };
  if (count !== 31) pts += 1; // nobody can go on: a go (or the last card)
  // The count starts again: whoever still holds a card, the other player first.
  const leader = hands[them].length ? them : hands[me].length ? me : -1;
  return { pts, next: leader < 0 ? null : { hands, seg: [], count: 0, turn: leader } };
}
function naiveBest(s: Naive): number {
  let best = -Infinity;
  for (const card of s.hands[s.turn].filter((c) => s.count + cardPlayValue(c) <= 31)) {
    const { pts, next } = naiveMove(s, card);
    const rest = next === null ? 0 : next.turn === s.turn ? naiveBest(next) : -naiveBest(next);
    best = Math.max(best, pts + rest);
  }
  return best === -Infinity ? 0 : best;
}
const peggingScene = (s: ReturnType<typeof randomScene>): PlayInput => ({
  myRemaining: s.myRemaining,
  starter: s.starter,
  segmentCards: s.segmentCards,
  count: s.count,
  allPlayed: s.allPlayed,
  opponentCardCount: s.theirLeft.length,
  level: "hard",
  opponentRemaining: s.theirLeft,
});
check("hard search: agrees with an independent brute-force minimax (300 positions)", () => {
  const rng = seededRng(4040);
  for (let t = 0; t < 300; t++) {
    const s = randomScene(rng);
    const options = evaluatePlays(peggingScene(s));
    for (const o of options) {
      const { pts, next } = naiveMove({ hands: [s.myRemaining, s.theirLeft], seg: s.segmentCards, count: s.count, turn: 0 }, o.card);
      const expected = pts + (next === null ? 0 : next.turn === 0 ? naiveBest(next) : -naiveBest(next));
      strictEqual(o.value, expected, `t=${t} ${o.card}: search ${o.value}, brute force ${expected}`);
    }
  }
});
check("hard search: beats the one-move-ahead choice in hand-made positions", () => {
  // Each: the one-move-ahead pick (points now minus the best reply) and the
  // card the search plays, which is worth more over the rest of the hand.
  const cases = [
    // Found by comparing the two methods over random positions; the
    // brute-force check above confirms the search's values.
    // A lead: one move ahead plays 2D; over the whole hand JH is 3 points better.
    { mine: ["QS", "JH", "2D"], theirs: ["JD", "5H", "9D"], starter: "7S", seg: [], oneMove: "2D", searched: "JH" },
    // A lead: one move ahead plays TC; over the whole hand the 5 is 3 points better.
    { mine: ["TC", "5D", "8C"], theirs: ["7C", "6C", "AC"], starter: "3S", seg: [], oneMove: "TC", searched: "5D" },
    // After a jack: one move ahead plays AS; over the whole hand 2S is 2 points better.
    { mine: ["2S", "AS"], theirs: ["2H", "9S"], starter: "6H", seg: ["JS"], oneMove: "AS", searched: "2S" },
  ];
  for (const c of cases) {
    const count = c.seg.reduce((n, card) => n + cardPlayValue(card), 0);
    const scene: PlayInput = {
      myRemaining: c.mine,
      starter: c.starter,
      segmentCards: c.seg,
      count,
      allPlayed: c.seg,
      opponentCardCount: c.theirs.length,
      level: "hard",
      rng: seededRng(1),
    };
    // One move ahead (no opponent cards: the estimate) need not match; the
    // exact one-move-ahead pick is checked through the search's own values.
    const searched = evaluatePlays({ ...scene, opponentRemaining: c.theirs });
    const best = searched[0];
    const oneMoveValue = searched.find((o) => o.card === c.oneMove)?.value as number;
    strictEqual(best.card, c.searched, `${c.mine}: searched ${best.card}`);
    ok(best.value > oneMoveValue, `${c.mine}: ${best.value} vs one move ahead ${oneMoveValue}`);
    strictEqual(decidePlay({ ...scene, opponentRemaining: c.theirs }), c.searched);
  }
});
check("hard search: easy and medium never use the opponent's cards (same values with them)", () => {
  const rng = seededRng(5050);
  for (let t = 0; t < 300; t++) {
    const s = randomScene(rng);
    for (const level of ["easy", "medium"] as const) {
      const scene = { ...peggingScene(s), level };
      deepStrictEqual(evaluatePlays(scene), evaluatePlays({ ...scene, opponentRemaining: undefined }));
    }
  }
});
check("medium never errs in pegging: always the best card (1000 scenes)", () => {
  const rng = seededRng(5252);
  for (let t = 0; t < 1000; t++) {
    const s = randomScene(rng);
    const scene = { ...peggingScene(s), level: "medium" as const, opponentRemaining: undefined };
    strictEqual(decidePlay({ ...scene, rng: seededRng(t) }), evaluatePlays(scene)[0].card, `t=${t}`);
  }
});
check("medium ignores opponentRemaining and the game state, and never searches (same seed, same card)", () => {
  const rng = seededRng(5353);
  for (let t = 0; t < 300; t++) {
    const s = randomScene(rng);
    const scene = { ...peggingScene(s), level: "medium" as const };
    strictEqual(
      decidePlay({ ...scene, rng: seededRng(t), game: { myScore: 115, opponentScore: 118, iAmDealer: true } }),
      decidePlay({ ...scene, rng: seededRng(t), opponentRemaining: undefined }),
      `t=${t}`
    );
  }
});
// THE EXACT-REPLIES BRANCH: a level that peeks without searching takes the
// one-move-ahead branch with the opponent's actual cards. No level is set
// up that way now, so these tests make one, for their own duration only:
// Medium with peek switched on (restored afterwards, whatever happens).
function withPeekingMedium(fn: () => void) {
  const real = LEVELS.medium;
  LEVELS.medium = { ...real, peek: true };
  try {
    fn();
  } finally {
    LEVELS.medium = real;
  }
}
// The best card one move ahead from the opponent's actual cards -- points
// now minus their best reply, written out here independently.
function oneMoveAhead(seg: string[], count: number, card: string, theirs: string[]) {
  const segment = [...seg, card];
  const now = count + cardPlayValue(card);
  const points = scorePegging(segment).points;
  if (now === 31) return { points, value: points };
  const replies = theirs.filter((c) => now + cardPlayValue(c) <= 31).map((c) => scorePegging([...segment, c]).points);
  return { points, value: points - Math.max(0, ...replies) };
}
check("a peeking level without search (forced here): one move ahead, exact replies (300 positions)", () => withPeekingMedium(() => {
  const rng = seededRng(5151);
  let differs = 0;
  for (let t = 0; t < 300; t++) {
    const s = randomScene(rng);
    const scene = { ...peggingScene(s), level: "medium" as const };
    const options = evaluatePlays(scene);
    for (const o of options) {
      const expected = oneMoveAhead(s.segmentCards, s.count, o.card, s.theirLeft);
      strictEqual(o.points, expected.points, `t=${t} ${o.card}: points`);
      ok(Math.abs(o.value - expected.value) < 1e-9, `t=${t} ${o.card}: ${o.value}, expected ${expected.value}`);
    }
    // And the cards matter: the blind estimate gives other values.
    if (JSON.stringify(options) !== JSON.stringify(evaluatePlays({ ...scene, opponentRemaining: undefined }))) differs++;
  }
  ok(differs > 100, `the opponent's cards changed the values only ${differs} times`);
}));
check("a peeking level without search (forced here) never searches: the one-move-ahead values where the search's differ", () => withPeekingMedium(() => {
  // The hand-made search positions above: Hard's search beats one move ahead.
  const cases = [
    { mine: ["QS", "JH", "2D"], theirs: ["JD", "5H", "9D"], starter: "7S", seg: [] as string[], oneMove: "2D" },
    { mine: ["TC", "5D", "8C"], theirs: ["7C", "6C", "AC"], starter: "3S", seg: [] as string[], oneMove: "TC" },
    { mine: ["2S", "AS"], theirs: ["2H", "9S"], starter: "6H", seg: ["JS"], oneMove: "AS" },
  ];
  for (const c of cases) {
    const count = c.seg.reduce((n, card) => n + cardPlayValue(card), 0);
    const scene: PlayInput = {
      myRemaining: c.mine,
      starter: c.starter,
      segmentCards: c.seg,
      count,
      allPlayed: c.seg,
      opponentCardCount: c.theirs.length,
      level: "medium",
      rng: seededRng(1),
      opponentRemaining: c.theirs,
    };
    for (const o of evaluatePlays(scene)) {
      ok(Math.abs(o.value - oneMoveAhead(c.seg, count, o.card, c.theirs).value) < 1e-9, `${c.mine} ${o.card}`);
    }
    strictEqual(decidePlay(scene), c.oneMove, `${c.mine}: it plays the one-move-ahead card`);
    ok(decidePlay({ ...scene, level: "hard" }) !== c.oneMove, `${c.mine}: hard searches to another card`);
  }
}));
// ---- Hard: playing to win near 121 ---------------------------------------------------
// A pegging position from a real deal with both kept hands known: some
// random plays (by the independent rules above), stopped on my turn.
type EndScene = { input: PlayInput; mine: string[]; theirs: string[] };
function endgameScene(rng: () => number, low: number, high: number): EndScene {
  for (;;) {
    const deck = shuffled(rng);
    const mine = deck.slice(0, 4);
    const theirs = deck.slice(4, 8);
    const starter = deck[8];
    let s: Naive | null = { hands: [[...mine], [...theirs]], seg: [], count: 0, turn: rng() < 0.5 ? 0 : 1 };
    const played: string[] = [];
    const steps = Math.floor(rng() * 5);
    for (let i = 0; s && (i < steps || s.turn !== 0); i++) {
      const legal: string[] = s.hands[s.turn].filter((c) => s!.count + cardPlayValue(c) <= 31);
      const card = legal[Math.floor(rng() * legal.length)];
      played.push(card);
      s = naiveMove(s, card).next;
    }
    if (!s) continue;
    const span = high - low + 1;
    return {
      mine,
      theirs,
      input: {
        myRemaining: s.hands[0],
        starter,
        segmentCards: s.seg,
        count: s.count,
        allPlayed: played,
        opponentCardCount: s.hands[1].length,
        level: "hard",
        opponentRemaining: s.hands[1],
        game: {
          myScore: low + Math.floor(rng() * span),
          opponentScore: low + Math.floor(rng() * span),
          iAmDealer: rng() < 0.5,
          myKept: mine,
          opponentKept: theirs,
        },
      },
    };
  }
}
// The independent near-121 brute force: the same rules as the plain one,
// plus the game's end. The value scale is the spec's: a win is 100000 less
// 100 per play or count it takes; a loss the negative; any value that big
// passes through unchanged; an undecided line is the points difference.
const N_WIN = 100000;
const N_STEP = 100;
function naiveToWin(s: Naive, card: string, scores: number[], depth: number, dealer: number, hands: number[]): number {
  const me = s.turn;
  const { pts, next } = naiveMove(s, card);
  const after = [...scores];
  after[me] += pts;
  if (after[me] >= 121) return N_WIN - N_STEP * (depth + 1);
  if (next === null) {
    const pone = 1 - dealer;
    let winner = -1;
    let steps = 0;
    if (after[pone] + hands[pone] >= 121) [winner, steps] = [pone, 1];
    else if (after[dealer] + hands[dealer] >= 121) [winner, steps] = [dealer, 2];
    if (winner < 0) return pts;
    const size = N_WIN - N_STEP * (depth + 1 + steps);
    return winner === me ? size : -size;
  }
  let best = -Infinity;
  for (const c of next.hands[next.turn].filter((x) => next.count + cardPlayValue(x) <= 31)) {
    best = Math.max(best, naiveToWin(next, c, after, depth + 1, dealer, hands));
  }
  const rest = next.turn === me ? best : -best;
  return Math.abs(rest) >= N_WIN / 2 ? rest : pts + rest;
}
check("hard to-win search: agrees with an independent brute force near 121 (300 positions)", () => {
  const rng = seededRng(8080);
  let decided = 0;
  for (let t = 0; t < 300; t++) {
    const { input, mine, theirs } = endgameScene(rng, 95, 120);
    const g = input.game!;
    const hands = [scoreHandPoints(mine, input.starter), scoreHandPoints(theirs, input.starter)];
    const dealer = g.iAmDealer ? 0 : 1;
    for (const o of evaluatePlays(input)) {
      const expected = naiveToWin(
        { hands: [input.myRemaining, input.opponentRemaining!], seg: input.segmentCards, count: input.count, turn: 0 },
        o.card,
        [g.myScore, g.opponentScore],
        0,
        dealer,
        hands
      );
      strictEqual(o.value, expected, `t=${t} ${o.card}: search ${o.value}, brute force ${expected}`);
      if (Math.abs(expected) >= N_WIN / 2) decided++;
    }
  }
  ok(decided > 100, `only ${decided} decided lines: the positions aren't testing the endgame`);
});
check("hard to-win search: wins where the points-difference choice doesn't", () => {
  const cases = [
    // A peg-out: at 119 as pone, the King makes 15 on their 5 for the game;
    // the points-difference search plays the 3.
    { mine: ["6S", "7C", "3C", "KC"], theirs: ["2D", "5C", "2C", "AD"], starter: "QD", played: ["5C"], seg: ["5C"],
      myRemaining: ["6S", "7C", "3C", "KC"], oppRemaining: ["2D", "2C", "AD"], myScore: 119, opponentScore: 103, iAmDealer: false,
      plain: "3C", winning: "KC" },
    // Stopping a peg-out: the 2 (points-difference choice) lets them peg out; the 8 doesn't.
    { mine: ["3S", "8H", "9C", "2D"], theirs: ["KH", "4H", "6D", "7D"], starter: "5H", played: ["9C", "4H"], seg: ["9C", "4H"],
      myRemaining: ["3S", "8H", "2D"], oppRemaining: ["KH", "6D", "7D"], myScore: 113, opponentScore: 109, iAmDealer: false,
      plain: "2D", winning: "8H" },
    // A pone hand that wins at the count: keep them from pegging out, then
    // 116 + an 8-point hand counts first.
    { mine: ["3H", "5D", "7H", "3D"], theirs: ["5H", "7D", "8S", "7S"], starter: "QC", played: ["3H", "7S"], seg: ["3H", "7S"],
      myRemaining: ["5D", "7H", "3D"], oppRemaining: ["5H", "7D", "8S"], myScore: 116, opponentScore: 117, iAmDealer: false,
      plain: "5D", winning: "3D" },
  ];
  for (const c of cases) {
    const base: PlayInput = {
      myRemaining: c.myRemaining,
      starter: c.starter,
      segmentCards: c.seg,
      count: c.seg.reduce((n, card) => n + cardPlayValue(card), 0),
      allPlayed: c.played,
      opponentCardCount: c.oppRemaining.length,
      level: "hard",
      rng: seededRng(1),
      opponentRemaining: c.oppRemaining,
    };
    const withGame = { ...base, game: { myScore: c.myScore, opponentScore: c.opponentScore, iAmDealer: c.iAmDealer, myKept: c.mine, opponentKept: c.theirs } };
    strictEqual(decidePlay(base), c.plain, `${c.winning}: the points-difference choice`);
    strictEqual(decidePlay(withGame), c.winning, `${c.winning}: the winning choice`);
    const options = evaluatePlays(withGame);
    const plainValue = options.find((o) => o.card === c.plain)?.value as number;
    if (c.plain === "2D") {
      // Stopping a peg-out: the points-difference card loses; the chosen one doesn't.
      ok(plainValue <= -N_WIN / 2, `${c.plain} should lose (${plainValue})`);
      ok(options[0].value > -N_WIN / 2, `${c.winning} should not lose (${options[0].value})`);
    } else {
      // A win (a peg-out, or at the count) that the points-difference card misses.
      ok(options[0].value >= N_WIN / 2, `${c.winning}: not a won line (${options[0].value})`);
      ok(plainValue < N_WIN / 2, `${c.plain} also wins?`);
    }
  }
});
check("hard to-win search: far from 121 the choices and values are the same as before", () => {
  const rng = seededRng(9090);
  for (let t = 0; t < 300; t++) {
    const { input } = endgameScene(rng, 0, 59);
    deepStrictEqual(evaluatePlays(input), evaluatePlays({ ...input, game: undefined }), `t=${t}`);
  }
});
check("hard to-win search: medium and easy ignore the game state", () => {
  const rng = seededRng(9191);
  for (let t = 0; t < 200; t++) {
    const { input } = endgameScene(rng, 95, 120);
    for (const level of ["medium", "easy"] as const) {
      const scene = { ...input, level, rng: seededRng(t) };
      strictEqual(decidePlay(scene), decidePlay({ ...scene, game: undefined, rng: seededRng(t) }));
      deepStrictEqual(evaluatePlays(scene), evaluatePlays({ ...scene, game: undefined }));
    }
  }
});
check("speed: the to-win search near 121 averages well under 50 ms per decision", () => {
  const rng = seededRng(9292);
  let total = 0;
  let worst = 0;
  const N = 300;
  for (let t = 0; t < N; t++) {
    // The biggest: a fresh hand, four cards each, a lead, scores near 121.
    const deck = shuffled(rng);
    const scene: PlayInput = {
      myRemaining: deck.slice(0, 4),
      starter: deck[8],
      segmentCards: [],
      count: 0,
      allPlayed: [],
      opponentCardCount: 4,
      level: "hard",
      rng: seededRng(t),
      opponentRemaining: deck.slice(4, 8),
      game: { myScore: 100 + (t % 21), opponentScore: 120 - (t % 21), iAmDealer: t % 2 === 0, myKept: deck.slice(0, 4), opponentKept: deck.slice(4, 8) },
    };
    const start = performance.now();
    decidePlay(scene);
    const took = performance.now() - start;
    total += took;
    worst = Math.max(worst, took);
  }
  console.log(`   to-win search: ${(total / N).toFixed(2)} ms average, ${worst.toFixed(2)} ms worst (${N} full-hand leads near 121)`);
  ok(total / N < 50, `${total / N} ms`);
});
check("speed: the hard search averages well under 50 ms per decision", () => {
  const rng = seededRng(6060);
  let total = 0;
  let worst = 0;
  const N = 300;
  for (let t = 0; t < N; t++) {
    // The biggest searches: a fresh hand, four cards each, a lead.
    const deck = shuffled(rng);
    const scene: PlayInput = {
      myRemaining: deck.slice(0, 4),
      starter: deck[8],
      segmentCards: [],
      count: 0,
      allPlayed: [],
      opponentCardCount: 4,
      level: "hard",
      rng: seededRng(t),
      opponentRemaining: deck.slice(4, 8),
    };
    const start = performance.now();
    decidePlay(scene);
    const took = performance.now() - start;
    total += took;
    worst = Math.max(worst, took);
  }
  console.log(`   hard search: ${(total / N).toFixed(2)} ms average, ${worst.toFixed(2)} ms worst (${N} full-hand leads)`);
  ok(total / N < 50, `${total / N} ms`);
});

// ---- Hard: the discard with the opponent's kept hand --------------------------------
// A deal: my six and the opponent's kept four, all different.
function discardDeal(rng: () => number) {
  const deck = shuffled(rng);
  return { hand: deck.slice(0, 6), theirs: deck.slice(6, 10) };
}
// The average hand score of a keep over the given starters, written out here.
const averageOver = (keep: string[], starters: string[]) =>
  starters.reduce((sum, s) => sum + scoreHand(keep, s, false).points, 0) / starters.length;
check("easy and medium ignore opponentKept (same seed, same discard, same evaluation)", () => {
  const rng = seededRng(3131);
  for (let t = 0; t < 100; t++) {
    const { hand, theirs } = discardDeal(rng);
    for (const level of ["easy", "medium"] as const) {
      const isDealer = t % 2 === 0;
      deepStrictEqual(
        evaluateDiscards({ hand, isDealer, level, rng: seededRng(t), opponentKept: theirs }),
        evaluateDiscards({ hand, isDealer, level, rng: seededRng(t) })
      );
      deepStrictEqual(
        decideDiscard({ hand, isDealer, level, rng: seededRng(t), opponentKept: theirs }),
        decideDiscard({ hand, isDealer, level, rng: seededRng(t) })
      );
    }
  }
});
check("hard without opponentKept: the previous discard (46 starters, no pegging value)", () => {
  const rng = seededRng(3232);
  for (let t = 0; t < 40; t++) {
    const { hand } = discardDeal(rng);
    const isDealer = t % 2 === 0;
    const unseen = FULL_DECK.filter((c) => !hand.includes(c));
    for (const o of evaluateDiscards({ hand, isDealer, level: "hard", rng: seededRng(t) })) {
      strictEqual(o.peggingValue, 0);
      ok(Math.abs(o.handValue - averageOver(o.keep, unseen)) < 1e-9, `t=${t}: hand value over 46 starters`);
      strictEqual(o.value, isDealer ? o.handValue + o.cribValue : o.handValue - o.cribValue);
    }
  }
});
check("hard with opponentKept: the exact pegging value per keep matches a brute force (100 deals, dealer and pone)", () => {
  const rng = seededRng(3333);
  for (let t = 0; t < 100; t++) {
    const { hand, theirs } = discardDeal(rng);
    const isDealer = t % 2 === 0;
    const unseen = FULL_DECK.filter((c) => !hand.includes(c) && !theirs.includes(c));
    for (const o of evaluateDiscards({ hand, isDealer, level: "hard", rng: seededRng(t), opponentKept: theirs })) {
      // The pone leads: the opponent when I deal.
      const turn = isDealer ? 1 : 0;
      const best = naiveBest({ hands: [o.keep, theirs], seg: [], count: 0, turn });
      strictEqual(o.peggingValue, turn === 0 ? best : -best, `t=${t} keep ${o.keep}`);
      ok(Math.abs(o.handValue - averageOver(o.keep, unseen)) < 1e-9, `t=${t}: hand value over the 42 starters`);
      strictEqual(o.value, (isDealer ? o.handValue + o.cribValue : o.handValue - o.cribValue) + o.peggingValue);
    }
  }
});
check("hard: an invalid opponentKept is ignored (wrong length, a repeat, overlapping my six)", () => {
  const rng = seededRng(3434);
  for (let t = 0; t < 30; t++) {
    const { hand, theirs } = discardDeal(rng);
    const plain = evaluateDiscards({ hand, isDealer: true, level: "hard", rng: seededRng(t) });
    for (const bad of [theirs.slice(0, 3), [...theirs.slice(0, 3), theirs[0]], [...theirs.slice(0, 3), hand[0]], ["ZZ", ...theirs.slice(0, 3)]]) {
      deepStrictEqual(evaluateDiscards({ hand, isDealer: true, level: "hard", rng: seededRng(t), opponentKept: bad }), plain, `bad ${bad}`);
    }
  }
});
check("hard: the opponent's kept hand changes the discard in a good share of deals", () => {
  const rng = seededRng(3535);
  let differs = 0;
  for (let t = 0; t < 200; t++) {
    const { hand, theirs } = discardDeal(rng);
    const isDealer = t % 2 === 0;
    const blind = decideDiscard({ hand, isDealer, level: "hard", rng: seededRng(t) });
    const seen = decideDiscard({ hand, isDealer, level: "hard", rng: seededRng(t), opponentKept: theirs });
    if (!same(blind, seen)) differs++;
  }
  console.log(`   hard discard with the kept hand: a different discard in ${differs} of 200 deals`);
  ok(differs >= 20, `only ${differs} of 200 differ`);
});
check("speed: hard's discard with the opponent's kept hand averages well under 50 ms", () => {
  const rng = seededRng(3636);
  let total = 0;
  let worst = 0;
  const N = 150;
  for (let t = 0; t < N; t++) {
    const { hand, theirs } = discardDeal(rng);
    const start = performance.now();
    decideDiscard({ hand, isDealer: t % 2 === 0, level: "hard", rng: seededRng(t), opponentKept: theirs });
    const took = performance.now() - start;
    total += took;
    worst = Math.max(worst, took);
  }
  console.log(`   hard discard with the kept hand: ${(total / N).toFixed(2)} ms average, ${worst.toFixed(2)} ms worst`);
  ok(total / N < 50, `${total / N} ms`);
});

// ---- Speed ---------------------------------------------------------------------
check("speed: decideDiscard averages under 25 ms (hard, 500 samples) and stays quick for medium", () => {
  const rng = seededRng(8);
  const hands = Array.from({ length: 200 }, () => shuffled(rng).slice(0, 6));
  for (const level of ["hard", "medium"] as const) {
    decideDiscard({ hand: hands[0], isDealer: true, level, rng }); // warm-up
    const start = performance.now();
    for (const hand of hands) decideDiscard({ hand, isDealer: true, level, rng });
    const each = (performance.now() - start) / hands.length;
    console.log(`   decideDiscard (${level}): ${each.toFixed(2)} ms per call (average of ${hands.length})`);
    ok(each < 25, `${level}: ${each} ms`);
  }
});
check("hard discard: stable for a seed, and agrees with a 3000-sample reference on at least 90% of 100 hands", () => {
  const rng = seededRng(12);
  let agree = 0;
  for (let t = 0; t < 100; t++) {
    const hand = shuffled(rng).slice(0, 6);
    const isDealer = t % 2 === 0;
    const a = decideDiscard({ hand, isDealer, level: "hard", rng: seededRng(t) });
    deepStrictEqual(decideDiscard({ hand, isDealer, level: "hard", rng: seededRng(t) }), a);
    const ref = decideDiscard({ hand, isDealer, level: "hard", rng: seededRng(70000 + t), cribSamples: 3000 });
    if (same(a, ref)) agree++;
  }
  ok(agree >= 90, `agreed on ${agree} of 100`);
});

console.log(`All ${passed} computer brain checks passed.`);
