// Test suite for the scoring engines. Zero dependencies -- Node 24 runs
// TypeScript directly (type stripping), so this needs no test framework, no
// build step and no database.
//
//   npm test                   run every stage
//   npm run test:quick         skip the exhaustive stage
//   npm run test:sql-cases     print the VALUES list for the SQL cross-check
//
// Those wrap `node --import ./scripts/ts-resolve.mjs scripts/test-scoring.ts`
// -- see scripts/ts-resolve.mjs for why the hook is needed.
//
// WHAT THIS DOES AND DOES NOT PROVE
//
// It checks lib/scoring.ts against a second scorer written here, from the
// rules, using a different algorithm. For runs that independence is real: the
// mirror walks maximal blocks of consecutive ranks and multiplies the counts,
// while the checker below enumerates every subset of the five cards and keeps
// the ones that form a run no other card can extend. A bug would have to hit
// both, identically.
//
// For fifteens and pairs the two agree by definition -- "every subset summing
// to 15" and "every unordered same-rank pair" are the rules, and there is no
// second way to say them. Flush and nobs are likewise one-liners. For those
// four the value here is COVERAGE (all 12,994,800 hand-and-starter
// combinations, so every suit arrangement and every duplicate-rank shape),
// not algorithmic independence.
//
// It says nothing about the SQL. The SQL is checked separately, against
// expected values generated from the checker below -- see --emit-sql-cases
// and docs/sql/phase2-batch1-verification.sql.

import { RANKS, SUITS, rankOf, suitOf } from "../lib/cards";
import { scoreHand, scorePegging, type HandScore } from "../lib/scoring";

// ---------------------------------------------------------------------------
// Test plumbing
// ---------------------------------------------------------------------------

let passed = 0;
const failures: string[] = [];

function check(label: string, actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    passed += 1;
  } else {
    failures.push(`${label}\n      expected ${e}\n      actual   ${a}`);
  }
}

function stage(name: string) {
  console.log(`\n=== ${name}`);
}

// ---------------------------------------------------------------------------
// Integer-encoded deck. The checker works on these so it never touches a
// string in the hot loop; the mirror is given the card codes as normal.
// ---------------------------------------------------------------------------

const DECK: string[] = [];
for (const suit of SUITS) for (const rank of RANKS) DECK.push(rank + suit);

const CARD_RANK = new Int32Array(52); // 1..13, ace low
const CARD_VALUE = new Int32Array(52); // 1..10, counting value
const CARD_SUIT = new Int32Array(52); // 0..3
DECK.forEach((card, i) => {
  const r = RANKS.indexOf(rankOf(card) as (typeof RANKS)[number]) + 1;
  CARD_RANK[i] = r;
  CARD_VALUE[i] = r > 10 ? 10 : r;
  CARD_SUIT[i] = SUITS.indexOf(suitOf(card) as (typeof SUITS)[number]);
});

// popcount over a 13-bit rank mask, and over a 5-bit card mask.
const POPCOUNT = new Uint8Array(1 << 13);
for (let i = 1; i < POPCOUNT.length; i++) POPCOUNT[i] = POPCOUNT[i >> 1] + (i & 1);

// A rank mask is a run exactly when its set bits are contiguous: shift the
// lowest bit down to position 0 and the result must be 2^size - 1.
function isContiguous(rankMask: number, size: number) {
  const lowest = rankMask & -rankMask;
  return rankMask / lowest === (1 << size) - 1;
}

// ---------------------------------------------------------------------------
// THE INDEPENDENT CHECKER
//
// Same rules, deliberately different reasoning for runs: every subset of the
// five cards that forms a run AND cannot be extended by any of the remaining
// cards scores its own length. That is the textbook definition. Double,
// triple and double-double runs therefore arise by COUNTING separate runs,
// where the mirror arrives at the same totals by multiplying rank counts.
// ---------------------------------------------------------------------------

