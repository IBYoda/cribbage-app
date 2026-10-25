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
    easy: { mistakeRate: 0.9, peek: false },
    medium: { mistakeRate: 0.35, peek: false },
    hard: { mistakeRate: 0, peek: true },
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
check("discard: easy and medium deviate from the best at about their rates", () => {
  const rng = seededRng(11);
  const hands = Array.from({ length: 400 }, () => shuffled(rng).slice(0, 6));
  for (const [level, low, high] of [["easy", 0.72, 0.95], ["medium", 0.2, 0.45]] as const) {
    let deviations = 0;
    hands.forEach((hand, t) => {
      const seed = 5000 + t;
      const best = evaluateDiscards({ hand, isDealer: true, level, rng: seededRng(seed) })[0].discard;
      const out = decideDiscard({ hand, isDealer: true, level, rng: seededRng(seed) });
      if (!same(out, best)) deviations++;
    });
    // Expected: mistakeRate x 14/15 (a random pick lands on the best 1 in 15).
    const rate = deviations / hands.length;
    ok(rate >= low && rate <= high, `${level}: deviated ${rate.toFixed(3)}, expected ${low}-${high}`);
  }
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
check("play: easy and medium ignore opponentRemaining (same seed, same card)", () => {
  const rng = seededRng(99);
  for (let t = 0; t < 300; t++) {
    const deck = shuffled(rng);
    const mine = deck.slice(0, 4);
    const theirs = deck.slice(4, 8);
    for (const level of ["easy", "medium"] as const) {
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
    for (const level of LEVEL_NAMES) {
      const card = decidePlay({
        myRemaining: s.myRemaining,
        starter: s.starter,
        segmentCards: s.segmentCards,
        count: s.count,
        allPlayed: s.allPlayed,
        opponentCardCount: s.theirLeft.length,
        level,
        rng: seededRng(t),
        opponentRemaining: t % 2 === 0 ? s.theirLeft : undefined,
      });
      ok(s.myRemaining.includes(card), `not held: ${card}`);
      ok(s.count + cardPlayValue(card) <= 31, `illegal: ${card} at ${s.count}`);
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

// ---- Speed ---------------------------------------------------------------------
check("speed: decideDiscard averages well under 50 ms", () => {
  const rng = seededRng(8);
  const hands = Array.from({ length: 200 }, () => shuffled(rng).slice(0, 6));
  decideDiscard({ hand: hands[0], isDealer: true, level: "hard", rng }); // warm-up
  const start = performance.now();
  for (const hand of hands) decideDiscard({ hand, isDealer: true, level: "hard", rng });
  const each = (performance.now() - start) / hands.length;
  console.log(`   decideDiscard: ${each.toFixed(2)} ms per call (average of ${hands.length})`);
  ok(each < 50, `${each} ms`);
});

console.log(`All ${passed} computer brain checks passed.`);