function checkerScore(
  cards: Int32Array, // the 5 card indices
  starterSlot: number,
  isCrib: boolean
): HandScore {
  let fifteens = 0;
  for (let mask = 1; mask < 32; mask++) {
    let sum = 0;
    for (let b = 0; b < 5; b++) if (mask & (1 << b)) sum += CARD_VALUE[cards[b]];
    if (sum === 15) fifteens += 2;
  }

  let pairs = 0;
  for (let i = 0; i < 5; i++) {
    for (let j = i + 1; j < 5; j++) {
      if (CARD_RANK[cards[i]] === CARD_RANK[cards[j]]) pairs += 2;
    }
  }

  let runs = 0;
  for (let mask = 1; mask < 32; mask++) {
    const size = POPCOUNT[mask];
    if (size < 3) continue;

    let rankMask = 0;
    for (let b = 0; b < 5; b++) {
      if (mask & (1 << b)) rankMask |= 1 << (CARD_RANK[cards[b]] - 1);
    }
    // Duplicate ranks collapse in the mask, so this rejects them.
    if (POPCOUNT[rankMask] !== size) continue;
    if (!isContiguous(rankMask, size)) continue;

    // Maximal only: if any card left out would extend it, this subset is part
    // of a longer run and must not be counted on its own.
    let extendable = false;
    for (let b = 0; b < 5 && !extendable; b++) {
      if (mask & (1 << b)) continue;
      const grown = rankMask | (1 << (CARD_RANK[cards[b]] - 1));
      if (POPCOUNT[grown] === size + 1 && isContiguous(grown, size + 1)) {
        extendable = true;
      }
    }
    if (!extendable) runs += size;
  }

  // Flush and nobs: no second way to state these. Coverage is the point.
  let flush = 0;
  let handSuit = -1;
  let sameSuit = true;
  for (let b = 0; b < 5; b++) {
    if (b === starterSlot) continue;
    if (handSuit === -1) handSuit = CARD_SUIT[cards[b]];
    else if (CARD_SUIT[cards[b]] !== handSuit) sameSuit = false;
  }
  if (sameSuit) {
    if (CARD_SUIT[cards[starterSlot]] === handSuit) flush = 5;
    else if (!isCrib) flush = 4;
  }

  let nobs = 0;
  for (let b = 0; b < 5; b++) {
    if (b === starterSlot) continue;
    if (
      CARD_RANK[cards[b]] === 11 &&
      CARD_SUIT[cards[b]] === CARD_SUIT[cards[starterSlot]]
    ) {
      nobs = 1;
    }
  }

  return { points: fifteens + pairs + runs + flush + nobs, fifteens, pairs, runs, flush, nobs };
}

// String-in wrapper, for the known-answer cases and the SQL generator.
function checkerScoreCards(cards: string[], starter: string, isCrib: boolean): HandScore {
  const idx = new Int32Array(5);
  for (let i = 0; i < 4; i++) idx[i] = DECK.indexOf(cards[i]);
  idx[4] = DECK.indexOf(starter);
  for (let i = 0; i < 5; i++) {
    if (idx[i] < 0) throw new Error(`Unknown card in case: ${[...cards, starter][i]}`);
  }
  return checkerScore(idx, 4, isCrib);
}

// ---------------------------------------------------------------------------
// STAGE 1: known-answer hands.
//
// Values derived by hand from the rules, not from either implementation.
// Several cases are built from all-even or all-ten-valued cards so no subset
// can reach 15 -- that isolates runs, pairs, flush and nobs from fifteens and
// makes each expected number something you can check in your head.
// ---------------------------------------------------------------------------

type HandCase = {
  label: string;
  cards: string[];
  starter: string;
  isCrib: boolean;
  expected: number;
  why: string;
};

const HAND_CASES: HandCase[] = [
  {
    label: "29 -- the best hand there is",
    cards: ["5S", "5H", "5D", "JC"],
    starter: "5C",
    isCrib: false,
    expected: 29,
    why: "four 5s: 4x(5+5+5)=8 and 4x(5+J)=8 fifteens, 6 pairs=12, nobs 1",
  },
  {
    label: "28 -- four 5s, ten-card starter, no nobs",
    cards: ["5S", "5H", "5D", "5C"],
    starter: "TS",
    isCrib: false,
    expected: 28,
    why: "8 + 8 fifteens, 12 pairs, no jack so no nobs",
  },
  {
    label: "0 -- the scoreless hand",
    cards: ["2S", "4H", "6D", "8C"],
    starter: "KS",
    isCrib: false,
    expected: 0,
    why: "every value even so no subset hits 15; no pair, no run, mixed suits, no jack",
  },
  {
    label: "double run of three",
    cards: ["JS", "QH", "KD", "KC"],
    starter: "3H",
    isCrib: false,
    expected: 8,
    why: "J-Q-K twice = 6, pair of kings = 2; all tens so no fifteen",
  },
  {
    label: "triple run of three",
    cards: ["JS", "JH", "JD", "QC"],
    starter: "KC",
    isCrib: false,
    expected: 15,
    why: "three J-Q-K runs = 9, pair royal of jacks = 6",
  },
  {
    label: "double-double run, fifteens suppressed",
    cards: ["JS", "JH", "QD", "QC"],
    starter: "KD",
    isCrib: false,
    expected: 16,
    why: "four J-Q-K runs = 12, two pairs = 4; all tens so no fifteen",
  },
  {
    label: "double-double run, the classic 24",
    cards: ["4S", "4H", "5D", "5C"],
    starter: "6D",
    isCrib: false,
    expected: 24,
    why: "four 4-5-6 runs = 12, two pairs = 4, four ways to make 4+5+6 = 8",
  },
  {
    label: "double run of four",
    cards: ["4S", "5H", "6D", "6C"],
    starter: "7H",
    isCrib: false,
    expected: 14,
    why: "4-5-6-7 twice = 8, pair of 6s = 2, 4+5+6 twice = 4",
  },
  {
    label: "run of five",
    cards: ["AS", "2H", "3D", "4C"],
    starter: "5S",
    isCrib: false,
    expected: 7,
    why: "run of 5 = 5, and the whole hand sums to 15 = 2",
  },
  {
    label: "J-Q-K is a run by RANK though all three count 10",
    cards: ["JS", "QH", "KD", "2C"],
    starter: "7H",
    isCrib: false,
    expected: 3,
    why: "run of 3; 10+10+10+2+7 has no subset of 15",
  },
  {
    label: "three tens are a pair royal, never a run",
    cards: ["TS", "TH", "TD", "2C"],
    starter: "7H",
    isCrib: false,
    expected: 6,
    why: "pair royal 6, no run -- rank 10 three times is not a sequence",
  },
  {
    label: "hand four-flush scores 4",
    cards: ["2S", "4S", "6S", "8S"],
    starter: "KH",
    isCrib: false,
    expected: 4,
    why: "four spades, starter off-suit; all values even so nothing else scores",
  },
  {
    label: "the SAME four-flush in the crib scores 0",
    cards: ["2S", "4S", "6S", "8S"],
    starter: "KH",
    isCrib: true,
    expected: 0,
    why: "a crib needs all FIVE in suit; four is worth nothing",
  },
  {
    label: "five-flush scores 5 in the hand",
    cards: ["2S", "4S", "6S", "8S"],
    starter: "KS",
    isCrib: false,
    expected: 5,
    why: "all five spades",
  },
  {
    label: "five-flush scores 5 in the crib too",
    cards: ["2S", "4S", "6S", "8S"],
    starter: "KS",
    isCrib: true,
    expected: 5,
    why: "the only flush a crib can score",
  },
  {
    label: "nobs: jack in hand matching the starter's suit",
    cards: ["JS", "2H", "4D", "6C"],
    starter: "8S",
    isCrib: false,
    expected: 1,
    why: "J of spades, starter a spade; values 10,2,4,6,8 are all even so no fifteen",
  },
  {
    label: "no nobs when the jack's suit does not match",
    cards: ["JH", "2H", "4D", "6C"],
    starter: "8S",
    isCrib: false,
    expected: 0,
    why: "jack of hearts, starter a spade",
  },
  {
    label: "HIS HEELS IS NOT SCORED HERE: jack starter, no jack in hand",
    cards: ["2S", "4H", "6D", "8C"],
    starter: "JS",
    isCrib: false,
    expected: 0,
    why: "the dealer's 2 for a jack starter is awarded in discard_to_crib; counting it here too is the double-award bug",
  },
];

function runHandCases() {
  stage("Stage 1: known-answer hands (expected values derived by hand)");
  for (const c of HAND_CASES) {
    const mirror = scoreHand(c.cards, c.starter, c.isCrib);
    const checker = checkerScoreCards(c.cards, c.starter, c.isCrib);
    const label = `${c.label} [${c.cards.join(" ")} + ${c.starter}${c.isCrib ? ", crib" : ""}]`;
    check(`${label} -- mirror total (${c.why})`, mirror.points, c.expected);
    check(`${label} -- checker total`, checker.points, c.expected);
    check(`${label} -- breakdowns agree`, mirror, checker);
  }
  console.log(`   ${HAND_CASES.length} hands x 3 assertions`);
}

// ---------------------------------------------------------------------------
// STAGE 2: known-answer pegging segments.
//
// The same 31 stratified cases used for the SQL cross-check, which passed in
// the database. Expected values derived from the rules.
// ---------------------------------------------------------------------------

const PEGGING_CASES: [string[], number, string][] = [
  [["7H"], 0, ""],
  [["TD"], 0, ""],
  [["7H", "8S"], 2, "fifteen"],
  [["5C", "TD"], 2, "fifteen"],
  [["7H", "8S", "5D"], 0, ""], // 7+8 made 15 earlier; only the CURRENT total counts
  [["TH", "TS", "AD", "TC"], 2, "thirty-one"],
  [["9H", "2S", "TD", "TC"], 4, "thirty-one + pair"],
  [["7H", "7S"], 2, "pair"],
  [["7H", "7S", "7D"], 6, "pair royal"],
  [["7H", "7S", "7D", "7C"], 12, "double pair royal"],
  [["TH", "TS", "TD"], 6, "pair royal"], // three tens: pair royal, NOT a run
  [["7H", "3S", "7D"], 0, ""], // pair broken by an intervening card
  [["2H", "9S", "9D", "9C"], 6, "pair royal"],
  [["2H", "3S", "4D"], 3, "run of 3"],
  [["5H", "3S", "4D"], 3, "run of 3"], // order inside the run does not matter
  [["4H", "5S", "6D", "7C"], 4, "run of 4"],
  [["6H", "4S", "7D", "5C"], 4, "run of 4"],
  [["3H", "4S", "5D", "6C", "7H"], 5, "run of 5"],
  [["5H", "3S", "7D", "4C", "6S"], 5, "run of 5"],
  [["JH", "QS", "KD"], 3, "run of 3"], // ranks 11,12,13 -- a run though all count 10
  [["TH", "JS", "QD"], 3, "run of 3"], // a run by rank, not because they share a value
  [["QH", "KS", "AD"], 0, ""], // no wrap: ace is low
  [["4H", "5S", "9D", "6C"], 0, ""], // run broken by an intervening card
  [["AH", "2S", "6D", "3C", "4H", "5S"], 6, "run of 6"], // longest suffix wins
  [["AH", "2S", "3D"], 3, "run of 3"],
  [["3H", "4S", "4D", "5C"], 0, ""], // duplicate rank inside the suffix
  [["AH", "7S", "7D"], 4, "fifteen + pair"],
  [["5H", "5S", "5D"], 8, "fifteen + pair royal"],
  [["4H", "5S", "6D"], 5, "fifteen + run of 3"],
  [["AH", "2S", "3D", "4C", "5H"], 7, "fifteen + run of 5"],
  [["9H", "TS", "4D", "3C", "5H"], 5, "thirty-one + run of 3"],
];

// Independent pegging checker: detects runs by sorting the suffix and
// requiring every adjacent rank difference to be exactly 1, where the mirror
// uses a distinct-count plus a max-minus-min span test.
function checkerPegging(segment: string[]): { points: number; reason: string } {
  const n = segment.length;
  if (n === 0) return { points: 0, reason: "" };

  const ranks = segment.map((c) => CARD_RANK[DECK.indexOf(c)]);
  const values = segment.map((c) => CARD_VALUE[DECK.indexOf(c)]);
  const parts: string[] = [];
  let points = 0;

  const total = values.reduce((a, b) => a + b, 0);
  if (total === 15) {
    points += 2;
    parts.push("fifteen");
  } else if (total === 31) {
    points += 2;
    parts.push("thirty-one");
  }

  let streak = 1;
  for (let i = n - 2; i >= 0 && ranks[i] === ranks[n - 1]; i--) streak += 1;
  if (streak >= 2) {
    points += streak * (streak - 1);
    parts.push(streak === 2 ? "pair" : streak === 3 ? "pair royal" : "double pair royal");
  }

  for (let len = n; len >= 3; len--) {
    const suffix = ranks.slice(n - len).sort((a, b) => a - b);
    let consecutive = true;
    for (let i = 1; i < suffix.length; i++) {
      if (suffix[i] - suffix[i - 1] !== 1) consecutive = false;
    }
    if (consecutive) {
      points += len;
      parts.push(`run of ${len}`);
      break;
    }
  }

  return { points, reason: parts.join(" + ") };
}

function runPeggingCases() {
  stage("Stage 2: known-answer pegging segments");
  for (const [segment, points, reason] of PEGGING_CASES) {
    const label = `[${segment.join(" ")}]`;
    check(`${label} -- mirror`, scorePegging(segment), { points, reason });
    check(`${label} -- checker`, checkerPegging(segment), { points, reason });
  }

  // A segment is scored from exactly what it is handed, so the CALLER has to
  // filter out earlier segments. This asserts the difference is real: pass a
  // prior-segment card and the answer changes. play_card filters on segment
  // (region B of the migration); the manual plan verifies it end to end.
  check(
    "a prior-segment card WOULD change the score, so play_card must filter it out",
    [scorePegging(["5H", "5S", "5D"]).points, scorePegging(["5D"]).points],
    [8, 0]
  );

  // Empty and single-card segments must not throw.
  check("empty segment", scorePegging([]), { points: 0, reason: "" });

  console.log(`   ${PEGGING_CASES.length} segments x 2 assertions, plus 2 edge cases`);
}

// ---------------------------------------------------------------------------
// STAGE 3: randomised pegging differential.
//
// The known-answer list covers the cases that matter; this sweeps the shapes
// nobody thought to write down. Segments are built the way play actually
// builds them -- cards added one at a time, never past 31.
// ---------------------------------------------------------------------------

function runPeggingDifferential(iterations: number) {
  stage(`Stage 3: randomised pegging differential (${iterations.toLocaleString()} segments)`);

  // Deterministic PRNG so a failure is reproducible.
  let seed = 0x9e3779b9;
  const rand = (n: number) => {
    seed ^= seed << 13;
    seed ^= seed >>> 17;
    seed ^= seed << 5;
    seed |= 0;
    return Math.abs(seed) % n;
  };

  let mismatches = 0;
  let longest = 0;
  for (let it = 0; it < iterations; it++) {
    const segment: string[] = [];
    let count = 0;
    const wanted = 1 + rand(8);
    for (let k = 0; k < wanted; k++) {
      const card = DECK[rand(52)];
      const value = CARD_VALUE[DECK.indexOf(card)];
      if (count + value > 31) break;
      segment.push(card);
      count += value;
    }
    if (segment.length === 0) continue;
    longest = Math.max(longest, segment.length);

    const a = scorePegging(segment);
    const b = checkerPegging([...segment]);
    if (a.points !== b.points || a.reason !== b.reason) {
      mismatches += 1;
      if (mismatches <= 5) {
        failures.push(
          `pegging differential [${segment.join(" ")}]\n` +
            `      mirror  ${JSON.stringify(a)}\n` +
            `      checker ${JSON.stringify(b)}`
        );
      }
    }
  }

  check("pegging differential mismatches", mismatches, 0);
  console.log(`   longest segment generated: ${longest} cards`);
}

// ---------------------------------------------------------------------------
// STAGE 4: THE EXHAUSTIVE HAND CHECK.
//
// Every 5-card set out of 52, times each of the 5 choices of which one is the
// starter, times both isCrib values:
//
//   C(52,5) = 2,598,960 sets x 5 starters = 12,994,800 hands
//   x 2 (hand and crib) = 25,989,600 scorings per implementation
//
// Also collects the facts that are properties of cribbage itself rather than
// of either implementation: which totals are reachable, and how many hands
// reach 29.
// ---------------------------------------------------------------------------

function runExhaustive() {
  stage("Stage 4: exhaustive -- every 5-card set x 5 starters x hand/crib");

  const started = Date.now();
  const idx = new Int32Array(5);
  const hand: string[] = ["", "", "", ""];

  const seenHand = new Set<number>();
  const seenCrib = new Set<number>();
  let twentyNines = 0;
  let mismatches = 0;
  let cases = 0;

  const report = (
    cards: string[],
    starter: string,
    isCrib: boolean,
    mirror: HandScore,
    checker: HandScore
  ) => {
    mismatches += 1;
    if (mismatches <= 10) {
      failures.push(
        `exhaustive [${cards.join(" ")} + ${starter}${isCrib ? ", crib" : ""}]\n` +
          `      mirror  ${JSON.stringify(mirror)}\n` +
          `      checker ${JSON.stringify(checker)}`
      );
    }
  };

  for (let a = 0; a < 48; a++) {
    for (let b = a + 1; b < 49; b++) {
      for (let c = b + 1; c < 50; c++) {
        for (let d = c + 1; d < 51; d++) {
          for (let e = d + 1; e < 52; e++) {
            idx[0] = a;
            idx[1] = b;
            idx[2] = c;
            idx[3] = d;
            idx[4] = e;

            for (let s = 0; s < 5; s++) {
              let h = 0;
              for (let t = 0; t < 5; t++) if (t !== s) hand[h++] = DECK[idx[t]];
              const starter = DECK[idx[s]];

              const mirrorHand = scoreHand(hand, starter, false);
              const checkHand = checkerScore(idx, s, false);
              cases += 1;
              if (
                mirrorHand.points !== checkHand.points ||
                mirrorHand.fifteens !== checkHand.fifteens ||
                mirrorHand.pairs !== checkHand.pairs ||
                mirrorHand.runs !== checkHand.runs ||
                mirrorHand.flush !== checkHand.flush ||
                mirrorHand.nobs !== checkHand.nobs
              ) {
                report([...hand], starter, false, mirrorHand, checkHand);
              }
              seenHand.add(mirrorHand.points);
              if (mirrorHand.points === 29) twentyNines += 1;

              const mirrorCrib = scoreHand(hand, starter, true);
              const checkCrib = checkerScore(idx, s, true);
              cases += 1;
              if (
                mirrorCrib.points !== checkCrib.points ||
                mirrorCrib.fifteens !== checkCrib.fifteens ||
                mirrorCrib.pairs !== checkCrib.pairs ||
                mirrorCrib.runs !== checkCrib.runs ||
                mirrorCrib.flush !== checkCrib.flush ||
                mirrorCrib.nobs !== checkCrib.nobs
              ) {
                report([...hand], starter, true, mirrorCrib, checkCrib);
              }
              seenCrib.add(mirrorCrib.points);
            }
          }
        }
      }
    }
  }

  const seconds = ((Date.now() - started) / 1000).toFixed(1);
  console.log(`   ${cases.toLocaleString()} scorings per implementation in ${seconds}s`);

  check("exhaustive mismatches between mirror and checker", mismatches, 0);
  check("hands scored (C(52,5) x 5 starters)", cases / 2, 12_994_800);

  // --- Properties of cribbage, not of the code ---------------------------
  //
  // A hand with its starter can score anything from 0 to 29 EXCEPT 19, 25,
  // 26 and 27. ("A nineteen hand" is the standing joke for a worthless one.)
  // This is the assertion that would catch a scorer which is self-consistent
  // but wrong, because neither implementation knows this fact.
  const IMPOSSIBLE = [19, 25, 26, 27];
  const expectedHand = [];
  for (let n = 0; n <= 29; n++) if (!IMPOSSIBLE.includes(n)) expectedHand.push(n);

  check(
    "reachable hand totals are exactly 0-29 except 19, 25, 26, 27",
    [...seenHand].sort((x, y) => x - y),
    expectedHand
  );
  check("exactly four hands score 29", twentyNines, 4);

  // The crib cannot score a four-card flush, so it can only ever reach FEWER
  // totals, never more. Asserting the four impossible values stay impossible
  // is safe; asserting the rest are all reachable is not, so it is reported.
  check(
    "the four impossible totals are impossible in the crib too",
    IMPOSSIBLE.filter((n) => seenCrib.has(n)),
    []
  );
  const missingInCrib = expectedHand.filter((n) => !seenCrib.has(n));
  console.log(
    `   crib totals unreachable that a hand can reach: ${
      missingInCrib.length === 0 ? "none" : missingInCrib.join(", ")
    }`
  );
}

// ---------------------------------------------------------------------------
// --emit-sql-cases: generate the stratified score_hand cross-check.
//
// Expected values come from the CHECKER, not from lib/scoring.ts, so the
// chain is: checker <-> mirror (exhaustive, above) and checker <-> SQL
// (stratified, in the database). The SQL is never compared against something
// derived from the SQL.
// ---------------------------------------------------------------------------

const SQL_CASES: { cards: string[]; starter: string; label: string }[] = [
  // --- runs, every shape ---
  { cards: ["2S", "4H", "6D", "8C"], starter: "KS", label: "no run, no anything (the 0 hand)" },
  { cards: ["JS", "QH", "KD", "2C"], starter: "7H", label: "run of 3, J-Q-K by rank" },
  { cards: ["TS", "TH", "TD", "2C"], starter: "7H", label: "three tens: pair royal, NOT a run" },
  { cards: ["JS", "QH", "KD", "AC"], starter: "7H", label: "Q-K-A does not wrap" },
  { cards: ["9S", "TH", "JD", "QC"], starter: "2H", label: "run of 4" },
  { cards: ["AS", "2H", "3D", "4C"], starter: "5S", label: "run of 5, ace low" },
  { cards: ["JS", "QH", "KD", "KC"], starter: "3H", label: "double run of 3" },
  { cards: ["4S", "5H", "6D", "6C"], starter: "7H", label: "double run of 4" },
  { cards: ["JS", "JH", "JD", "QC"], starter: "KC", label: "triple run of 3" },
  { cards: ["JS", "JH", "QD", "QC"], starter: "KD", label: "double-double run" },
  { cards: ["4S", "4H", "5D", "5C"], starter: "6D", label: "double-double run, the classic 24" },
  // --- flushes, every shape ---
  { cards: ["2S", "4S", "6S", "8S"], starter: "KH", label: "four-flush: 4 in hand, 0 in crib" },
  { cards: ["2S", "4S", "6S", "8S"], starter: "KS", label: "five-flush: 5 in both" },
  { cards: ["2S", "4S", "6S", "8H"], starter: "KS", label: "three of a suit plus starter: no flush" },
  { cards: ["JS", "QS", "KS", "2S"], starter: "7H", label: "four-flush AND a run" },
  // --- nobs, every shape ---
  { cards: ["JS", "2H", "4D", "6C"], starter: "8S", label: "nobs: jack matches the starter's suit" },
  { cards: ["JH", "2H", "4D", "6C"], starter: "8S", label: "no nobs: jack is off-suit" },
  { cards: ["2S", "4H", "6D", "8C"], starter: "JS", label: "jack STARTER: his heels, so score_hand gives 0" },
  { cards: ["JS", "JH", "4D", "6C"], starter: "8S", label: "two jacks, one matching: nobs is 1, not 2" },
  { cards: ["JS", "2S", "4S", "6S"], starter: "8S", label: "five-flush plus nobs" },
  // --- the extremes ---
  { cards: ["5S", "5H", "5D", "JC"], starter: "5C", label: "29" },
  { cards: ["5S", "5H", "5D", "5C"], starter: "TS", label: "28" },
];

function emitSqlCases() {
  const rows: string[] = [];
  for (const c of SQL_CASES) {
    for (const isCrib of [false, true]) {
      const s = checkerScoreCards(c.cards, c.starter, isCrib);
      const arr = `array[${c.cards.map((x) => `'${x}'`).join(",")}]`;
      rows.push(
        `    (${arr}, '${c.starter}', ${isCrib ? "true " : "false"}, ` +
          `${String(s.points).padStart(2)}, ${String(s.fifteens).padStart(2)}, ` +
          `${String(s.pairs).padStart(2)}, ${String(s.runs).padStart(2)}, ` +
          `${s.flush}, ${s.nobs}),  -- ${c.label}${isCrib ? " [crib]" : " [hand]"}`
      );
    }
  }
  // Trailing comma off the last row.
  rows[rows.length - 1] = rows[rows.length - 1].replace("),  --", ")   --");
  console.log(rows.join("\n"));
  console.log(`\n-- ${rows.length} rows`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const args = process.argv.slice(2);

if (args.includes("--emit-sql-cases")) {
  emitSqlCases();
  process.exit(0);
}

runHandCases();
runPeggingCases();
runPeggingDifferential(200_000);

if (args.includes("--quick")) {
  stage("Stage 4: exhaustive -- SKIPPED (--quick)");
} else {
  runExhaustive();
}

console.log(`\n${"=".repeat(60)}`);
if (failures.length === 0) {
  console.log(`PASS -- ${passed} assertions`);
  process.exit(0);
} else {
  console.log(`FAIL -- ${failures.length} of ${passed + failures.length} assertions\n`);
  for (const f of failures) console.log(`  x ${f}`);
  process.exit(1);
}
