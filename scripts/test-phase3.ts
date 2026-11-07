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
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import {
  WINGS_ASPECT,
  WINGS_BADGE,
  WINGS_CENTRE_Y,
  WINGS_PLACEMENT,
  WINGS_SETTING_KEY,
  WINGS_SPLASH,
  WINGS_TIERS,
  badgeSize,
  flamesForPointer,
  idBatches,
  initSeenTier,
  isMilestone,
  nextTier,
  placementFor,
  plateSpot,
  progress,
  readSeenTier,
  readWingsOn,
  shouldCelebrate,
  tierForCount,
  wingsAssets,
  wingsBox,
  wingsSeenKey,
  wingsOverhang,
  wingsSplashSub,
  writeSeenTier,
  writeWingsOn,
} from "../lib/wings";
import { fourPlayerModeOffered, newTableFields, startTableOptions } from "../lib/newTable";
import { mugginsPlateStates, type MugginsPlateState } from "../lib/mugginsPlates";
import { adminTableLabel, isStaleWaitingTable, seatedNames, STALE_WAITING_TABLE_MS } from "../lib/tableListing";
import { godLossAlt, godLossSplash, hideRejoinedScores, lossTier, scoreFromThisGame } from "../lib/resultScores";
import {
  BURST_WINDOW_MS,
  CORE_SOUNDS,
  DEFAULT_SOUND_VOLUME,
  SHUFFLE_LEAD_MS,
  SOUND_CLIP_MAX_BYTES,
  SOUND_EVENTS,
  SOUND_KEY,
  SOUND_PRIORITY,
  SOUND_SET_MAX_BYTES,
  SOUND_VOLUME_KEY,
  audioRepair,
  clipsFor,
  cueAllowed,
  heardZeroKeys,
  isZeroCount,
  zeroKey,
  zeroSoundAllowed,
  cutKey,
  cutKeys,
  cutOpenKey,
  dealKey,
  discardKey,
  discardKeys,
  endKey,
  endSoundEvent,
  gameOutcome,
  heardKeys,
  loserScore,
  pickBurst,
  pickClip,
  playKey,
  readLastClip,
  readSoundOn,
  readSoundVolume,
  soundFor,
  writeLastClip,
  writeSoundOn,
  writeSoundVolume,
  type SoundCue,
  type SoundEvent,
} from "../lib/sounds";
import { isEmailNotConfirmed, readAuthHashError, RESEND_COOLDOWN_S, resendSecondsLeft } from "../lib/authFlow";
import {
  GOD_ZERO_SPLASH_IMAGE,
  GOD_ZERO_SPLASH_PHRASES,
  GO_SPLASH_MS,
  isGodLevel,
  SPLASH_MS,
  splashDurationMs,
  ZERO_SPLASH_PHRASES,
  zeroSplashKind,
  zeroSplashPhrases,
} from "../lib/splashPhrases";
import {
  NICKNAME_MAX_LENGTH,
  needsNickname,
  nicknameProblem,
  nicknameSaveErrorMessage,
  nicknameStepHref,
  safeReturnPath,
} from "../lib/nickname";
import {
  pollIntervalMs,
  profilesToFetch,
  SAFETY_POLL_CONNECTED_MS,
  SAFETY_POLL_MS,
  wonBoardReusable,
} from "../lib/tableSync";
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
  boardLanesFor,
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
  frontPegScore,
  nextPegs,
  PEG_MIN_R,
  S_VARIANTS,
  TRACK_ASPECT_MAX,
  trackStretch,
  boardGeometryFor,
  boardPatternFor,
  isSBoard,
  pegPosition,
  sBoardGeometry,
  sHolePosition,
  sTrack,
  sVariantFor,
  sSlidePoints,
  pegSlideFrames,
  SNAKE_VARIANT,
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
  BOARD_PATTERN_KEY,
  boardPatternById,
  readBoardPattern,
  writeBoardPattern,
  sRibbonFill,
  sPlateColors,
} from "../lib/boardSkins";
import {
  DERBY_ART,
  DERBY_FINISH_X,
  DERBY_MAX_SLIDE,
  DERBY_MAX_TILT,
  DERBY_RUN_UP,
  DERBY_START_X,
  derbyDistance,
  derbyHorseScale,
  derbyHorseTransform,
  derbyLaneCount,
  derbyLaneLength,
  derbyLaneOffset,
  derbyPointAt,
  derbyPose,
  derbySlideFrames,
  type DerbyLaneCount,
} from "../lib/derbyTrack";
import {
  BEER_LAYERS,
  BEER_MAX_DRAIN,
  BEER_MUGS,
  BEER_PREVIEW_SIZE,
  beerAriaLabel,
  beerDrains,
  beerDrawing,
  beerEase,
  beerFoamCap,
  beerLayerUrl,
  beerLayerUrls,
  beerLayoutFor,
  beerLevel,
  beerLevelY,
  beerMugIdsFor,
  beerPreviewPlates,
  beerScene,
  beerSlots,
  platesReplaced,
  type BeerMugId,
} from "../lib/beerBoard";
import type { ScorePlate } from "../components/table/ScoreStrip";
import {
  CUSTOM_BOARD_KEY,
  CUSTOM_BOARDS,
  customBoardById,
  FOOTBALL_PEG_RX,
  FOOTBALL_PEG_RY,
  fieldLogoPx,
  fieldYardLines,
  readCustomBoardId,
  writeCustomBoardId,
  YARD_NUMBER_MIN_PX,
  YARD_NUMBERS,
  yardNumberPx,
  yardNumberRows,
} from "../lib/customBoards";
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
check("layout: 4-player Solo is square by default, ?layout=classic classic -- the Teams rule", () => {
  for (const param of [null, "square", "x", "", "Square"]) {
    for (const s of SQUARE_SCREENS) strictEqual(layoutFor(param, 4, false, s), "square", `4p solo ${param} ${s}`);
    for (const s of CLASSIC_SCREENS) strictEqual(layoutFor(param, 4, false, s), "classic", `4p solo ${param} ${s}`);
  }
  for (const s of [...SQUARE_SCREENS, ...CLASSIC_SCREENS]) strictEqual(layoutFor("classic", 4, false, s), "classic", s);
  // Exactly what 4-player Teams gets.
  for (const param of [null, "square", "classic", "x"]) {
    for (const s of [...SQUARE_SCREENS, ...CLASSIC_SCREENS]) {
      strictEqual(
        chooseTableLayout({ layoutParam: param, playerCount: 4, isMuggins: false, teams: false, screen: s }),
        chooseTableLayout({ layoutParam: param, playerCount: 4, isMuggins: false, teams: true, screen: s })
      );
    }
  }
  strictEqual(isSquareTable({ layoutParam: null, playerCount: 4, isMuggins: false }), true);
  strictEqual(isSquareTable({ layoutParam: "classic", playerCount: 4, isMuggins: false }), false);
});
check("layout: 3- or 4-player self-scoring is square on its screens -- ?layout=classic ignored", () => {
  for (const param of [null, "square", "classic", "x", "", "Square"]) {
    for (const n of [3, 4]) {
      for (const s of SQUARE_SCREENS) strictEqual(layoutFor(param, n, true, s), "square", `${n}p muggins ${param} ${s}`);
      for (const s of CLASSIC_SCREENS) strictEqual(layoutFor(param, n, true, s), "classic", `${n}p muggins ${param} ${s}`);
      strictEqual(isSquareTable({ layoutParam: param, playerCount: n, isMuggins: true }), true, `${n}p ${param}`);
    }
    // The teams flag changes nothing (a 4-player self-scoring table is
    // 'solo' anyway).
    for (const s of [...SQUARE_SCREENS, ...CLASSIC_SCREENS]) {
      strictEqual(
        chooseTableLayout({ layoutParam: param, playerCount: 4, isMuggins: true, teams: true, screen: s }),
        layoutFor(param, 4, true, s),
        `4p teams muggins ${param} ${s}`
      );
    }
  }
  // Other sizes never square, self-scoring or not.
  for (const n of [0, 1, 5]) strictEqual(isSquareTable({ layoutParam: null, playerCount: n, isMuggins: true }), false);
  strictEqual(isSquareTable({ layoutParam: null, playerCount: 2, isMuggins: false }), true);
  strictEqual(isSquareTable({ layoutParam: "classic", playerCount: 2, isMuggins: false }), false);
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
check("layout: 2, 3 and 4 players (Solo) follow the same rule; other table sizes never square", () => {
  for (const param of [null, "square", "classic", "x"]) {
    for (const s of [...SQUARE_SCREENS, ...CLASSIC_SCREENS]) {
      strictEqual(layoutFor(param, 3, false, s), layoutFor(param, 2, false, s), `${param} ${s}`);
      strictEqual(layoutFor(param, 4, false, s), layoutFor(param, 2, false, s), `4p solo ${param} ${s}`);
      for (const n of [0, 1, 5]) strictEqual(layoutFor(param, n, false, s), "classic", `${n}p ${param} ${s}`);
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
  // Self-scoring: its own rule (square always -- its own check). (4-player
  // Solo: the same as Teams -- its own check.)
  for (const param of [null, "square", "classic", "x"]) {
    for (const s of SQUARE_SCREENS) strictEqual(teams4(param, s, true), "square", `muggins ${param} ${s}`);
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
  // 4-player Solo: a lane each by seat, the fourth seat lane 3 (4-lane board).
  deepStrictEqual(P4.map((id) => laneForPlayer({ players: P4, userId: id, teams: false })), [0, 1, 2, 3]);
  strictEqual(laneForPlayer({ players: P4, userId: "z", teams: false }), null);
  strictEqual(boardLanesFor(4, false), 4);
  strictEqual(boardLanesFor(4, true), 3);
  for (const n of [2, 3]) for (const t of [false, true]) strictEqual(boardLanesFor(n, t), 3);
});
// 4-PLAYER SOLO: the 4-lane straight board and its four plates.
check("4-lane board: four lanes, 123 holes each in order, inside the board, pegs at 9.8px clear of the next lane", () => {
  for (const [w, h] of [[375, 66.7], [375, 67], [390, 84], [502, 108], [896, 86]]) {
    const g = boardGeometry(w, h, 4);
    strictEqual(g.rows.length, 4);
    const holes = boardHoles(g);
    strictEqual(holes.length, 4 * 123);
    for (let lane = 0; lane < 4; lane++) {
      // In order: the same rows and columns as a 3-lane board's lane.
      for (const s of [1, 30, 60, 61, 90, 120]) {
        const p = holePosition(g, lane, s);
        const spot = holeSpot(s);
        strictEqual(spot.kind === "hole" && p.y === (spot.row === "out" ? g.rows[lane].out : g.rows[lane].back), true);
      }
      strictEqual(holePosition(g, lane, 121).y, g.rows[lane].back);
    }
    for (const hole of holes) {
      strictEqual(hole.x - g.pegR >= 0 && hole.x + g.pegR <= w && hole.y - g.pegR >= 0 && hole.y + g.pegR <= h, true, `${w}x${h}`);
    }
    // The 9.8px peg, and a peg in one lane never touches one in the next.
    strictEqual(g.pegR * 2 >= 9.8 - 1e-9, true, `peg ${(g.pegR * 2).toFixed(2)} at ${w}x${h}`);
    for (let lane = 1; lane < 4; lane++) {
      strictEqual(g.rows[lane].out - g.rows[lane - 1].back >= 2 * g.pegR - 1e-9, true, `lanes at ${w}x${h}`);
    }
  }
  // Lanes stay in seat order down the board; lane 3 is the fourth seat's.
  const g = boardGeometry(502, 108, 4);
  strictEqual(g.rows.every((r, i) => i === 0 || r.out > g.rows[i - 1].back), true);
});
check("4-lane board: the 3-lane board is untouched (same geometry, default lanes)", () => {
  for (const [w, h] of [[375, 67], [502, 108]]) {
    deepStrictEqual(boardGeometry(w, h, 3), boardGeometry(w, h));
    deepStrictEqual(boardGeometryFor("straight", w, h, 3), boardGeometry(w, h));
  }
});
check("4-lane board: every skin's 4th lane meets the peg and hole floors; four lane colours clearly different", () => {
  for (const s of BOARD_SKIN_LIST) {
    strictEqual(isHexColor(s.fourthLane.color) && isHexColor(s.fourthLane.peg), true, s.id);
    if (!pegContrastExempt(s)) strictEqual(pegContrast(s, 3) >= PEG_CONTRAST_MIN, true, `${s.id} peg ${pegContrast(s, 3).toFixed(2)}`);
    if (!holeContrastExempt(s)) strictEqual(holeContrast(s, 3) >= HOLE_CONTRAST_MIN, true, `${s.id} hole ${holeContrast(s, 3).toFixed(2)}`);
    strictEqual(laneSeparation(s, 4) >= LANE_DISTANCE_MIN, true, `${s.id} ${laneSeparation(s, 4).toFixed(1)}`);
    // Its ring colour is its lane colour.
    strictEqual(laneRingColor(s, 3), s.fourthLane.color);
  }
  // The colours asked for.
  deepStrictEqual(
    BOARD_SKIN_LIST.map((s) => [s.id, s.fourthLane.color, s.fourthLane.peg]),
    [
      ["classic-wood", "#f0b429", "#8a5a00"],
      ["midnight", "#ff7a59", "#ff7a59"],
      ["espresso", "#e8a93a", "#5a1f7a"],
      ["mahogany", "#d9a441", "#0f3d2e"],
      ["heritage", "#6b7f5e", "#1e2a18"],
      ["metallic", "#5a86b0", "#0e2236"],
    ]
  );
});
check("4-player Solo: S and Snake fall back to the 4-lane straight board; every other game keeps the pattern", () => {
  for (const p of ["straight", "s", "snake"] as const) {
    strictEqual(boardPatternFor(p, 4), "straight");
    strictEqual(boardPatternFor(p, 3), p);
    const g = boardGeometryFor(p, 375, 67, 4);
    strictEqual(isSBoard(g), false);
    strictEqual(!isSBoard(g) && g.rows.length === 4, true);
  }
  strictEqual(isSBoard(boardGeometryFor("s", 375, 67, 3)), true);
  strictEqual(isSBoard(boardGeometryFor("snake", 375, 67)), true);
});
check("4-player Solo: four plates, one a player, in seat order from me (Teams: two)", () => {
  const P = ["y", "s", "n", "k"];
  const rows = seatOrderFrom(P, "y").map((id, i) => ({
    user_id: id,
    name: id.toUpperCase().repeat(30),
    avatar_url: null,
    score: 10 + i,
    last_points: null,
    last_reason: null,
    last_awarded_at: null,
  }));
  const solo = buildPlates({ rows, myId: "y", dealerId: "s", teamsPlayers: null });
  deepStrictEqual(solo.map((p) => p.key), ["y", "s", "n", "k"]);
  strictEqual(solo.every((p) => p.members.length === 1), true);
  // Each a quarter of the strip -- half a Teams plate.
  const teams = buildPlates({ rows, myId: "y", dealerId: "s", teamsPlayers: P });
  strictEqual(teams.length, 2);
  strictEqual(solo.length, teams.length * 2);
  // Names kept whole for the tooltip (the strip ellipsises them).
  strictEqual(solo[1].members[0].name, "S".repeat(30));
});
// START A TABLE (lib/newTable.ts).
check("Start a Table: Team or Solo is offered only with 4 players (never with Self-Scoring)", () => {
  strictEqual(fourPlayerModeOffered(4, false), true);
  strictEqual(fourPlayerModeOffered(2, false), false);
  strictEqual(fourPlayerModeOffered(3, false), false);
  for (const n of [2, 3, 4] as const) strictEqual(fourPlayerModeOffered(n, true), false);
});
check("Start a Table: the row created -- 2/3 players and Teams exactly as before, Solo for 4", () => {
  const base = { isPublic: true, isMuggins: false };
  // 2 and 3 players: no team_mode sent (the database default), whatever the
  // 4-player choice left behind -- exactly the old insert.
  for (const n of [2, 3] as const) {
    for (const mode of ["teams", "solo"] as const) {
      deepStrictEqual(newTableFields({ ...base, maxPlayers: n, fourPlayerMode: mode }), {
        is_public: true,
        is_muggins: false,
        max_players: n,
      });
    }
  }
  // 2-player Self-Scoring, private: as before.
  deepStrictEqual(newTableFields({ isPublic: false, isMuggins: true, maxPlayers: 2, fourPlayerMode: "teams" }), {
    is_public: false,
    is_muggins: true,
    max_players: 2,
  });
  // 4 players, Teams (the default): team_mode 'teams', as before.
  deepStrictEqual(newTableFields({ ...base, maxPlayers: 4, fourPlayerMode: "teams" }), {
    is_public: true,
    is_muggins: false,
    max_players: 4,
    team_mode: "teams",
  });
  // 4 players, Solo: team_mode 'solo' -- the row the solo verification
  // suite (docs/sql/phase3-solo-verification.sql, C1) proves is accepted.
  deepStrictEqual(newTableFields({ ...base, maxPlayers: 4, fourPlayerMode: "solo" }), {
    is_public: true,
    is_muggins: false,
    max_players: 4,
    team_mode: "solo",
  });
});
check("Start a Table: Self-Scoring with 2, 3 and 4 players, never a Team/Solo choice with it", () => {
  for (const n of [2, 3, 4] as const) {
    // Self-Scoring is offered whatever the size; every size whatever the
    // scoring -- nothing greyed out between them.
    for (const muggins of [false, true]) {
      const o = startTableOptions(n, muggins);
      strictEqual(o.mugginsOffered, true, `${n} ${muggins}`);
      deepStrictEqual(o.playerCounts, [2, 3, 4], `${n} ${muggins}`);
    }
    // With Self-Scoring: no Team/Solo shown, nor offered.
    deepStrictEqual(
      { shown: startTableOptions(n, true).fourPlayerModeShown, offered: startTableOptions(n, true).fourPlayerModeOffered },
      { shown: false, offered: false },
      `${n}p self-scoring`
    );
    // Regular play: shown, and offered for 4 only -- as before.
    strictEqual(startTableOptions(n, false).fourPlayerModeShown, true, `${n}p regular`);
    strictEqual(startTableOptions(n, false).fourPlayerModeOffered, n === 4, `${n}p regular`);
  }
});
check("Start a Table: the Self-Scoring row -- 3 and 4 players 'solo', 2 players as before", () => {
  for (const isPublic of [true, false]) {
    for (const mode of ["teams", "solo"] as const) {
      // 2 players: exactly the old insert (no team_mode).
      deepStrictEqual(newTableFields({ isPublic, isMuggins: true, maxPlayers: 2, fourPlayerMode: mode }), {
        is_public: isPublic,
        is_muggins: true,
        max_players: 2,
      });
      // 3 and 4: 'solo', whatever the (hidden) Team/Solo choice left behind
      // -- the database requires it for 4 (tables_muggins_no_teams).
      for (const n of [3, 4] as const) {
        deepStrictEqual(newTableFields({ isPublic, isMuggins: true, maxPlayers: n, fourPlayerMode: mode }), {
          is_public: isPublic,
          is_muggins: true,
          max_players: n,
          team_mode: "solo",
        });
      }
    }
  }
});

// THE SELF-SCORING PLATES (lib/mugginsPlates.ts), 3 and 4 players. Seen as
// "a" (plates me first, then clockwise). Each plate as kind:label (+ "✓"
// when ticked), and my plate's action.
const MP3 = ["a", "b", "c"];
const MP4 = ["a", "b", "c", "d"];
const mpOrder = (ids: string[], name = (id: string) => id.toUpperCase()) => ids.map((id) => ({ userId: id, name: name(id) }));
const mpShow = (plates: MugginsPlateState[]) =>
  plates.map((p) => `${p.kind}${p.label ? `:${p.label}` : ""}${p.tick ? "✓" : ""}`).join(" | ");
const mpFor = (ids: string[], claimBy: string | null, confirmedBy?: string[] | null, winnerId?: string | null) =>
  mugginsPlateStates({ order: mpOrder(ids), myId: "a", claimBy, confirmedBy, winnerId });
check("muggins plates: idle -- my plate is I win, the others just their names", () => {
  strictEqual(mpShow(mpFor(MP3, null)), "i-win:I win | idle | idle");
  strictEqual(mpShow(mpFor(MP4, null)), "i-win:I win | idle | idle | idle");
  strictEqual(mpFor(MP4, null)[0].action, "claim");
  for (const p of mpFor(MP4, null).slice(1)) strictEqual(p.action, null);
  // A stale row (no win_confirmed_by) and null read as nobody.
  strictEqual(mpShow(mpFor(MP4, null, undefined)), mpShow(mpFor(MP4, null, [])));
  strictEqual(mpShow(mpFor(MP4, null, null)), mpShow(mpFor(MP4, null, [])));
});
check("muggins plates: I claimed -- Waiting (tap to cancel); ticks as the others confirm", () => {
  strictEqual(mpShow(mpFor(MP3, "a")), "waiting:Waiting… (tap to cancel) | idle | idle");
  strictEqual(mpFor(MP3, "a")[0].action, "cancel");
  strictEqual(mpShow(mpFor(MP4, "a", ["c"])), "waiting:Waiting… (tap to cancel) | idle | confirmed✓ | idle");
  strictEqual(mpShow(mpFor(MP4, "a", ["c", "b"])), "waiting:Waiting… (tap to cancel) | confirmed✓ | confirmed✓ | idle");
  strictEqual(mpShow(mpFor(MP3, "a", undefined)), "waiting:Waiting… (tap to cancel) | idle | idle");
});
check("muggins plates: someone else claimed -- Claims the win on theirs, Confirm loss on mine", () => {
  strictEqual(mpShow(mpFor(MP3, "b")), "confirm-loss:Confirm loss | claims:Claims the win | idle");
  strictEqual(mpShow(mpFor(MP4, "c")), "confirm-loss:Confirm loss | idle | claims:Claims the win | idle");
  strictEqual(mpFor(MP4, "c")[0].action, "confirm");
  // Another player (not me) has confirmed: their tick, my button unchanged.
  strictEqual(mpShow(mpFor(MP4, "c", ["d"])), "confirm-loss:Confirm loss | idle | claims:Claims the win | confirmed✓");
  strictEqual(mpShow(mpFor(MP3, "b", ["c"])), "confirm-loss:Confirm loss | claims:Claims the win | confirmed✓");
  // Stale row: nobody confirmed yet.
  strictEqual(mpShow(mpFor(MP4, "c", undefined)), "confirm-loss:Confirm loss | idle | claims:Claims the win | idle");
});
check("muggins plates: I confirmed -- ✓ Confirmed, nothing to tap; the others' ticks", () => {
  strictEqual(mpShow(mpFor(MP3, "b", ["a"])), "confirmed-mine:✓ Confirmed | claims:Claims the win | idle");
  strictEqual(mpFor(MP3, "b", ["a"])[0].action, null);
  strictEqual(mpShow(mpFor(MP4, "b", ["a"])), "confirmed-mine:✓ Confirmed | claims:Claims the win | idle | idle");
  strictEqual(mpShow(mpFor(MP4, "b", ["d", "a"])), "confirmed-mine:✓ Confirmed | claims:Claims the win | idle | confirmed✓");
  // The claimant never shows a tick, whatever the array says.
  strictEqual(mpShow(mpFor(MP4, "b", ["b"])), "confirm-loss:Confirm loss | claims:Claims the win | idle | idle");
});
check("muggins plates: game over -- Won on the winner's plate, nothing to tap", () => {
  strictEqual(mpShow(mpFor(MP3, null, [], "b")), "over-mine | won:Won | over");
  strictEqual(mpShow(mpFor(MP4, null, [], "a")), "won-mine:Won | over | over | over");
  strictEqual(mpShow(mpFor(MP4, null, [], "d")), "over-mine | over | over | won:Won");
  for (const p of mpFor(MP4, null, [], "d")) strictEqual(p.action, null);
  // A leftover claim or confirmation on the row never shows on a final board.
  strictEqual(mpShow(mpFor(MP4, "c", ["b"], "c")), "over-mine | over | won:Won | over");
});
check("muggins plates: long names are kept whole (the plates ellipsize them) and change nothing else", () => {
  const long = (id: string) => `${id.toUpperCase()}${"x".repeat(29)}`;
  for (const ids of [MP3, MP4]) {
    for (const [claim, conf, won] of [
      [null, [], null],
      ["b", [], null],
      ["b", ["a"], null],
      [null, [], "b"],
    ] as [string | null, string[], string | null][]) {
      const plates = mugginsPlateStates({ order: mpOrder(ids, long), myId: "a", claimBy: claim, confirmedBy: conf, winnerId: won });
      strictEqual(mpShow(plates), mpShow(mpFor(ids, claim, conf, won)), `${ids.length} ${claim} ${conf} ${won}`);
      for (const p of plates) strictEqual(p.name.length, 30);
    }
  }
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
// THE S BOARD (lib/boardLayout.ts) and the board's pattern.
check("board pattern: Straight is unchanged (every hole and size, fingerprinted before the S)", () => {
  // Taken from the straight board before the S pattern was added: each
  // size's peg and hole radii, pitch and every hole, to 4 places.
  const expected: Record<string, [number, number]> = {
    "375x67": [6132, -1273785418],
    "390x84": [6135, 1432211088],
    "502x108": [6221, 1179808240],
    "896x108": [6252, 2136128248],
  };
  for (const [key, [len, hash]] of Object.entries(expected)) {
    const [w, h] = key.split("x").map(Number);
    const g = boardGeometry(w, h);
    const s = [g.pegR, g.holeR, g.pitch, ...boardHoles(g).flatMap((p) => [p.x, p.y])].map((n) => n.toFixed(4)).join(",");
    let x = 0;
    for (let i = 0; i < s.length; i++) x = (x * 31 + s.charCodeAt(i)) | 0;
    deepStrictEqual([s.length, x], [len, hash], key);
    // Through the pattern-aware calls too.
    const any = boardGeometryFor("straight", w, h);
    strictEqual(isSBoard(any), false);
    deepStrictEqual(pegPosition(any, 1, 37, 0), holePosition(g, 1, 37, 0));
  }
});
check("S board: positions 0 .. 121 in every lane, in order along the path", () => {
  for (const v of Object.values(S_VARIANTS)) {
    const t = sTrack(v);
    strictEqual(t.lanes.length, 3);
    for (const lane of t.lanes) {
      strictEqual(lane.holes.length, 122, v.id);
      strictEqual(lane.holeAlong.length, 122);
      for (let s = 1; s < 122; s++) strictEqual(lane.holeAlong[s] > lane.holeAlong[s - 1], true, `${v.id} ${s}`);
      // Start near the path's start, the game hole near its end.
      strictEqual(lane.holeAlong[0] > 0 && lane.holeAlong[121] < lane.length, true);
      // A wider gap after every fifth hole.
      const step = lane.holeAlong[2] - lane.holeAlong[1];
      strictEqual(lane.holeAlong[6] - lane.holeAlong[5] > step * 1.3, true);
    }
  }
});
check("S board: holes in a lane at least 4px apart at 375 wide (and at 390, 502)", () => {
  for (const [w, h] of [[375, 67], [375, 66.7], [390, 84], [502, 108]]) {
    const g = sBoardGeometry(w, h);
    for (const lane of g.lanes) {
      for (let i = 0; i < lane.holes.length; i++) {
        for (let j = i + 1; j < lane.holes.length; j++) {
          const d = Math.hypot(lane.holes[i].x - lane.holes[j].x, lane.holes[i].y - lane.holes[j].y);
          strictEqual(d >= 4, true, `${w}x${h}: holes ${i} and ${j} ${d.toFixed(2)}px`);
        }
      }
    }
  }
});
check("S board: no two lanes closer than LS - 0.5 anywhere, the ribbon tips included", () => {
  for (const v of Object.values(S_VARIANTS)) {
    const t = sTrack(v);
    // Every 4th point (1 view unit), all pairs between different lanes.
    const minBetween = (from: (l: (typeof t.lanes)[number], d: number) => boolean) => {
      const pts = t.lanes.map((l) => l.points.filter((_, i) => i % 4 === 0 && from(l, l.along[i])));
      let min = Infinity;
      for (let a = 0; a < 3; a++) {
        for (let b = a + 1; b < 3; b++) {
          for (const p of pts[a]) for (const q of pts[b]) min = Math.min(min, Math.hypot(p.x - q.x, p.y - q.y));
        }
      }
      return min;
    };
    // Where the holes and pegs are: never under LS - 0.5 (in fact LS).
    const playing = minBetween((l, d) => d >= l.holeAlong[0] && d <= l.holeAlong[121]);
    strictEqual(playing >= v.LS - 0.5, true, `${v.id}: ${playing.toFixed(2)}`);
    // The whole ribbon, the bare tips before the start hole and after the
    // game hole included (x0 = 212.2 - R keeps them clear).
    const whole = minBetween(() => true);
    strictEqual(whole >= v.LS - 0.5, true, `${v.id} whole ribbon: ${whole.toFixed(2)}`);
  }
});
check("S board: the plates sit on the middle lane, between holes 5k and 5k + 1", () => {
  for (const v of Object.values(S_VARIANTS)) {
    const t = sTrack(v);
    strictEqual(t.plates.length, 23);
    const mid = t.lanes[1];
    for (const p of t.plates) {
      const near = Math.min(...mid.points.map((q) => Math.hypot(p.x - q.x, p.y - q.y)));
      strictEqual(near < 0.5, true, `${v.id} plate ${p.label}`);
      const a = mid.holes[p.label];
      const b = mid.holes[p.label + 1];
      // Nearer those two holes than any other.
      const da = Math.hypot(p.x - a.x, p.y - a.y);
      const db = Math.hypot(p.x - b.x, p.y - b.y);
      strictEqual(Math.abs(da - db) < 1, true);
      strictEqual(t.plateRx < da - v.holeR, true, `${v.id} plate ${p.label} clear of its holes`);
    }
  }
});
check("S board: fits the strip whole, the right variant for its shape, pegs at the 9.8px floor", () => {
  strictEqual(sVariantFor(502, 108).id, "sflat");
  strictEqual(sVariantFor(390, 84).id, "sflat");
  strictEqual(sVariantFor(375, 67).id, "sflat2");
  for (const [w, h] of [[375, 67], [390, 84], [502, 108], [896, 86]]) {
    const g = sBoardGeometry(w, h);
    strictEqual(g.board.x >= -0.01 && g.board.x + g.board.width <= w + 0.01, true);
    strictEqual(g.board.y >= -0.01 && g.board.y + g.board.height <= h + 0.01, true);
    strictEqual(g.pegR >= PEG_MIN_R, true);
    // Every hole inside the board, with room for a peg.
    for (const lane of g.lanes) {
      for (const p of lane.holes) {
        strictEqual(p.x - g.pegR >= g.board.x && p.x + g.pegR <= g.board.x + g.board.width, true);
        strictEqual(p.y - g.pegR >= g.board.y && p.y + g.pegR <= g.board.y + g.board.height, true);
      }
    }
    deepStrictEqual(pegPosition(g, 2, 121, 1), sHolePosition(g, 2, 121));
    // One start hole: both pegs start on it.
    deepStrictEqual(pegPosition(g, 0, 0, 0), pegPosition(g, 0, 0, 1));
  }
});
check("S board: every skin's pegs and holes read on its ribbons (same floors and exemptions)", () => {
  for (const s of BOARD_SKIN_LIST) {
    for (const lane of [0, 1, 2]) {
      const surface = sRibbonFill(s, lane);
      if (!pegContrastExempt(s)) {
        const ratio = contrastRatio(s.lanes[lane].peg, surface);
        strictEqual(ratio >= PEG_CONTRAST_MIN, true, `${s.id} lane ${lane} peg: ${ratio.toFixed(2)}`);
      }
      if (!holeContrastExempt(s)) {
        const ratio = contrastRatio(s.hole.fill, surface);
        strictEqual(ratio >= HOLE_CONTRAST_MIN, true, `${s.id} lane ${lane} hole: ${ratio.toFixed(2)}`);
      }
    }
  }
  // Midnight's ribbon is its dark panel, outlined.
  strictEqual(sRibbonFill(boardSkinById("midnight"), 0), "#1d1d23");
});
check("S board: a peg's slide follows its lane (round the turns, across the S, backward too)", () => {
  // The distance from a point to a lane's line (view units).
  const offLane = (points: { x: number; y: number }[], p: { x: number; y: number }) =>
    Math.min(...points.map((q) => Math.hypot(p.x - q.x, p.y - q.y)));
  for (const v of Object.values(S_VARIANTS)) {
    const t = sTrack(v);
    // Through the first hairpin (3 -> 25), across the middle S (55 -> 66),
    // the 2-peg leapfrog's long jump (0 -> 29), the last turn (100 -> 121)
    // and a correction backward (66 -> 52).
    for (const [from, to] of [[3, 25], [55, 66], [0, 29], [100, 121], [66, 52], [121, 0]]) {
      for (const lane of [0, 1, 2]) {
        const pts = sSlidePoints(v, lane, from, to);
        const line = t.lanes[lane].points;
        // Starts and ends on the holes.
        strictEqual(Math.hypot(pts[0].x - t.lanes[lane].holes[from].x, pts[0].y - t.lanes[lane].holes[from].y) < 1e-6, true);
        const end = pts[pts.length - 1];
        strictEqual(Math.hypot(end.x - t.lanes[lane].holes[to].x, end.y - t.lanes[lane].holes[to].y) < 1e-6, true);
        // Sampled partway (a third, half, two-thirds): on the lane's line.
        for (const f of [1 / 3, 1 / 2, 2 / 3]) {
          const p = pts[Math.round((pts.length - 1) * f)];
          const off = offLane(line, p);
          strictEqual(off < 0.5, true, `${v.id} lane ${lane} ${from}->${to} at ${f.toFixed(2)}: ${off.toFixed(3)}`);
        }
        // Evenly spaced along the lane, never jumping across the board.
        const steps = pts.slice(1).map((p, i) => Math.hypot(p.x - pts[i].x, p.y - pts[i].y));
        strictEqual(Math.max(...steps) <= 2.05, true, `${v.id} ${from}->${to} step ${Math.max(...steps).toFixed(2)}`);
      }
    }
    // Backward is the forward slide reversed (to rounding).
    const back = sSlidePoints(v, 1, 66, 52).reverse();
    const fwd = sSlidePoints(v, 1, 52, 66);
    strictEqual(back.length, fwd.length);
    strictEqual(back.every((p, i) => Math.hypot(p.x - fwd[i].x, p.y - fwd[i].y) < 1e-9), true);
  }
  // In px on a board: the same path scaled.
  const g = sBoardGeometry(375, 67);
  const frames = pegSlideFrames(g, 2, 55, 66)!;
  deepStrictEqual(frames[frames.length - 1], sHolePosition(g, 2, 66));
});
check("board pattern: the S and the snake as drawn (every hole, plate, line point and a slide, fingerprinted)", () => {
  // Taken when the S and the snake were stretched to the strip's width
  // (trackStretch); a change to either board shows here.
  const fp = (nums: number[]) => {
    const s = nums.map((n) => n.toFixed(4)).join(",");
    let x = 0;
    for (let i = 0; i < s.length; i++) x = (x * 31 + s.charCodeAt(i)) | 0;
    return [s.length, x];
  };
  const expected: Record<string, [number, number]> = {
    "375x67": [79725, 1103962872],
    "390x84": [75769, 1254954566],
    "502x108": [76175, 1876352292],
    "896x86": [149772, -347375122],
  };
  const expectedSnake: Record<string, [number, number]> = {
    "375x67": [84813, 1345305158],
    "390x84": [71037, 592824981],
    "502x108": [71412, -1917070306],
    "896x86": [159247, -1042515116],
  };
  for (const [key, want] of Object.entries(expectedSnake)) {
    const [w, h] = key.split("x").map(Number);
    const g = sBoardGeometry(w, h, SNAKE_VARIANT);
    const nums = [
      g.board.x, g.board.y, g.board.width, g.board.height, g.pegR, g.holeR, g.ribbonWidth, g.plateRx, g.plateRy,
      ...g.lanes.flatMap((l) => [...l.holes, ...l.path].flatMap((p) => [p.x, p.y])),
      ...g.plates.flatMap((p) => [p.x, p.y, p.angle]),
    ];
    deepStrictEqual(fp(nums), want, `snake ${key}`);
  }
  deepStrictEqual(fp(sSlidePoints(SNAKE_VARIANT, 1, 30, 52).flatMap((p) => [p.x, p.y])), [2929, -1284831856]);
  for (const [key, want] of Object.entries(expected)) {
    const [w, h] = key.split("x").map(Number);
    const g = sBoardGeometry(w, h);
    const nums = [
      g.board.x, g.board.y, g.board.width, g.board.height, g.pegR, g.holeR, g.ribbonWidth, g.plateRx, g.plateRy,
      ...g.lanes.flatMap((l) => [...l.holes, ...l.path].flatMap((p) => [p.x, p.y])),
      ...g.plates.flatMap((p) => [p.x, p.y, p.angle]),
    ];
    deepStrictEqual(fp(nums), want, key);
    // The S through the pattern call is the same board.
    deepStrictEqual(boardGeometryFor("s", w, h), g);
  }
  deepStrictEqual(fp(sSlidePoints(S_VARIANTS.sflat, 1, 55, 66).flatMap((p) => [p.x, p.y])), [1668, -548985297]);
});

check("S and snake: drawn as wide as the straight board in the same strip, lanes unchanged", () => {
  // The straight board fills the strip (its width); the track boards are
  // stretched to match (trackStretch), up to TRACK_ASPECT_MAX : 1.
  for (const [w, h] of [[375, 66.7], [375, 67], [390, 84], [502, 108], [896, 86.4], [896, 86]]) {
    const straight = boardGeometry(w, h).width;
    for (const [name, g] of [
      ["S", sBoardGeometry(w, h)],
      ["snake", sBoardGeometry(w, h, SNAKE_VARIANT)],
    ] as const) {
      strictEqual(Math.abs(g.board.width - straight) <= 1, true, `${name} ${w}x${h}: ${g.board.width.toFixed(1)} vs ${straight}`);
      // Height sets the scale, so the lane spacing is as before.
      strictEqual(Math.abs(g.laneGap - (g.variant.LS * h) / g.variant.H) < 1e-6, true);
      strictEqual(g.board.height <= h + 0.01, true);
    }
  }
  // Never narrower than the unstretched board; capped on a very wide strip
  // (a landscape phone's, ~21 : 1), where the board is centred.
  strictEqual(trackStretch(300, 100, 215, 877), 0);
  const phone = sBoardGeometry(844, 39);
  strictEqual(Math.abs(phone.board.width / phone.board.height - TRACK_ASPECT_MAX) < 1e-6, true);
  strictEqual(Math.abs(phone.board.x - (844 - phone.board.width) / 2) < 1e-6, true);
  // The most-stretched boards still keep their lanes apart, their plates on
  // the middle lane and clear of the holes, and their pegs on the board.
  for (const g of [phone, sBoardGeometry(844, 39, SNAKE_VARIANT)]) {
    const t = sTrack(g.variant, g.stretch);
    const pts = t.lanes.map((l) => l.points.filter((_, i) => i % 8 === 0));
    let min = Infinity;
    for (let a = 0; a < 3; a++) {
      for (let b = a + 1; b < 3; b++) for (const p of pts[a]) for (const q of pts[b]) min = Math.min(min, Math.hypot(p.x - q.x, p.y - q.y));
    }
    strictEqual(min >= g.variant.LS - 0.5, true, `${g.variant.id}: ${min.toFixed(2)}`);
    const mid = t.lanes[1];
    for (const p of t.plates) {
      const da = Math.hypot(p.x - mid.holes[p.label].x, p.y - mid.holes[p.label].y);
      strictEqual(t.plateRx < da - g.variant.holeR && t.plateRx <= t.plateRy, true);
    }
  }
});

// THE SNAKE BOARD (lib/boardLayout.ts: SNAKE_VARIANT, built like the S).
check("snake board: the track as specified (LS 17, D, YC, H, three right turns' worth of lanes)", () => {
  const v = SNAKE_VARIANT;
  strictEqual(v.LS, 17);
  strictEqual(Math.abs(v.R - (2 * 17 + 15.8 + 8)) < 1e-9, true);
  strictEqual(Math.abs(v.H - (3 + v.R + 17 + 7.9 + 14 + v.R + 17 + 7.9 + 14 + 3)) < 1e-9, true);
  const t = sTrack(v);
  // It only turns right (a full turn in all), so each lane is 2 pi LS
  // shorter than the one outside it.
  strictEqual(Math.abs(t.lanes[0].length - t.lanes[1].length - 2 * Math.PI * 17) < 0.5, true);
  strictEqual(Math.abs(t.lanes[1].length - t.lanes[2].length - 2 * Math.PI * 17) < 0.5, true);
  // Starts top left heading east; finishes in the middle band, inside the U.
  const mid = t.lanes[1];
  strictEqual(Math.abs(mid.points[0].x - 100) < 1e-9 && mid.points[0].y < mid.points[mid.points.length - 1].y, true);
  for (const [w, h] of [[502, 108], [375, 67]]) {
    const g = boardGeometryFor("snake", w, h);
    strictEqual(isSBoard(g) && g.variant.id === "snake", true);
  }
});
check("snake board: positions 0 .. 121 in every lane, in order along the path", () => {
  const t = sTrack(SNAKE_VARIANT);
  for (const lane of t.lanes) {
    strictEqual(lane.holes.length, 122);
    for (let s = 1; s < 122; s++) strictEqual(lane.holeAlong[s] > lane.holeAlong[s - 1], true, `${s}`);
    strictEqual(lane.holeAlong[0] > 0 && lane.holeAlong[121] < lane.length, true);
    const step = lane.holeAlong[2] - lane.holeAlong[1];
    strictEqual(lane.holeAlong[6] - lane.holeAlong[5] > step * 1.3, true);
  }
});
check("snake board: holes in a lane at least 4px apart at 375, 390 and 502, every lane", () => {
  const minPerLane = (w: number, h: number) =>
    sBoardGeometry(w, h, SNAKE_VARIANT).lanes.map((lane) => {
      let min = Infinity;
      for (let i = 0; i < lane.holes.length; i++) {
        for (let j = i + 1; j < lane.holes.length; j++) {
          min = Math.min(min, Math.hypot(lane.holes[i].x - lane.holes[j].x, lane.holes[i].y - lane.holes[j].y));
        }
      }
      return min;
    });
  for (const [w, h] of [[375, 67], [375, 66.7], [390, 84], [502, 108]]) {
    minPerLane(w, h).forEach((d, lane) => strictEqual(d >= 4, true, `${w}x${h} lane ${lane}: ${d.toFixed(2)}px`));
  }
});
check("snake board: no two lanes closer than LS - 0.5 anywhere, the whole ribbon", () => {
  const v = SNAKE_VARIANT;
  const pts = sTrack(v).lanes.map((l) => l.points.filter((_, i) => i % 4 === 0));
  let min = Infinity;
  for (let a = 0; a < 3; a++) {
    for (let b = a + 1; b < 3; b++) for (const p of pts[a]) for (const q of pts[b]) min = Math.min(min, Math.hypot(p.x - q.x, p.y - q.y));
  }
  strictEqual(min >= v.LS - 0.5, true, min.toFixed(2));
});
check("snake board: plates on the middle lane, clear of their holes", () => {
  const v = SNAKE_VARIANT;
  const t = sTrack(v);
  strictEqual(t.plates.length, 23);
  const mid = t.lanes[1];
  for (const p of t.plates) {
    strictEqual(Math.min(...mid.points.map((q) => Math.hypot(p.x - q.x, p.y - q.y))) < 0.5, true, `plate ${p.label}`);
    const da = Math.hypot(p.x - mid.holes[p.label].x, p.y - mid.holes[p.label].y);
    const db = Math.hypot(p.x - mid.holes[p.label + 1].x, p.y - mid.holes[p.label + 1].y);
    strictEqual(Math.abs(da - db) < 1, true);
    strictEqual(t.plateRx < da - v.holeR, true, `plate ${p.label} clear of its holes`);
  }
});
check("snake board: fits the strip whole, pegs at the 9.8px floor and inside the board", () => {
  for (const [w, h] of [[375, 67], [390, 84], [502, 108], [896, 86]]) {
    const g = sBoardGeometry(w, h, SNAKE_VARIANT);
    strictEqual(g.board.x >= -0.01 && g.board.x + g.board.width <= w + 0.01, true);
    strictEqual(g.board.y >= -0.01 && g.board.y + g.board.height <= h + 0.01, true);
    strictEqual(g.pegR >= PEG_MIN_R, true);
    for (const lane of g.lanes) {
      for (const p of lane.holes) {
        strictEqual(p.x - g.pegR >= g.board.x && p.x + g.pegR <= g.board.x + g.board.width, true);
        strictEqual(p.y - g.pegR >= g.board.y && p.y + g.pegR <= g.board.y + g.board.height, true);
      }
    }
    deepStrictEqual(pegPosition(g, 0, 0, 0), pegPosition(g, 0, 0, 1));
  }
});
check("snake board: a peg's slide follows its lane (the big U, the small hairpin, backward), stretched too", () => {
  const v = SNAKE_VARIANT;
  const offLane = (points: { x: number; y: number }[], p: { x: number; y: number }) =>
    Math.min(...points.map((q) => Math.hypot(p.x - q.x, p.y - q.y)));
  // Unstretched, and as drawn on the 375 and wide landscape strips.
  for (const stretch of [0, sBoardGeometry(375, 67, v).stretch, sBoardGeometry(896, 86, v).stretch]) {
  const t = sTrack(v, stretch);
  // Where each turn is, by position on the middle lane: the big U, then
  // the small hairpin -- found from this track's band length.
  const mid = t.lanes[1];
  const posAt = (d: number) => mid.holeAlong.findIndex((a) => a >= d);
  const band = 520 + stretch;
  const topEnd = band;
  const uEnd = topEnd + Math.PI * v.R;
  const hairpinStart = uEnd + band;
  const hairpinEnd = hairpinStart + (Math.PI * v.R) / 2;
  const throughU = [posAt(topEnd) - 3, posAt(uEnd) + 3];
  const throughHairpin = [posAt(hairpinStart) - 3, posAt(hairpinEnd) + 3];
  for (const [from, to] of [throughU, throughHairpin, [0, 29], [throughHairpin[1], throughU[0]], [121, 0]]) {
    for (const lane of [0, 1, 2]) {
      const pts = sSlidePoints(v, lane, from, to, stretch);
      const l = t.lanes[lane];
      strictEqual(Math.hypot(pts[0].x - l.holes[from].x, pts[0].y - l.holes[from].y) < 1e-6, true);
      const end = pts[pts.length - 1];
      strictEqual(Math.hypot(end.x - l.holes[to].x, end.y - l.holes[to].y) < 1e-6, true);
      for (const f of [1 / 3, 1 / 2, 2 / 3]) {
        const p = pts[Math.round((pts.length - 1) * f)];
        const off = offLane(l.points, p);
        strictEqual(off < 0.5, true, `lane ${lane} ${from}->${to} at ${f.toFixed(2)}: ${off.toFixed(3)}`);
      }
      const steps = pts.slice(1).map((p, i) => Math.hypot(p.x - pts[i].x, p.y - pts[i].y));
      strictEqual(Math.max(...steps) <= 2.05, true);
    }
  }
  }
  // In px on a stretched board: the slide ends on the hole as drawn.
  const g = sBoardGeometry(375, 67, v);
  const frames = pegSlideFrames(g, 2, 30, 52)!;
  deepStrictEqual(frames[frames.length - 1], sHolePosition(g, 2, 52));
});
check("snake board: every skin's pegs and holes read on its ribbons; plates show on Mahogany and Midnight", () => {
  // The same ribbons as the S (sRibbonFill), so the same floors and
  // exemptions.
  for (const s of BOARD_SKIN_LIST) {
    for (const lane of [0, 1, 2]) {
      const surface = sRibbonFill(s, lane);
      if (!pegContrastExempt(s)) strictEqual(contrastRatio(s.lanes[lane].peg, surface) >= PEG_CONTRAST_MIN, true, s.id);
      if (!holeContrastExempt(s)) strictEqual(contrastRatio(s.hole.fill, surface) >= HOLE_CONTRAST_MIN, true, s.id);
    }
    // A plate either stands out from the middle ribbon or has an edge that
    // does.
    const plate = sPlateColors(s);
    const ribbon = sRibbonFill(s, 1);
    strictEqual(contrastRatio(plate.fill, ribbon) >= 1.5 || (!!plate.edge && contrastRatio(plate.edge, ribbon) >= 1.5), true, s.id);
  }
  strictEqual(sPlateColors(boardSkinById("mahogany")).edge !== null, true);
  strictEqual(sPlateColors(boardSkinById("midnight")).edge !== null, true);
});
check("board pattern: Straight's slide is unchanged (its own CSS transition, no path)", () => {
  for (const [w, h] of [[375, 67], [502, 108]]) {
    const g = boardGeometryFor("straight", w, h);
    strictEqual(pegSlideFrames(g, 0, 3, 25), null);
    strictEqual(pegSlideFrames(g, 2, 66, 52), null);
  }
});
check("board pattern setting: unknown or missing is Straight, storage never throws", () => {
  strictEqual(boardPatternById("s"), "s");
  strictEqual(boardPatternById("straight"), "straight");
  strictEqual(boardPatternById(null), "straight");
  strictEqual(boardPatternById(undefined), "straight");
  strictEqual(boardPatternById("spiral"), "straight");
  strictEqual(boardPatternById("S"), "straight");
  strictEqual(boardPatternById("snake"), "snake");
  strictEqual(boardPatternById("Snake"), "straight");
  strictEqual(readBoardPattern(), "straight");
  writeBoardPattern("s");
  const store = new Map<string, string>();
  const g = globalThis as unknown as { localStorage?: unknown };
  g.localStorage = {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v),
    removeItem: (k: string) => void store.delete(k),
  };
  try {
    writeBoardPattern("s");
    strictEqual(store.get(BOARD_PATTERN_KEY), "s");
    strictEqual(readBoardPattern(), "s");
    // The colours keep their own key.
    strictEqual(store.has(BOARD_SETTING_KEY), false);
    store.set(BOARD_PATTERN_KEY, "zigzag");
    strictEqual(readBoardPattern(), "straight");
    writeBoardPattern("straight");
    strictEqual(store.has(BOARD_PATTERN_KEY), false);
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
    strictEqual(readBoardPattern(), "straight");
    writeBoardPattern("s");
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

// TABLE LISTS (lib/tableListing.ts): the admin rows and Open Tables.
check("admin label: seated/max, then Teams or Solo for 4 players, then Self-Scoring", () => {
  const label = (seated: number, maxPlayers: number, teamMode: string | null, isMuggins: boolean) =>
    adminTableLabel({ seated, maxPlayers, teamMode, isMuggins });
  strictEqual(label(1, 2, "teams", false), "1/2 seated");
  strictEqual(label(2, 3, "teams", false), "2/3 seated");
  strictEqual(label(3, 3, "solo", true), "3/3 seated · Self-Scoring");
  strictEqual(label(4, 4, "teams", false), "4/4 seated · Teams");
  strictEqual(label(0, 4, "solo", false), "0/4 seated · Solo");
  strictEqual(label(1, 4, "solo", true), "1/4 seated · Solo · Self-Scoring");
  strictEqual(label(2, 2, null, true), "2/2 seated · Self-Scoring");
});
check("admin names: seat order, nickname trimmed, never an id", () => {
  deepStrictEqual(
    seatedNames([
      { seat: 3, nickname: "Kim" },
      { seat: 1, nickname: "  Walt " },
      { seat: 2, nickname: "God" },
    ]),
    ["Walt", "God", "Kim"]
  );
  // No nickname (null, blank, unread): the app's "A player"; no seat yet: last.
  deepStrictEqual(
    seatedNames([
      { seat: null, nickname: "Late" },
      { seat: 2, nickname: "  " },
      { seat: 1, nickname: undefined },
    ]),
    ["A player", "A player", "Late"]
  );
  deepStrictEqual(seatedNames([]), []);
  // Long names are kept whole (the row wraps them).
  strictEqual(seatedNames([{ seat: 1, nickname: "W".repeat(30) }])[0], "W".repeat(30));
});
check("Open Tables age filter: waiting tables older than 2 hours hide, live ones never", () => {
  strictEqual(STALE_WAITING_TABLE_MS, 2 * 60 * 60 * 1000);
  const now = Date.parse("2026-11-02T20:00:00Z");
  const ago = (ms: number) => new Date(now - ms).toISOString();
  strictEqual(isStaleWaitingTable({ createdAt: ago(5 * 60 * 1000), gameLive: false }, now), false);
  strictEqual(isStaleWaitingTable({ createdAt: ago(STALE_WAITING_TABLE_MS), gameLive: false }, now), false);
  strictEqual(isStaleWaitingTable({ createdAt: ago(STALE_WAITING_TABLE_MS + 1000), gameLive: false }, now), true);
  strictEqual(isStaleWaitingTable({ createdAt: ago(11 * 60 * 60 * 1000), gameLive: false }, now), true);
  // In play: never hidden, however old.
  strictEqual(isStaleWaitingTable({ createdAt: ago(11 * 60 * 60 * 1000), gameLive: true }, now), false);
  // An unreadable time hides nothing.
  strictEqual(isStaleWaitingTable({ createdAt: "not a date", gameLive: false }, now), false);
});

// A WON GAME'S RESULT AFTER A REJOIN (lib/resultScores.ts).
check("rejoin: a seat joined after the game began doesn't hold its score; older, equal or bad times do", () => {
  const game = "2026-11-03T20:00:00.000Z";
  strictEqual(scoreFromThisGame("2026-11-03T19:59:00.000Z", game), true); // seat older: reliable
  strictEqual(scoreFromThisGame("2026-11-03T20:10:00.000Z", game), false); // left and came back
  strictEqual(scoreFromThisGame(game, game), true); // equal: reliable
  // Missing or unreadable: never hide.
  strictEqual(scoreFromThisGame(null, game), true);
  strictEqual(scoreFromThisGame("2026-11-03T20:10:00.000Z", null), true);
  strictEqual(scoreFromThisGame(undefined, undefined), true);
  strictEqual(scoreFromThisGame("not a date", game), true);
  strictEqual(scoreFromThisGame("2026-11-03T20:10:00.000Z", "garbage"), true);
  // Different formats of the same moment (a REST read vs a realtime payload).
  strictEqual(scoreFromThisGame("2026-11-03 20:00:00+00", game), true);
  // A rematch: New Game is created after everyone already sits there, so
  // nobody's score is hidden on its result.
  const seats = ["2026-11-03T18:00:00Z", "2026-11-03T18:05:00Z"];
  const rematch = "2026-11-03T21:00:00Z";
  for (const joined of seats) strictEqual(scoreFromThisGame(joined, rematch), true);
});
check("rejoin: only the rejoined players' plates are blanked; a Teams plate only if both partners rejoined", () => {
  const plate = (key: string, ids: string[], score: number) => ({
    key,
    members: ids.map((userId) => ({ userId, name: userId, avatarUrl: null })),
    score,
    isMine: false,
    hasDealer: false,
    lastPoints: null,
    lastReason: null,
    lastAwardedAt: null,
  });
  const solo = [plate("a", ["a"], 121), plate("b", ["b"], 0), plate("c", ["c"], 98)];
  deepStrictEqual(
    hideRejoinedScores(solo, new Set(["b"])).map((p) => `${p.key}:${p.scoreHidden ? "-" : p.score}`),
    ["a:121", "b:-", "c:98"]
  );
  // Nobody rejoined: the very same plates.
  strictEqual(hideRejoinedScores(solo, new Set()), solo);
  // Teams: the partner who stayed still holds the team score.
  const teams = [plate("team-1", ["a", "c"], 121), plate("team-2", ["b", "d"], 90)];
  deepStrictEqual(
    hideRejoinedScores(teams, new Set(["a"])).map((p) => `${p.key}:${p.scoreHidden ? "-" : p.score}`),
    ["team-1:121", "team-2:90"]
  );
  deepStrictEqual(
    hideRejoinedScores(teams, new Set(["b", "d"])).map((p) => `${p.key}:${p.scoreHidden ? "-" : p.score}`),
    ["team-1:121", "team-2:-"]
  );
});

// TABLE SYNC (lib/tableSync.ts): fewer requests, same screen.
check("table sync: the safety poll is 12 s until realtime is connected, 30 s while it is", () => {
  strictEqual(SAFETY_POLL_MS, 12_000);
  strictEqual(SAFETY_POLL_CONNECTED_MS, 30_000);
  strictEqual(pollIntervalMs(false), 12_000);
  strictEqual(pollIntervalMs(true), 30_000);
});
check("table sync: profiles read for new seats, moved seats and missing names; never for the rest", () => {
  const shown = [
    { user_id: "a", seat: 1, nickname: "Walt" },
    { user_id: "b", seat: 2, nickname: "Yoda" },
    { user_id: "c", seat: 3, nickname: null }, // its profile read never landed
  ];
  const rows = [
    { user_id: "a", seat: 1 }, // unchanged: skipped
    { user_id: "b", seat: 4 }, // moved seat
    { user_id: "c", seat: 3 }, // no name yet
    { user_id: "d", seat: 2 }, // a new seat (or a rejoin)
  ];
  deepStrictEqual(profilesToFetch(rows, shown, false), ["b", "c", "d"]);
  // The poll, as before: only players not on screen.
  deepStrictEqual(profilesToFetch(rows, shown, true), ["d"]);
  // The first load (nothing on screen): everyone.
  deepStrictEqual(profilesToFetch(rows, [], false), ["a", "b", "c", "d"]);
  // Everyone shown, named and seated as read: nothing.
  deepStrictEqual(profilesToFetch([{ user_id: "a", seat: 1 }], shown, false), []);
});
check("table sync: the won board is kept only for the same game read in full", () => {
  const shown = (id: string, complete?: boolean) => ({ id, board: complete === undefined ? {} : { complete } });
  strictEqual(wonBoardReusable(shown("g1", true), "g1"), true);
  strictEqual(wonBoardReusable(shown("g1", true), "g2"), false); // a different game
  strictEqual(wonBoardReusable(shown("g1", false), "g1"), false); // an earlier read failed
  strictEqual(wonBoardReusable(shown("g1"), "g1"), false); // built from the screen at the win
  strictEqual(wonBoardReusable(null, "g1"), false); // nothing on screen: a reload, a rejoin
});

// CONFIRM EMAIL (lib/authFlow.ts).
check("auth: email-not-confirmed by its code or its message; nothing else matches", () => {
  strictEqual(isEmailNotConfirmed({ code: "email_not_confirmed", message: "whatever" }), true);
  strictEqual(isEmailNotConfirmed({ message: "Email not confirmed" }), true);
  strictEqual(isEmailNotConfirmed({ code: null, message: "EMAIL NOT CONFIRMED" }), true);
  strictEqual(isEmailNotConfirmed({ code: "invalid_credentials", message: "Invalid login credentials" }), false);
  strictEqual(isEmailNotConfirmed({ message: "Email rate limit exceeded" }), false);
  strictEqual(isEmailNotConfirmed({}), false);
  strictEqual(isEmailNotConfirmed(null), false);
});
check("auth: an error in the link's hash is read; tokens or nothing are not errors", () => {
  deepStrictEqual(
    readAuthHashError("#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired"),
    { error: "access_denied", code: "otp_expired", description: "Email link is invalid or has expired" }
  );
  // Without the "#", and with a code only.
  deepStrictEqual(readAuthHashError("error_code=otp_expired"), { error: "otp_expired", code: "otp_expired", description: null });
  // A good link: tokens, no error.
  strictEqual(readAuthHashError("#access_token=abc&expires_in=3600&refresh_token=def&token_type=bearer&type=signup"), null);
  strictEqual(readAuthHashError(""), null);
  strictEqual(readAuthHashError("#"), null);
});
check("auth: Resend waits 60 s after each send, counting down in whole seconds", () => {
  strictEqual(RESEND_COOLDOWN_S, 60);
  const sent = 1_000_000;
  strictEqual(resendSecondsLeft(null, sent), 0); // never sent
  strictEqual(resendSecondsLeft(sent, sent), 60); // just sent
  strictEqual(resendSecondsLeft(sent, sent + 30_000), 30);
  strictEqual(resendSecondsLeft(sent, sent + 30_400), 30); // whole seconds
  strictEqual(resendSecondsLeft(sent, sent + 60_000), 0);
  strictEqual(resendSecondsLeft(sent, sent + 90_000), 0);
  strictEqual(resendSecondsLeft(sent, sent - 5_000), 60); // a clock that went back: never above 60
});

// THE NICKNAME GATE (lib/nickname.ts).
check("nickname: no row, no nickname, empty or spaces needs one; a real name doesn't", () => {
  strictEqual(needsNickname(null), true); // no profile row
  strictEqual(needsNickname(undefined), true);
  strictEqual(needsNickname({}), true);
  strictEqual(needsNickname({ nickname: null }), true);
  strictEqual(needsNickname({ nickname: "" }), true);
  strictEqual(needsNickname({ nickname: "   \t " }), true);
  strictEqual(needsNickname({ nickname: "Walt" }), false);
  strictEqual(needsNickname({ nickname: "  Walt " }), false);
});
check("nickname: the save's rules and messages are the Profile page's", () => {
  strictEqual(NICKNAME_MAX_LENGTH, 30);
  strictEqual(nicknameProblem(""), "Please enter a nickname.");
  strictEqual(nicknameProblem("   "), "Please enter a nickname.");
  strictEqual(nicknameProblem(" Walt "), null);
  strictEqual(nicknameProblem("x".repeat(30)), null);
  strictEqual(nicknameProblem(` ${"x".repeat(30)} `), null); // trimmed first
  strictEqual(nicknameProblem("x".repeat(31)), "Nicknames are at most 30 characters.");
  strictEqual(nicknameSaveErrorMessage({ code: "23505", message: "duplicate key value" }), "That nickname is taken.");
  strictEqual(nicknameSaveErrorMessage({ code: "42501", message: "permission denied" }), "permission denied");
  strictEqual(nicknameSaveErrorMessage({ message: "Failed to fetch" }), "Failed to fetch");
});
check("nickname: the return path is a same-site path or the home page", () => {
  // Fine.
  strictEqual(safeReturnPath("/tables/1234"), "/tables/1234");
  strictEqual(safeReturnPath("/tables/new"), "/tables/new");
  strictEqual(safeReturnPath("/single-player"), "/single-player");
  strictEqual(safeReturnPath("/tables/1234?layout=classic"), "/tables/1234?layout=classic");
  strictEqual(safeReturnPath("/"), "/");
  // Open-redirect attempts, and nothing at all: home.
  for (const bad of [
    "//evil.com",
    "https://evil.com",
    "http://evil.com/tables/1234",
    "/\\evil.com",
    "\\\\evil.com",
    "/\t/evil.com",
    "/\n/evil.com",
    " /tables/1234",
    "javascript:alert(1)",
    "JavaScript:alert(1)",
    "tables/1234",
    "",
    null,
    undefined,
    "/" + "x".repeat(600),
  ]) {
    strictEqual(safeReturnPath(bad), "/", JSON.stringify(bad));
  }
});
check("nickname: the step's address carries only a safe return path", () => {
  strictEqual(nicknameStepHref("/tables/1234"), "/nickname?next=%2Ftables%2F1234");
  strictEqual(nicknameStepHref("/tables/new"), "/nickname?next=%2Ftables%2Fnew");
  strictEqual(nicknameStepHref("/"), "/nickname");
  strictEqual(nicknameStepHref("//evil.com"), "/nickname");
  // And back again, as the step reads it.
  strictEqual(safeReturnPath(new URLSearchParams("next=%2Ftables%2F1234").get("next")), "/tables/1234");
  strictEqual(safeReturnPath(new URLSearchParams("next=%2F%2Fevil.com").get("next")), "/");
  strictEqual(safeReturnPath(new URLSearchParams("other=1").get("next")), "/");
});

// GOD-TABLE ZERO SPLASHES (lib/splashPhrases.ts).
check("splash: only the hard level is God", () => {
  strictEqual(isGodLevel("hard"), true);
  for (const level of ["easy", "medium", "Hard", "", null, undefined]) strictEqual(isGodLevel(level), false, String(level));
});
check("splash: a God table gets God's phrases, any other the normal ones, never mixed", () => {
  deepStrictEqual(zeroSplashPhrases(false), ["THAT'S A SHOT BITCH!", "DRINK UP SUCKA!", "SHOT!"]);
  strictEqual(zeroSplashPhrases(false), ZERO_SPLASH_PHRASES);
  deepStrictEqual(zeroSplashPhrases(true), ["THAT'S A SHOT MY CHILD", "DRINK UP MY CHILD", "SHOT! MY CHILD"]);
  strictEqual(zeroSplashPhrases(true), GOD_ZERO_SPLASH_PHRASES);
  for (const phrase of GOD_ZERO_SPLASH_PHRASES) {
    strictEqual(ZERO_SPLASH_PHRASES.includes(phrase), false, phrase);
    strictEqual(phrase, phrase.toUpperCase(), phrase);
  }
});
check("splash: only God's own 0 at a God table is the image", () => {
  strictEqual(zeroSplashKind(true, false), "image");
  strictEqual(zeroSplashKind(true, true), "phrase");
  strictEqual(zeroSplashKind(false, true), "phrase");
  strictEqual(zeroSplashKind(false, false), "phrase"); // a human opponent, or a lower computer level
  strictEqual(GOD_ZERO_SPLASH_IMAGE, "/splashes/god-shot.webp");
});
check("splash: GO lasts 1.2 s, every other splash 3 s", () => {
  strictEqual(SPLASH_MS, 3000);
  strictEqual(GO_SPLASH_MS, 1200);
  strictEqual(splashDurationMs("go"), 1200);
  strictEqual(splashDurationMs("zero"), 3000);
  strictEqual(splashDurationMs("image"), 3000);
});
check("God loss: the boundaries on God's final score", () => {
  strictEqual(godLossSplash("hard", true, 120), "stinkhole");
  strictEqual(godLossSplash("hard", true, 119), null);
  strictEqual(godLossSplash("hard", true, 91), null);
  strictEqual(godLossSplash("hard", true, 90), "skunk");
  strictEqual(godLossSplash("hard", true, 61), "skunk");
  strictEqual(godLossSplash("hard", true, 60), "double-skunk");
  strictEqual(godLossSplash("hard", true, 0), "double-skunk");
});
check("God loss: nothing when God wins, at any other table, or with no score", () => {
  for (const score of [120, 90, 60, 0]) {
    strictEqual(godLossSplash("hard", false, score), null, `God won, ${score}`);
    for (const level of ["easy", "medium", null, undefined]) {
      strictEqual(godLossSplash(level, true, score), null, `${level}, ${score}`);
    }
  }
  strictEqual(godLossSplash("hard", true, null), null);
  strictEqual(godLossSplash("hard", true, undefined), null);
});
check("God loss: each result has its own alt text", () => {
  strictEqual(godLossAlt("skunk"), "God was skunked");
  strictEqual(godLossAlt("double-skunk"), "God was double skunked");
  strictEqual(godLossAlt("stinkhole"), "God was stink holed");
});

// CUSTOM BOARDS (lib/customBoards.ts).
const FOOTBALL = customBoardById("football")!;
check("custom boards: ids unique, an unknown id is no custom board, separate from the skins", () => {
  strictEqual(new Set(CUSTOM_BOARDS.map((b) => b.id)).size, CUSTOM_BOARDS.length);
  strictEqual(CUSTOM_BOARDS.length >= 1, true);
  for (const id of ["nope", "espresso", "", null, undefined]) strictEqual(customBoardById(id), null, String(id));
  strictEqual(BOARD_SKIN_LIST.length, 6);
  for (const b of CUSTOM_BOARDS) strictEqual(BOARD_SKIN_LIST.some((s) => s.id === b.id), false, b.id);
});
check("custom boards: The Football is the Straight layout with one football peg", () => {
  strictEqual(FOOTBALL.name, "The Football");
  strictEqual(FOOTBALL.layout, "straight");
  deepStrictEqual(FOOTBALL.peg, { pegs: 1, shape: "football" });
  strictEqual(FOOTBALL.art, "football"); // a board with art draws no holes or lane lines
  deepStrictEqual(FOOTBALL.skin.lanes.map((l) => l.peg), CLASSIC_WOOD.lanes.map((l) => l.peg));
  strictEqual(FOOTBALL.skin.fourthLane.peg, FOOTBALL.skin.fourthLane.color); // the amber
  strictEqual(contrastRatio("#ffffff", FOOTBALL.skin.wood.top) >= PEG_CONTRAST_MIN, true); // the peg's white edge
});
check("football field: 11 lines from goal to goal, each in a gap between groups of holes", () => {
  const g = boardGeometry(375, 67);
  const lines = fieldYardLines(g);
  strictEqual(lines.length, 11);
  strictEqual(YARD_NUMBERS.length, 9); // on the lines between the goal lines
  deepStrictEqual([...YARD_NUMBERS], [10, 20, 30, 40, 50, 40, 30, 20, 10]);
  strictEqual(lines[0] > g.columnX[4] && lines[0] < g.columnX[5], true);
  strictEqual(lines[5] > g.columnX[29] && lines[5] < g.columnX[30], true); // midfield
  strictEqual(lines[10] > g.columnX[54] && lines[10] < g.columnX[55], true);
  // The start holes and the game hole are in the left end zone, left of its goal line.
  for (const x of [...g.startX, g.gameX]) strictEqual(x > g.rim && x < lines[0], true);
  // And a football at the start holes stays on the board.
  strictEqual(g.startX[0] - g.pegR * FOOTBALL_PEG_RX > 0, true);
});
check("football field: yard numbers only where they reach 9 px, in bands no football covers", () => {
  strictEqual(YARD_NUMBER_MIN_PX, 9);
  strictEqual(yardNumberPx(boardGeometry(375, 67)), null); // a short phone: left out
  strictEqual(yardNumberPx(boardGeometry(375, 67, 4)), null);
  for (const [w, h] of [[390, 84], [502, 108], [896, 96]] as const) {
    const g = boardGeometry(w, h);
    const px = yardNumberPx(g)!;
    strictEqual(px >= 9, true, `${w}x${h}`);
    const halfFootball = g.pegR * FOOTBALL_PEG_RY;
    const [top, bottom] = yardNumberRows(g);
    strictEqual(top - px / 2 >= g.rows[0].back + halfFootball, true, `${w}x${h} top`);
    strictEqual(top + px / 2 <= g.rows[1].out - halfFootball, true, `${w}x${h} top`);
    strictEqual(bottom - px / 2 >= g.rows[1].back + halfFootball, true, `${w}x${h} bottom`);
    strictEqual(bottom + px / 2 <= g.rows[2].out - halfFootball, true, `${w}x${h} bottom`);
    // The logo stays clear of the numbers.
    strictEqual(fieldLogoPx(g) * 0.75 <= bottom - top - px, true, `${w}x${h} logo`);
  }
});
check("custom boards: the self-scoring banner on The Football is cream on green", () => {
  strictEqual(bannerTextColor(FOOTBALL.skin), "#f5efe3");
  strictEqual(contrastRatio(bannerTextColor(FOOTBALL.skin), FOOTBALL.skin.wood.top) >= 4.5, true);
});
check("custom boards: one peg sits at the score, whatever the pegs did", () => {
  strictEqual(frontPegScore([0, 0]), 0);
  strictEqual(frontPegScore([12, 20]), 20);
  strictEqual(frontPegScore([20, 12]), 20); // after a leapfrog
  let pair = nextPegs(null, 0, null);
  for (const [score, last] of [[8, 8], [15, 7], [15, 0], [29, 14], [121, 92]] as const) {
    pair = nextPegs(pair, score, last);
    strictEqual(frontPegScore(pair), score);
  }
  strictEqual(frontPegScore(nextPegs(null, 140, 3)), 121); // past the game hole
});
check("custom boards: this device only, and leaving Custom restores the saved pattern and colours", () => {
  strictEqual(readCustomBoardId(), null); // no localStorage at all, as here in Node
  writeCustomBoardId("football"); // and doesn't throw
  const store = new Map<string, string>();
  const g = globalThis as unknown as { localStorage?: unknown };
  g.localStorage = {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v),
    removeItem: (k: string) => void store.delete(k),
  };
  try {
    writeBoardPattern("snake");
    writeBoardSkinId("mahogany");
    const before = JSON.stringify([...store]);
    writeCustomBoardId("football");
    strictEqual(store.get(CUSTOM_BOARD_KEY), "football");
    strictEqual(readCustomBoardId(), "football");
    strictEqual(readBoardPattern(), "snake");
    strictEqual(readBoardSkinId(), "mahogany");
    writeCustomBoardId(null);
    strictEqual(store.has(CUSTOM_BOARD_KEY), false);
    strictEqual(JSON.stringify([...store]), before);
    // A stored id that doesn't exist (a board removed later): the normal board.
    store.set(CUSTOM_BOARD_KEY, "no-such-board");
    strictEqual(readCustomBoardId(), null);
    writeCustomBoardId("no-such-board");
    strictEqual(store.has(CUSTOM_BOARD_KEY), false);
  } finally {
    delete g.localStorage;
  }
});

// THE DERBY (lib/derbyTrack.ts).
const DERBY_SIZES = [[375, 67], [390, 84], [502, 108], [896, 86], [896, 96], [896, 130]] as const;
// The art's y of the near and far straights, for a lane: below and above the middle.
const DERBY_MIDDLE = 201.5;
const artAt = (count: DerbyLaneCount, lane: number, score: number) => {
  const offset = derbyLaneOffset(count, lane);
  return derbyPointAt(offset, derbyDistance(offset, score));
};
const close = (a: number, b: number, what: string) => strictEqual(Math.abs(a - b) < 1e-6, true, `${what}: ${a} vs ${b}`);
check("derby: the registry has it after The Football, with its picture on disk", () => {
  strictEqual(new Set(CUSTOM_BOARDS.map((b) => b.id)).size, CUSTOM_BOARDS.length);
  deepStrictEqual(CUSTOM_BOARDS.map((b) => b.id), ["football", "derby", "beer"]);
  const derby = customBoardById("derby")!;
  strictEqual(derby.name, "The Derby");
  strictEqual(derby.layout, "track");
  if (derby.layout !== "track") return;
  deepStrictEqual(derby.peg, { pegs: 1, shape: "horse" });
  strictEqual(existsSync(`public${derby.image}`), true);
  deepStrictEqual(derby.skin.lanes.map((l) => l.peg), FOOTBALL.skin.lanes.map((l) => l.peg));
  strictEqual(derby.skin.fourthLane.peg, FOOTBALL.skin.fourthLane.peg);
  strictEqual(bannerTextColor(derby.skin), "#f5efe3"); // cream
  strictEqual(contrastRatio(bannerTextColor(derby.skin), derby.skin.wood.top) >= 4.5, true);
});
check("derby: score 0 on the start mark, 45 art px behind the line in travel order, on every lane", () => {
  strictEqual(DERBY_RUN_UP, 45);
  strictEqual(DERBY_START_X, DERBY_FINISH_X - 45); // the near straight runs left to right
  for (const count of [2, 3, 4] as const) {
    for (let lane = 0; lane < count; lane++) {
      const p = artAt(count, lane, 0);
      close(p.x, DERBY_START_X, "x");
      strictEqual(p.y > DERBY_MIDDLE, true); // the near straight
      deepStrictEqual([p.dx, p.dy], [1, 0]);
    }
  }
});
check("derby: 121 exactly on the finish line, 120 one step short, over 121 clamps", () => {
  for (const count of [2, 3, 4] as const) {
    for (let lane = 0; lane < count; lane++) {
      const end = artAt(count, lane, 121);
      close(end.x, DERBY_FINISH_X, "121");
      strictEqual(end.y > DERBY_MIDDLE, true);
      const last = artAt(count, lane, 120);
      strictEqual(last.x < DERBY_FINISH_X, true); // before the line, running right
      strictEqual(last.x > DERBY_FINISH_X - 40, true); // and only a step short
      close(artAt(count, lane, 140).x, end.x, "140");
      close(artAt(count, lane, -3).x, DERBY_START_X, "-3");
      close(artAt(count, lane, NaN).x, DERBY_START_X, "NaN");
    }
  }
});
check("derby: positions increase along the lane, one lap, in equal steps", () => {
  for (const count of [2, 3, 4] as const) {
    for (let lane = 0; lane < count; lane++) {
      const offset = derbyLaneOffset(count, lane);
      const step = derbyDistance(offset, 1) - derbyDistance(offset, 0);
      for (let s = 0; s < 121; s++) close(derbyDistance(offset, s + 1) - derbyDistance(offset, s), step, "step");
      close(derbyDistance(offset, 121) - derbyDistance(offset, 0), derbyLaneLength(offset) + DERBY_RUN_UP, "the run-up and a lap");
    }
  }
});
check("derby: the first points cross the line, and 121 is the second crossing", () => {
  for (const count of [2, 3, 4] as const) {
    const offset = derbyLaneOffset(count, 0);
    strictEqual(artAt(count, 0, 1).x < DERBY_FINISH_X, true); // still behind it
    strictEqual(artAt(count, 0, 3).x > DERBY_FINISH_X, true); // over it
    close(derbyDistance(offset, 121), DERBY_FINISH_X - 246 + derbyLaneLength(offset), "one lap past the first crossing");
  }
});
check("derby: from 0 over the line the horse faces right and stays level, in every frame", () => {
  for (const [w, h] of DERBY_SIZES) {
    for (const count of [2, 3, 4] as const) {
      for (let lane = 0; lane < count; lane++) {
        const frames = derbySlideFrames(w, h, count, lane, 0, 6)!;
        strictEqual(frames.every((f) => f.flip === 1 && f.tilt === 0), true, `${w}x${h} ${count}/${lane}`);
        strictEqual(new Set(frames.map((f) => f.y)).size, 1, "a straight line");
      }
    }
  }
});
check("derby: the track runs counter-clockwise: right along the near straight, up the right, left along the far", () => {
  const offset = 0;
  const lap = derbyLaneLength(offset);
  const at = (part: number) => derbyPointAt(offset, part * lap);
  deepStrictEqual([at(0.1).dx, at(0.1).dy], [1, 0]); // the near straight
  strictEqual(at(0.1).y > DERBY_MIDDLE, true);
  deepStrictEqual([at(0.6).dx, at(0.6).dy], [-1, 0]); // the far straight
  strictEqual(at(0.6).y < DERBY_MIDDLE, true);
  const rightEnd = derbyPointAt(offset, 1036 + Math.PI * 124.5 * 0.5); // the top of the right end's half turn
  strictEqual(rightEnd.dy, -1); // going up
  strictEqual(rightEnd.x > 1400, true);
  const leftEnd = derbyPointAt(offset, 2 * 1036 + Math.PI * 124.5 * 1.5);
  strictEqual(leftEnd.dy, 1); // going down
  strictEqual(leftEnd.x < 130, true);
});
check("derby: lane 0 is outermost and the last lane innermost, on both straights, and all are distinct", () => {
  for (const count of [2, 3, 4] as const) {
    const near = Array.from({ length: count }, (_, lane) => artAt(count, lane, 5).y); // near straight
    const far = Array.from({ length: count }, (_, lane) => derbyPointAt(derbyLaneOffset(count, lane), 0.6 * derbyLaneLength(derbyLaneOffset(count, lane))).y);
    for (let lane = 1; lane < count; lane++) {
      strictEqual(near[lane] < near[lane - 1], true); // lower on screen is further out
      strictEqual(far[lane] > far[lane - 1], true); // higher on screen is further out
    }
    strictEqual(new Set(near).size, count);
  }
  deepStrictEqual([0, 1, 2, 3].map((lane) => derbyLaneOffset(4, lane)), [33, 11, -11, -33]);
  deepStrictEqual([0, 1, 2].map((lane) => derbyLaneOffset(3, lane)), [26, 0, -26]);
  deepStrictEqual([0, 1].map((lane) => derbyLaneOffset(2, lane)), [13, -13]);
});
check("derby: lane counts -- 2 players and Teams 2, 3 players 3, 4-player Solo 4", () => {
  strictEqual(derbyLaneCount(3, [0, 1]), 2);
  strictEqual(derbyLaneCount(3, [0, 1, 2]), 3);
  strictEqual(derbyLaneCount(4, [0, 1, 2, 3]), 4);
  strictEqual(derbyLaneCount(3, []), 2);
  // The lower lane's player has left: the third-lane player stays in a real lane.
  strictEqual(derbyLaneCount(3, [0, 2]), 3);
  strictEqual(derbyLaneCount(4, [0]), 4);
});
check("derby: every point of every lane is inside the strip, at every size", () => {
  for (const [w, h] of DERBY_SIZES) {
    for (const count of [2, 3, 4] as const) {
      for (let lane = 0; lane < count; lane++) {
        for (let score = 0; score <= 121; score++) {
          const p = derbyPose(w, h, count, lane, score);
          strictEqual(p.x > 0 && p.x < w && p.y > 0 && p.y < h, true, `${w}x${h} ${count}/${lane} ${score}`);
        }
      }
    }
  }
  const art = derbyPointAt(0, 0);
  strictEqual(art.x < DERBY_ART.width && art.y < DERBY_ART.height, true);
});
check("derby: a horse faces its way: right on the near straight, flipped on the far, level on both", () => {
  for (const [w, h] of DERBY_SIZES) {
    for (const count of [2, 3, 4] as const) {
      const near = derbyPose(w, h, count, 0, 3);
      strictEqual(near.flip, 1);
      strictEqual(near.tilt, 0);
      // Halfway round is on the far straight.
      const far = derbyPose(w, h, count, 0, 60);
      strictEqual(far.flip, -1);
      strictEqual(Math.abs(far.tilt), 0);
    }
  }
});
check("derby: tilt never over 26 degrees; it leans up the right end and down the left", () => {
  strictEqual(DERBY_MAX_TILT, 26);
  let leaned = 0;
  for (const [w, h] of DERBY_SIZES) {
    for (const count of [2, 3, 4] as const) {
      for (let lane = 0; lane < count; lane++) {
        for (let score = 0; score <= 121; score++) {
          const pose = derbyPose(w, h, count, lane, score);
          strictEqual(Math.abs(pose.tilt) <= DERBY_MAX_TILT, true);
          if (pose.tilt !== 0) leaned++;
        }
      }
    }
  }
  strictEqual(leaned > 0, true);
  // Climbing either way the nose lifts, descending it drops: on screen the nose
  // leads, so a right-facing horse climbing and a left-facing one descending
  // lean anticlockwise (negative), and the other two clockwise.
  for (let score = 0; score <= 121; score++) {
    const p = artAt(3, 0, score);
    if (p.dx === 0 || p.dy === 0) continue;
    const pose = derbyPose(896, 96, 3, 0, score);
    strictEqual(pose.flip, p.dx > 0 ? 1 : -1, `facing at ${score}`);
    strictEqual(pose.tilt < 0, p.dx > 0 === p.dy < 0, `lean at ${score}`);
  }
});
check("derby: a slide follows the track in frames about 6 art px apart, with facing and tilt in each", () => {
  // From the near straight round the right end to the far straight.
  const frames = derbySlideFrames(896, 96, 4, 0, 20, 70)!;
  strictEqual(frames.length > 3 && frames.length <= 121, true);
  deepStrictEqual(
    [frames[0].x, frames[0].y, frames[frames.length - 1].x, frames[frames.length - 1].y],
    [derbyPose(896, 96, 4, 0, 20).x, derbyPose(896, 96, 4, 0, 20).y, derbyPose(896, 96, 4, 0, 70).x, derbyPose(896, 96, 4, 0, 70).y]
  );
  strictEqual(frames[0].flip, 1);
  strictEqual(frames[frames.length - 1].flip, -1);
  strictEqual(frames.some((f) => f.tilt !== 0), true);
  // On the track: every frame is on the lane, never cutting across the infield.
  const inInfield = (f: { x: number; y: number }) => f.y > 96 * (DERBY_MIDDLE - 70) / 427 && f.y < 96 * (DERBY_MIDDLE + 70) / 427 && f.x < 896 * 1280 / 1525 && f.x > 896 * 250 / 1525;
  strictEqual(frames.some(inInfield), false);
  // No big jumps between frames.
  for (let i = 1; i < frames.length; i++) {
    strictEqual(Math.hypot(frames[i].x - frames[i - 1].x, frames[i].y - frames[i - 1].y) < 12, true);
  }
  strictEqual(derbySlideFrames(375, 67, 2, 1, 0, 1)!.length >= 2, true);
});
check("derby: going backward, or over 60 points, snaps; 60 points forward slides", () => {
  strictEqual(DERBY_MAX_SLIDE, 60);
  strictEqual(derbySlideFrames(896, 96, 3, 0, 121, 0), null); // a New Game's reset
  strictEqual(derbySlideFrames(896, 96, 3, 0, 50, 49), null);
  strictEqual(derbySlideFrames(896, 96, 3, 0, 30, 30), null);
  strictEqual(derbySlideFrames(896, 96, 3, 0, 0, 61), null);
  strictEqual(derbySlideFrames(896, 96, 3, 0, 0, 60) !== null, true);
  // Never more than about 120 frames, even for the longest slide.
  strictEqual(derbySlideFrames(896, 96, 4, 0, 0, 60)!.length <= 121, true);
});
check("derby: the horse is 3.2% of the strip's width, 2.8% with four lanes, and never stretched", () => {
  close(derbyHorseScale(375, 3) * 117, 12, "375");
  close(derbyHorseScale(1000, 2) * 117, 32, "1000");
  close(derbyHorseScale(1000, 4) * 117, 28, "1000 four");
  const right = derbyHorseTransform({ x: 10, y: 20, flip: 1, tilt: 5 }, 0.5);
  strictEqual(right, "translate(10px, 20px) rotate(5deg) scale(0.5, 0.5) translate(-55px, -60px)");
  const left = derbyHorseTransform({ x: 10, y: 20, flip: -1, tilt: -5 }, 0.5);
  strictEqual(left, "translate(10px, 20px) rotate(-5deg) scale(-0.5, 0.5) translate(-55px, -60px)");
});

// THE BEER BOARD (lib/beerBoard.ts).
const BEER = customBoardById("beer")!;
const beerPlate = (key: string, names: string[], score: number, extra: Partial<ScorePlate> = {}): ScorePlate => ({
  key,
  members: names.map((name, i) => ({ userId: `${key}${i}`, name, avatarUrl: null })),
  score,
  isMine: false,
  hasDealer: false,
  lastPoints: null,
  lastReason: null,
  lastAwardedAt: null,
  ...extra,
});
const BEER_TWO = [beerPlate("a", ["Walt"], 94, { isMine: true }), beerPlate("b", ["Normie"], 71)];
const BEER_THREE = [...BEER_TWO, beerPlate("c", ["Buddy"], 38)];
const BEER_FOUR = [...BEER_THREE, beerPlate("d", ["Kim"], 7)];
const BEER_TEAMS = [
  beerPlate("team-2", ["Walt", "Buddy"], 94, { isMine: true }),
  beerPlate("team-1", ["Normie", "Kim"], 71),
];
const BEER_STRIPS: [number, number][] = [[375, 117], [390, 134], [896, 142], [502, 158]];

check("beer: the registry entry, replacing the plates, with every layer on disk", () => {
  strictEqual(BEER.name, "Beer Board");
  strictEqual(BEER.layout, "mugs");
  for (const id of Object.keys(BEER_MUGS) as BeerMugId[]) {
    for (const layer of BEER_LAYERS) strictEqual(existsSync(`public${beerLayerUrl(id, layer)}`), true, `${id} ${layer}`);
  }
});
check("beer: the measurements are the json's, except 4-3's glass, which is corrected", () => {
  const json = JSON.parse(readFileSync("public/boards/beer/beer-layers.json", "utf8"));
  deepStrictEqual(Object.keys(BEER_MUGS).sort(), Object.keys(json).sort());
  for (const id of Object.keys(BEER_MUGS) as BeerMugId[]) {
    const expected = id === "4-3" ? { ...json[id], glassX0: 12, glassX1: 205.5 } : json[id];
    deepStrictEqual({ ...BEER_MUGS[id] }, expected, id);
  }
  // The correction is the point: without it the cap reaches the handle.
  strictEqual(json["4-3"].glassX1 - json["4-0"].glassX1 > 30, true);
  const glass = (id: BeerMugId) => BEER_MUGS[id].glassX1 - BEER_MUGS[id].glassX0;
  strictEqual(Math.abs(glass("4-3") - glass("4-0")) < 3, true);
});
check("beer: every layer image is the width the json says, and the full ones 340 tall", () => {
  // A webp's size, from its VP8X header (every layer is VP8X).
  const sizeOf = (path: string) => {
    const b = readFileSync(path);
    strictEqual(b.toString("ascii", 12, 16), "VP8X", path);
    return { w: 1 + b.readUIntLE(24, 3), h: 1 + b.readUIntLE(27, 3) };
  };
  for (const id of Object.keys(BEER_MUGS) as BeerMugId[]) {
    const art = BEER_MUGS[id];
    for (const layer of BEER_LAYERS) {
      const size = sizeOf(`public${beerLayerUrl(id, layer)}`);
      strictEqual(size.w, art.w, `${id} ${layer}`);
      strictEqual(size.h, layer === "band" ? Math.round(art.bandBottom - art.bandTop) : art.h, `${id} ${layer}`);
    }
  }
});
check("beer: the 3-* mugs only for 3 players, the 4-* for everything else; the preload lists them", () => {
  deepStrictEqual(beerMugIdsFor(3), ["3-0", "3-1", "3-2"]);
  for (const n of [2, 4]) deepStrictEqual(beerMugIdsFor(n), ["4-0", "4-1", "4-2", "4-3"]);
  strictEqual(beerLayerUrls(3).length, 15);
  strictEqual(beerLayerUrls(2).length, 20);
  strictEqual(beerLayerUrls(3).every((u) => u.startsWith("/boards/beer/3-")), true);
  strictEqual(beerLayerUrls(4).every((u) => u.startsWith("/boards/beer/4-")), true);
  strictEqual([...beerLayerUrls(2), ...beerLayerUrls(3)].every((u) => !/beer-[34]/.test(u)), true);
});
check("beer: plates go only with a board that replaces them, never on a Muggins table", () => {
  strictEqual(platesReplaced(BEER, false), true);
  strictEqual(platesReplaced(BEER, true), false);
  for (const board of [FOOTBALL, customBoardById("derby")!, null, undefined]) {
    strictEqual(platesReplaced(board, false), false);
    strictEqual(platesReplaced(board, true), false);
  }
});
check("beer: the drain -- one mug over the game, or two split at 60", () => {
  const scores = [0, 30, 60, 61, 91, 121];
  const levels = (lo: number, hi: number) => scores.map((s) => beerLevel(s, lo, hi));
  const near = (a: number[], b: number[], what: string) => a.forEach((v, i) => close(v, b[i], `${what} ${scores[i]}`));
  near(levels(0, 121), scores.map((s) => 1 - s / 121), "solo");
  near(levels(0, 60), [1, 0.5, 0, 0, 0, 0], "first");
  near(levels(60, 121), [1, 1, 1, 1 - 1 / 61, 1 - 31 / 61, 0], "second");
  strictEqual(beerLevel(60, 0, 60), 0); // the first mug is empty exactly at 60
  strictEqual(beerLevel(121, 60, 121), 0); // the second exactly at 121
  strictEqual(beerLevel(121, 0, 121), 0);
  strictEqual(beerLevel(0, 0, 121), 1);
  // Past either end stays in 0 .. 1.
  strictEqual(beerLevel(130, 0, 121), 0);
  strictEqual(beerLevel(-5, 0, 121), 1);
});
check("beer: the layout comes from the plates' shape, with the right mugs and points", () => {
  strictEqual(beerLayoutFor(BEER_TWO), "pairs");
  strictEqual(beerLayoutFor(BEER_THREE), "three");
  strictEqual(beerLayoutFor(BEER_FOUR), "four");
  strictEqual(beerLayoutFor(BEER_TEAMS), "teams");
  // A partner who has gone is still a team: the other partner's plate has two.
  strictEqual(beerLayoutFor([BEER_TEAMS[0], beerPlate("team-1", ["Normie"], 71)]), "teams");
  deepStrictEqual(beerSlots("three").map((s) => [s.id, s.plate, s.lo, s.hi]), [["3-0", 0, 0, 121], ["3-1", 1, 0, 121], ["3-2", 2, 0, 121]]);
  deepStrictEqual(beerSlots("four").map((s) => [s.id, s.plate]), [["4-0", 0], ["4-1", 1], ["4-2", 2], ["4-3", 3]]);
  for (const layout of ["pairs", "teams"] as const) {
    deepStrictEqual(beerSlots(layout).map((s) => [s.id, s.plate, s.lo, s.hi]), [
      ["4-0", 0, 0, 60],
      ["4-1", 0, 60, 121],
      ["4-2", 1, 0, 60],
      ["4-3", 1, 60, 121],
    ]);
  }
  deepStrictEqual(beerSlots("teams").map((s) => s.member), [0, 1, 0, 1]);
  deepStrictEqual(beerSlots("pairs").map((s) => s.member), [null, null, null, null]);
});
check("beer: mug centres, height and foot; every mug's glass stays on the strip", () => {
  for (const [w, h] of BEER_STRIPS) {
    for (const plates of [BEER_TWO, BEER_THREE, BEER_FOUR, BEER_TEAMS]) {
      for (const m of beerScene(w, h, plates).mugs) {
        close(m.scale * 340, 0.9 * h, "height");
        close(m.y + m.scale * 340, 0.935 * h, "foot");
        strictEqual(m.x + m.art.glassX0 * m.scale >= 2 - 1e-9, true, `${w}x${h} ${m.id} left`);
        strictEqual(m.x + m.art.w * m.scale <= w, true, `${w}x${h} ${m.id} right`);
      }
    }
  }
  // The clamp moves only a first mug that would leave the strip, and keeps it
  // clear of its neighbour.
  const clamped = beerScene(390, 134, BEER_TWO).mugs;
  strictEqual(clamped[0].x + clamped[0].art.w * clamped[0].scale < clamped[1].x + clamped[1].art.glassX0 * clamped[1].scale, true);
  for (const [w, h] of [[375, 117], [896, 142]]) {
    const middle = (m: ReturnType<typeof beerScene>["mugs"][number]) => m.x + (m.art.w * m.scale) / 2 + 0.04 * h;
    beerScene(w, h, BEER_THREE).mugs.forEach((m, k) => close(middle(m), (w * (2 * k + 1)) / 6, `three ${k}`));
    beerScene(w, h, BEER_FOUR).mugs.forEach((m, k) => close(middle(m), (w * (2 * k + 1)) / 8, `four ${k}`));
    for (const plates of [BEER_TWO, BEER_TEAMS]) {
      const { mugs } = beerScene(w, h, plates);
      for (const pair of [0, 1]) {
        const [a, b] = mugs.filter((m) => m.plate === pair);
        const mw = a.art.w * a.scale + 0.05 * h;
        close(middle(a), w * (pair === 0 ? 0.25 : 0.75) - 0.5 * mw, "pair left");
        close(middle(b), w * (pair === 0 ? 0.25 : 0.75) + 0.5 * (b.art.w * b.scale + 0.05 * h), "pair right");
      }
    }
  }
});
check("beer: 3 and 4 solo -- the number and avatar on each mug, the 3-digit size smaller", () => {
  const [w, h] = [375, 117];
  const scale = (h * 0.9) / 340;
  const top = 0.035 * h;
  const scene = beerScene(w, h, BEER_THREE);
  scene.scores.forEach((s, k) => {
    const mug = scene.mugs[k];
    close(s.x, mug.x + (mug.art.w * scale) / 2, "score x");
    close(s.y, top + 172 * scale, "score y");
    close(s.fontSize, 83 * scale, "two digits");
  });
  scene.avatars.forEach((a, k) => {
    close(a.x, scene.scores[k].x, "avatar x");
    close(a.y, top + 272 * scale, "avatar y");
    close(a.r, 45 * scale, "avatar r");
  });
  const big = beerScene(w, h, [beerPlate("a", ["A"], 100), beerPlate("b", ["B"], 99), beerPlate("c", ["C"], 121)]);
  deepStrictEqual(big.scores.map((s) => Math.round(s.fontSize / scale)), [71, 83, 71]);
});
check("beer: 2 players -- number and avatar on the pair's centre, sized up, the score the plate's", () => {
  const [w, h] = [375, 117];
  const scale = (h * 0.9) / 340;
  const top = 0.035 * h;
  const scene = beerScene(w, h, BEER_TWO);
  deepStrictEqual(scene.scores.map((s) => s.text), ["94", "71"]);
  scene.scores.forEach((s, i) => {
    close(s.x, w * (i === 0 ? 0.25 : 0.75) - 0.04 * h, "pair x");
    close(s.y, top + (172 - 0.05 * 47) * scale, "pair y");
    close(s.fontSize, 95 * scale, "pair size");
    close(scene.avatars[i].x, s.x, "avatar x");
    close(scene.avatars[i].y, top + (272 + 0.15 * 47) * scale, "avatar y");
    close(scene.avatars[i].r, 47 * scale, "avatar r");
  });
  strictEqual(beerScene(w, h, [beerPlate("a", ["A"], 100), beerPlate("b", ["B"], 0)]).scores[0].fontSize, 82 * scale);
  // The pair drains in turn: at 94, the first mug is dry and the second going.
  deepStrictEqual(scene.mugs.slice(0, 2).map((m) => m.level), [0, 1 - 34 / 61]);
});
check("beer: Teams -- one score across the pair, each teammate's avatar on their own mug", () => {
  const [w, h] = [375, 117];
  const scene = beerScene(w, h, BEER_TEAMS);
  deepStrictEqual(scene.scores.map((s) => s.text), ["94", "71"]);
  deepStrictEqual(scene.avatars.map((a) => a.name), ["Walt", "Buddy", "Normie", "Kim"]);
  scene.avatars.forEach((a, i) => close(a.x, scene.mugs[i].x + (scene.mugs[i].art.w * scene.mugs[i].scale) / 2, "on its mug"));
  // Only the first of my team is me (buildPlates puts me first on my plate).
  deepStrictEqual(scene.avatars.map((a) => a.mine), [true, false, false, false]);
  strictEqual(new Set(scene.avatars.map((a) => a.key)).size, 4);
});
check("beer: the gold ring is mine alone; rings are the lane's, letters and photos as given", () => {
  const plates = [
    beerPlate("a", ["walt"], 10, { isMine: true, laneColor: "#ff0000", members: [{ userId: "a", name: "walt", avatarUrl: "/w.png" }] }),
    beerPlate("b", ["Normie"], 20, { laneColor: "#0000ff" }),
    beerPlate("c", ["Buddy"], 30),
  ];
  const { avatars } = beerScene(375, 117, plates);
  deepStrictEqual(avatars.map((a) => a.mine), [true, false, false]);
  deepStrictEqual(avatars.map((a) => a.url), ["/w.png", null, null]);
  deepStrictEqual(avatars.map((a) => a.letter), ["W", "N", "B"]);
  deepStrictEqual(avatars.slice(0, 2).map((a) => a.ringColor), ["#ff0000", "#0000ff"]);
  strictEqual(avatars[2].ringColor.length, 7); // never missing
});
check("beer: a hidden score shows no number and a full mug, whatever the seat's score", () => {
  const hidden = beerPlate("b", ["Walt"], 0, { scoreHidden: true });
  for (const plates of [
    [BEER_TWO[0], hidden],
    [BEER_TWO[0], hidden, BEER_THREE[2]],
    [BEER_TWO[0], hidden, BEER_THREE[2], BEER_FOUR[3]],
  ]) {
    const scene = beerScene(375, 117, plates);
    strictEqual(scene.scores.some((s) => s.key === "b"), false);
    strictEqual(scene.scores.length, plates.length - 1);
    const mugs = scene.mugs.filter((m) => m.plate === 1);
    strictEqual(mugs.length >= 1, true);
    for (const m of mugs) {
      strictEqual(m.level, 1);
      strictEqual(m.score, null);
    }
    strictEqual(scene.avatars.length, plates.length); // the avatar stays
  }
  // A real 121, hidden: still full, no number.
  const teams = beerScene(375, 117, [BEER_TEAMS[0], { ...BEER_TEAMS[1], score: 121, scoreHidden: true }]);
  deepStrictEqual(teams.scores.map((s) => s.key), ["team-2"]);
  deepStrictEqual(teams.mugs.filter((m) => m.plate === 1).map((m) => m.level), [1, 1]);
});
check("beer: the drawing -- surface, foam and crown by the level", () => {
  for (const id of Object.keys(BEER_MUGS) as BeerMugId[]) {
    const art = BEER_MUGS[id];
    close(beerLevelY(art, 1), art.bt, "full");
    close(beerLevelY(art, 0), art.h + 5, "empty");
    // Just above empty, the surface is the glass's floor.
    strictEqual(Math.abs(beerLevelY(art, 1e-9) - art.bb) < 1e-6, true);
    const empty = beerDrawing(id, 0);
    deepStrictEqual(
      [empty.levelY, empty.cap.opacity, empty.band.height, empty.band.opacity, empty.crown.opacity],
      [art.h + 5, 0, 0, 0, 0]
    );
    const half = beerDrawing(id, 0.5);
    const bh = art.bandBottom - art.bandTop;
    close(half.band.height, Math.round(bh * 0.75 * 100) / 100, "band");
    strictEqual(Math.abs(half.band.y + half.band.height - half.levelY) < 0.02, true);
    strictEqual(half.band.opacity, 1);
    strictEqual(half.crown.opacity, 0);
    // The foam fades in over the last 8% of the beer, the crown over the top 12%.
    strictEqual(beerDrawing(id, 0.04).band.opacity, 0.5);
    strictEqual(beerDrawing(id, 0.94).crown.opacity, 0.5);
    strictEqual(beerDrawing(id, 1).crown.opacity, 1);
    strictEqual(beerDrawing(id, 1).crown.y, 0);
    strictEqual(beerDrawing(id, 0.94).crown.y, Math.round(0.03 * (art.bb - art.bt) * 100) / 100);
    // The band never collapses, however low.
    strictEqual(beerDrawing(id, 0.001).band.height >= 2, true);
  }
});
check("beer: the foam cap is deterministic, differs by mug, and only shows when it should", () => {
  for (const id of Object.keys(BEER_MUGS) as BeerMugId[]) {
    for (const level of [0.1, 0.5, 0.9]) deepStrictEqual(beerFoamCap(id, level), beerFoamCap(id, level));
    strictEqual(beerFoamCap(id, 0), null);
    strictEqual(beerFoamCap(id, 0.985), null);
    strictEqual(beerFoamCap(id, 1), null);
    strictEqual(beerDrawing(id, 1).cap.d, "");
    strictEqual(beerFoamCap(id, 0.984) !== null, true);
  }
  strictEqual(beerFoamCap("4-0", 0.5)!.d !== beerFoamCap("4-1", 0.5)!.d, true);
  strictEqual(beerFoamCap("4-0", 0.5)!.d !== beerFoamCap("4-0", 0.7)!.d, true);
  // The level is taken to the nearest 2%: a slow drain doesn't reshuffle the
  // bubbles every frame (only their y moves).
  const bubbles = (level: number) => beerFoamCap("4-0", level)!.d.match(/a/g)!.length;
  strictEqual(bubbles(0.501), bubbles(0.5));
  const radii = (level: number) => beerFoamCap("4-0", level)!.d.match(/a[\d.]+/g)!.map((r) => Number(r.slice(1)));
  radii(0.501).forEach((r, i) => strictEqual(Math.abs(r - radii(0.5)[i]) <= 0.02, true, `bubble ${i}`));
  const cap = beerFoamCap("4-2", 0.5)!;
  const art = BEER_MUGS["4-2"];
  close(cap.x0, art.glassX0 - 3, "clip left");
  close(cap.x1, art.glassX1 + 4, "clip right");
  const f = 0.75;
  const nh = (art.bandBottom - art.bandTop) * f;
  strictEqual(Math.abs(cap.y - (beerLevelY(art, 0.5) - nh + 1)) < 0.01, true);
});
check("beer: a drain follows The Derby's rule", () => {
  strictEqual(beerDrains(10, 12), true);
  strictEqual(beerDrains(0, BEER_MAX_DRAIN), true);
  strictEqual(beerDrains(0, BEER_MAX_DRAIN + 1), false); // too long
  strictEqual(beerDrains(50, 49), false); // backward
  strictEqual(beerDrains(121, 0), false); // a New Game's reset
  strictEqual(beerDrains(30, 30), false);
  strictEqual(beerDrains(null, 30), false); // hidden on either side
  strictEqual(beerDrains(30, null), false);
  strictEqual(beerEase(0), 0);
  strictEqual(beerEase(1), 1);
  strictEqual(beerEase(0.5) > 0.5, true); // ease-out: most of it early
});
check("beer: the label says who has what, teams by team, hidden scores as hidden", () => {
  strictEqual(beerAriaLabel(BEER_THREE), "Walt 94, Normie 71, Buddy 38");
  strictEqual(beerAriaLabel(BEER_TEAMS), "Team 2 (Walt and Buddy) 94, Team 1 (Normie and Kim) 71");
  strictEqual(
    beerAriaLabel([BEER_TWO[0], { ...BEER_TWO[1], scoreHidden: true }]),
    "Walt 94, Normie score hidden"
  );
  strictEqual(beerAriaLabel([{ ...BEER_TEAMS[0], scoreHidden: true }]), "Team 2 (Walt and Buddy) score hidden");
});
check("beer: the Profile's preview -- the tall strip, three players, letters, lane rings", () => {
  deepStrictEqual(BEER_PREVIEW_SIZE, { w: 375, h: 117 });
  const plates = beerPreviewPlates(BEER.skin);
  strictEqual(beerLayoutFor(plates), "three");
  strictEqual(plates.every((p) => p.members[0].avatarUrl === null), true);
  strictEqual(new Set(plates.map((p) => p.laneColor)).size, 3);
  const scene = beerScene(BEER_PREVIEW_SIZE.w, BEER_PREVIEW_SIZE.h, plates);
  strictEqual(scene.avatars.every((a) => a.url === null && !a.mine), true);
});
check("beer: the self-scoring banner reads, and the lanes match the other custom boards", () => {
  strictEqual(bannerTextColor(BEER.skin), "#f5efe3");
  for (const wood of [BEER.skin.wood.top, BEER.skin.wood.bottom]) strictEqual(contrastRatio(bannerTextColor(BEER.skin), wood) >= 4.5, true);
  deepStrictEqual(BEER.skin.lanes.map((l) => l.peg), FOOTBALL.skin.lanes.map((l) => l.peg));
  strictEqual(BEER.skin.fourthLane.peg, FOOTBALL.skin.fourthLane.peg);
});

// THE SOUNDS (lib/sounds.ts).
const onDisk = (url: string) => `public${url}`;
const SOUND_P2 = ["a", "b"];
const SOUND_P4 = ["a", "b", "c", "d"];
const plainTable = { isMuggins: false, square: true };
const cue = (...events: SoundEvent[]): SoundCue => ({ steps: events.map((event) => ({ event, url: event })), gapMs: null });

check("sounds: every clip the spec lists is registered, in its event", () => {
  deepStrictEqual(CORE_SOUNDS.card, ["/sounds/card.mp3"]);
  deepStrictEqual(CORE_SOUNDS.shuffle, ["/sounds/shuffle.mp3"]);
  deepStrictEqual(CORE_SOUNDS.deal, ["/sounds/deal.mp3"]);
  deepStrictEqual(SOUND_EVENTS.map((e) => CORE_SOUNDS[e].length), [1, 1, 1, 1, 4, 2, 3, 2, 2]);
  strictEqual(CORE_SOUNDS.win.every((c) => c.startsWith("/sounds/win-")), true);
  strictEqual(CORE_SOUNDS.loss.every((c) => c.startsWith("/sounds/loss-")), true);
  strictEqual(CORE_SOUNDS.skunk.every((c) => c.startsWith("/sounds/skunk-")), true);
  strictEqual(CORE_SOUNDS["double-skunk"].every((c) => c.startsWith("/sounds/doubleskunk-")), true);
  strictEqual(CORE_SOUNDS.stinkhole.every((c) => c.startsWith("/sounds/stinkhole-")), true);
});
check("sounds: every registered clip exists, is an MP3, and fits the budget", () => {
  const clips = clipsFor(null);
  strictEqual(clips.length, 16);
  let total = 0;
  for (const url of clips) {
    strictEqual(existsSync(onDisk(url)), true, url);
    strictEqual(url.endsWith(".mp3"), true, url);
    const { size } = statSync(onDisk(url));
    strictEqual(size > 0 && size < SOUND_CLIP_MAX_BYTES, true, `${url}: ${size}`);
    total += size;
  }
  strictEqual(SOUND_CLIP_MAX_BYTES, 60_000);
  strictEqual(SOUND_SET_MAX_BYTES, 350_000);
  strictEqual(total < SOUND_SET_MAX_BYTES, true, `the set: ${total}`);
});
check("sounds: no clip sits on disk unregistered", () => {
  const onDiskNow = readdirSync("public/sounds").filter((f) => f.endsWith(".mp3")).map((f) => `/sounds/${f}`).sort();
  deepStrictEqual(onDiskNow, clipsFor(null).sort());
});
check("sounds: no event plays points -- nothing exists for a score to trigger", () => {
  deepStrictEqual([...SOUND_EVENTS].sort(), ["card", "deal", "double-skunk", "loss", "shuffle", "skunk", "stinkhole", "win", "zeroHand"]);
});
check("sounds: the deal's lead-in is the shuffle's length, and a burst is a few ms", () => {
  strictEqual(SHUFFLE_LEAD_MS, 650);
  strictEqual(BURST_WINDOW_MS <= 50, true);
});
check("sounds: soundFor falls back to the core sound; no board has sounds yet", () => {
  for (const event of SOUND_EVENTS) {
    deepStrictEqual(soundFor(event, null, plainTable), CORE_SOUNDS[event]);
    deepStrictEqual(soundFor(event, undefined, plainTable), CORE_SOUNDS[event]);
    for (const board of CUSTOM_BOARDS) {
      strictEqual(board.sounds, undefined);
      deepStrictEqual(soundFor(event, board, plainTable), CORE_SOUNDS[event]);
    }
  }
});
check("sounds: a board's clip plays only while its board is on screen", () => {
  const board = { sounds: { card: "/sounds/beer/glug.mp3" } };
  deepStrictEqual(soundFor("card", board, plainTable), ["/sounds/beer/glug.mp3"]);
  deepStrictEqual(soundFor("deal", board, plainTable), CORE_SOUNDS.deal); // not its event
  deepStrictEqual(soundFor("card", board, { isMuggins: true, square: true }), CORE_SOUNDS.card);
  deepStrictEqual(soundFor("card", board, { isMuggins: false, square: false }), CORE_SOUNDS.card);
  strictEqual(clipsFor(board).includes("/sounds/beer/glug.mp3"), true);
  strictEqual(clipsFor(board).length, 17);
});
check("sounds: the picker never repeats back to back", () => {
  for (const event of SOUND_EVENTS) {
    const clips = CORE_SOUNDS[event];
    if (clips.length < 2) continue;
    let last: string | null = null;
    for (let i = 0; i < 500; i++) {
      const next = pickClip(clips, last);
      strictEqual(clips.includes(next), true);
      strictEqual(next !== last, true, `${event} repeated ${next}`);
      last = next;
    }
  }
});
check("sounds: the picker -- both ends of random, a single clip, a last pick not in the list", () => {
  const list = ["a", "b", "c"];
  strictEqual(pickClip(list, "a", () => 0), "b");
  strictEqual(pickClip(list, "a", () => 0.999), "c");
  strictEqual(pickClip(list, null, () => 0), "a");
  strictEqual(pickClip(["only"], "only"), "only"); // nothing else to play
  strictEqual(pickClip(list, "gone", () => 0), "a");
});
check("sounds: every pick reachable from every last pick", () => {
  const list = ["a", "b", "c", "d"];
  for (const last of list) {
    const seen = new Set<string>();
    for (const r of [0, 0.34, 0.67, 0.99]) seen.add(pickClip(list, last, () => r));
    deepStrictEqual([...seen].sort(), list.filter((c) => c !== last));
  }
});
check("sounds: who hears the end -- 2, 3 and 4 Solo players: only the winner wins", () => {
  strictEqual(gameOutcome({ players: SOUND_P2, winnerId: "a", myId: "a", teams: false }), "win");
  strictEqual(gameOutcome({ players: SOUND_P2, winnerId: "a", myId: "b", teams: false }), "loss");
  for (const me of ["b", "c", "d"]) {
    strictEqual(gameOutcome({ players: SOUND_P4, winnerId: "a", myId: me, teams: false }), "loss");
  }
});
check("sounds: who hears the end -- Teams: both partners win, both opponents lose", () => {
  // Seats 1 and 3 against 2 and 4 (teamOfPosition).
  const outcomeOf = (winnerId: string) =>
    SOUND_P4.map((myId) => gameOutcome({ players: SOUND_P4, winnerId, myId, teams: true }));
  deepStrictEqual(outcomeOf("a"), ["win", "loss", "win", "loss"]);
  deepStrictEqual(outcomeOf("c"), ["win", "loss", "win", "loss"]);
  deepStrictEqual(outcomeOf("b"), ["loss", "win", "loss", "win"]);
  deepStrictEqual(outcomeOf("d"), ["loss", "win", "loss", "win"]);
});
check("sounds: who hears the end -- a spectator, a missing winner or nobody signed in: nothing", () => {
  strictEqual(gameOutcome({ players: SOUND_P2, winnerId: "a", myId: "z", teams: false }), null);
  strictEqual(gameOutcome({ players: SOUND_P4, winnerId: "a", myId: "z", teams: true }), null);
  strictEqual(gameOutcome({ players: SOUND_P2, winnerId: null, myId: "a", teams: false }), null);
  strictEqual(gameOutcome({ players: SOUND_P2, winnerId: "a", myId: null, teams: false }), null);
});
check("sounds: the loss tiers are God's numbers, at every boundary", () => {
  const expected: [number, string | null][] = [
    [0, "double-skunk"], [60, "double-skunk"],
    [61, "skunk"], [90, "skunk"],
    [91, null], [119, null],
    [120, "stinkhole"],
  ];
  for (const [score, tier] of expected) strictEqual(lossTier(score), tier, String(score));
  for (let score = 0; score <= 120; score++) {
    strictEqual(godLossSplash("hard", true, score), lossTier(score));
  }
});
check("sounds: a loss plays its tier; a win never does", () => {
  const plain = { isMuggins: false };
  strictEqual(endSoundEvent("loss", 100, plain), "loss");
  strictEqual(endSoundEvent("loss", 75, plain), "skunk");
  strictEqual(endSoundEvent("loss", 40, plain), "double-skunk");
  strictEqual(endSoundEvent("loss", 120, plain), "stinkhole");
  strictEqual(endSoundEvent("loss", null, plain), "loss"); // the read failed
  strictEqual(endSoundEvent("win", 40, plain), "win");
});
check("sounds: the gate -- a Muggins table never tells a loser how far behind they were", () => {
  const muggins = { isMuggins: true };
  for (let score = 0; score <= 121; score++) strictEqual(endSoundEvent("loss", score, muggins), "loss");
  strictEqual(endSoundEvent("win", null, muggins), "win");
});
check("sounds: the loser's score -- Solo reads mine, Teams the higher of the two rows", () => {
  const rows = [
    { user_id: "a", score: 121 },
    { user_id: "b", score: 70 },
    { user_id: "c", score: 121 },
    { user_id: "d", score: 95 },
  ];
  const base = { rows, players: SOUND_P4, winnerId: "a", gameHole: 121 };
  strictEqual(loserScore({ ...base, myId: "b", teams: false }), 70);
  strictEqual(loserScore({ ...base, myId: "b", teams: true }), 95); // a partner's row still on its way
  strictEqual(loserScore({ ...base, myId: "d", teams: true }), 95);
});
check("sounds: the loser's score -- not final, or not there: null, so a plain loss", () => {
  const players = SOUND_P2;
  const final = { players, winnerId: "a", myId: "b", teams: false, gameHole: 121 };
  strictEqual(loserScore({ ...final, rows: [{ user_id: "a", score: 0 }, { user_id: "b", score: 0 }] }), null);
  strictEqual(loserScore({ ...final, rows: [] }), null);
  strictEqual(loserScore({ ...final, rows: [{ user_id: "a", score: 121 }] }), null);
  strictEqual(loserScore({ ...final, rows: [{ user_id: "a", score: 121 }, { user_id: "b", score: null }] }), null);
});
check("sounds: the keys -- a play's seq restarts each hand, so its key has the hand in it", () => {
  strictEqual(playKey("g", 1, 1) === playKey("g", 2, 1), false);
  strictEqual(playKey("g", 1, 1) === playKey("g", 1, 2), false);
  strictEqual(playKey("g", 1, 1) === playKey("h", 1, 1), false);
  strictEqual(playKey("g", 1, 1), playKey("g", 1, 1));
});
check("sounds: the keys -- each is its own, and hand, round and player count", () => {
  strictEqual(discardKey("g", 1, "a") === discardKey("g", 2, "a"), false);
  strictEqual(discardKey("g", 1, "a") === discardKey("g", 1, "b"), false);
  strictEqual(cutKey("g", 0, "a") === cutKey("g", 1, "a"), false); // a tie's redraw
  strictEqual(cutKey("g", 0, "a") === cutKey("g", 0, "b"), false);
  const keys = [playKey("g", 1, 1), discardKey("g", 1, "a"), cutKey("g", 1, "a"), cutOpenKey("g"), dealKey("g:1"), endKey("g")];
  strictEqual(new Set(keys).size, keys.length);
});
check("sounds: a later row repeats a cut, with the same keys", () => {
  const first = [[{ user_id: "a" }]];
  const later = [[{ user_id: "a" }, { user_id: "b" }]];
  deepStrictEqual(cutKeys("g", first), [cutKey("g", 0, "a")]);
  deepStrictEqual(cutKeys("g", later), [cutKey("g", 0, "a"), cutKey("g", 0, "b")]);
  // The tap's key is the row's: the tapping player's own echo stays quiet.
  strictEqual(cutKeys("g", later).includes(cutKey("g", 0, "a")), true);
  // A tie opens a round: a second card from the same player is a new key.
  deepStrictEqual(cutKeys("g", [[{ user_id: "a" }], []]), [cutKey("g", 0, "a")]);
  deepStrictEqual(cutKeys("g", [[{ user_id: "a" }], [{ user_id: "a" }]]), [cutKey("g", 0, "a"), cutKey("g", 1, "a")]);
  deepStrictEqual(cutKeys("g", null), []);
});
check("sounds: a discard is one list entry per player, keyed per hand", () => {
  deepStrictEqual(discardKeys("g", 3, ["a", "b"]), [discardKey("g", 3, "a"), discardKey("g", 3, "b")]);
  deepStrictEqual(discardKeys("g", 3, []), []);
  deepStrictEqual(discardKeys("g", 3, null), []);
});
check("sounds: what a read finds is heard, not played", () => {
  const row = { id: "g", hand_no: 2, deal_cut: [[{ user_id: "a" }]], discarded_by: ["b"] };
  deepStrictEqual(heardKeys(row), [cutKey("g", 0, "a"), discardKey("g", 2, "b")]);
  deepStrictEqual(heardKeys({ id: "g", hand_no: 1, deal_cut: null, discarded_by: null }), []);
});
check("sounds: a burst -- win and lose over deal over shuffle over card", () => {
  deepStrictEqual(pickBurst([]), null);
  const card = cue("card");
  const shuffle = cue("shuffle");
  const deal = cue("deal");
  for (const end of ["win", "loss", "skunk", "double-skunk", "stinkhole"] as const) {
    const ending = cue(end);
    strictEqual(pickBurst([card, shuffle, deal, ending]), ending);
    strictEqual(pickBurst([ending, deal, shuffle, card]), ending);
  }
  strictEqual(pickBurst([card, shuffle, deal]), deal);
  strictEqual(pickBurst([card, shuffle]), shuffle);
  strictEqual(pickBurst([card, card]), card);
  strictEqual(SOUND_PRIORITY.win > SOUND_PRIORITY.deal, true);
});
check("sounds: a burst -- the shuffle-then-deal pair stays whole, ahead of a lone shuffle", () => {
  const pair = cue("shuffle", "deal");
  const shuffle = cue("shuffle");
  const card = cue("card");
  strictEqual(pickBurst([card, shuffle, pair]), pair);
  strictEqual(pickBurst([pair, card]), pair);
  deepStrictEqual(pickBurst([card, pair])?.steps.map((s) => s.event), ["shuffle", "deal"]);
  const win = cue("win");
  strictEqual(pickBurst([pair, win]), win);
  strictEqual(pickBurst([cue("card", "card"), card])?.steps.length, 2); // a discard's two cards, first of equals
});
check("sounds: the setting -- no storage reads on at 0.8, and writes don't throw", () => {
  strictEqual(readSoundOn(), true); // no localStorage at all, as here in Node
  strictEqual(readSoundVolume(), DEFAULT_SOUND_VOLUME);
  strictEqual(DEFAULT_SOUND_VOLUME, 0.8);
  strictEqual(readLastClip("win"), null);
  writeSoundOn(false);
  writeSoundVolume(0.5);
  writeLastClip("win", "x");
});
check("sounds: the setting -- saved under its own keys, and read back", () => {
  strictEqual(SOUND_KEY, "nobs:sound");
  strictEqual(SOUND_VOLUME_KEY, "nobs:sound-volume");
  const store = new Map<string, string>();
  const g = globalThis as unknown as { localStorage?: unknown };
  g.localStorage = {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v),
    removeItem: (k: string) => void store.delete(k),
  };
  try {
    strictEqual(readSoundOn(), true); // on by default
    writeSoundOn(false);
    strictEqual(store.get(SOUND_KEY), "0");
    strictEqual(readSoundOn(), false);
    writeSoundOn(true);
    strictEqual(store.get(SOUND_KEY), "1");
    strictEqual(readSoundOn(), true);

    strictEqual(readSoundVolume(), 0.8);
    writeSoundVolume(0.35);
    strictEqual(store.get(SOUND_VOLUME_KEY), "0.35");
    strictEqual(readSoundVolume(), 0.35);
    writeSoundVolume(0);
    strictEqual(readSoundVolume(), 0); // silence is a volume, not a missing one
    writeSoundVolume(4);
    strictEqual(readSoundVolume(), 1);
    writeSoundVolume(-1);
    strictEqual(readSoundVolume(), 0);
    writeSoundVolume(Number.NaN);
    strictEqual(readSoundVolume(), 0); // not saved

    for (const junk of ["", " ", "loud", "NaN"]) {
      store.set(SOUND_VOLUME_KEY, junk);
      strictEqual(readSoundVolume(), 0.8, JSON.stringify(junk));
    }
    store.set(SOUND_VOLUME_KEY, "7");
    strictEqual(readSoundVolume(), 1); // an edited value is held in range

    writeLastClip("win", "/sounds/win-2-booyah.mp3");
    strictEqual(readLastClip("win"), "/sounds/win-2-booyah.mp3");
    strictEqual(readLastClip("loss"), null); // one last pick per category
  } finally {
    delete g.localStorage;
  }
});
check("sounds: the setting -- blocked storage falls back, and never throws", () => {
  const g = globalThis as unknown as { localStorage?: unknown };
  const blocked = () => {
    throw new Error("blocked");
  };
  g.localStorage = { getItem: blocked, setItem: blocked, removeItem: blocked };
  try {
    strictEqual(readSoundOn(), true);
    strictEqual(readSoundVolume(), 0.8);
    strictEqual(readLastClip("win"), null);
    writeSoundOn(false);
    writeSoundVolume(0.1);
    writeLastClip("win", "x");
  } finally {
    delete g.localStorage;
  }
});

check("sounds: mute, then unmute, then a sound plays again -- nothing stays stopped", () => {
  const store = new Map<string, string>();
  const g = globalThis as unknown as { localStorage?: unknown };
  g.localStorage = {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v),
    removeItem: (k: string) => void store.delete(k),
  };
  // The player's question, asked as it is at a sound's start: the setting is
  // read then, not remembered.
  let contextState: string | null = "running";
  const plays = () => cueAllowed({ hidden: false, on: readSoundOn(), contextState, loaded: true });
  try {
    strictEqual(plays(), true);
    writeSoundOn(false);
    strictEqual(plays(), false);
    writeSoundOn(true);
    strictEqual(plays(), true);
    for (let i = 0; i < 5; i++) {
      writeSoundOn(false);
      strictEqual(plays(), false);
      writeSoundOn(true);
      strictEqual(plays(), true);
    }

    // A sound that fired while muted is only dropped: a later key plays.
    const handled = new Set<string>();
    const fire = (key: string) => {
      if (handled.has(key)) return false;
      handled.add(key);
      return plays();
    };
    writeSoundOn(false);
    strictEqual(fire(playKey("g", 1, 1)), false);
    writeSoundOn(true);
    strictEqual(fire(playKey("g", 1, 2)), true);

    // The browser suspended the context while muted: the unmute's tap resumes it.
    writeSoundOn(false);
    contextState = "suspended";
    writeSoundOn(true);
    strictEqual(plays(), false);
    strictEqual(audioRepair(contextState), "resume");
    contextState = "running";
    strictEqual(plays(), true);

    // It closed: replaced, never stuck until a reload.
    contextState = "closed";
    strictEqual(plays(), false);
    strictEqual(audioRepair(contextState), "make");
    contextState = "running";
    strictEqual(plays(), true);
  } finally {
    delete g.localStorage;
  }
});
check("sounds: a table opened with sound off has no context yet, and switching on makes one", () => {
  strictEqual(audioRepair(null), "make");
  strictEqual(audioRepair("interrupted"), "resume"); // iOS, after a call
  strictEqual(audioRepair("running"), null);
});
check("sounds: what stops a sound, each on its own", () => {
  const ok = { hidden: false, on: true, contextState: "running", loaded: true };
  strictEqual(cueAllowed(ok), true);
  strictEqual(cueAllowed({ ...ok, hidden: true }), false);
  strictEqual(cueAllowed({ ...ok, on: false }), false);
  strictEqual(cueAllowed({ ...ok, loaded: false }), false);
  for (const state of [null, "suspended", "interrupted", "closed"]) {
    strictEqual(cueAllowed({ ...ok, contextState: state }), false);
  }
});
check("sounds: the speaker sits above the deal overlay, so it works mid-deal", () => {
  const css = readFileSync("app/globals.css", "utf8");
  const zOf = (rule: string) => Number(css.match(new RegExp(`\\.${rule} \\{[^}]*z-index: (\\d+)`))?.[1]);
  strictEqual(zOf("sound-toggle") > zOf("deal-overlay"), true);
  strictEqual(readFileSync("components/table/SoundToggle.tsx", "utf8").includes('className="sound-toggle '), true);
});

check("sounds: a 19 hand has its own clip list, and SHOT! stays in the skunk tier", () => {
  deepStrictEqual(CORE_SOUNDS.zeroHand, ["/sounds/skunk-3-shot.mp3"]);
  strictEqual(CORE_SOUNDS.skunk.includes("/sounds/skunk-3-shot.mp3"), true);
  deepStrictEqual(soundFor("zeroHand", null, plainTable), CORE_SOUNDS.zeroHand);
  strictEqual(clipsFor(null).filter((c) => c === "/sounds/skunk-3-shot.mp3").length, 1); // loaded once
  strictEqual(pickClip(CORE_SOUNDS.zeroHand, CORE_SOUNDS.zeroHand[0]), CORE_SOUNDS.zeroHand[0]); // one clip still plays
  const later = ["/sounds/19-a.mp3", "/sounds/19-b.mp3"]; // a longer list never repeats
  let last: string | null = null;
  for (let i = 0; i < 100; i++) {
    const next = pickClip(later, last);
    strictEqual(next !== last, true);
    last = next;
  }
});
check("sounds: a 19 hand -- only a counted hand or crib of 0, never pegging", () => {
  strictEqual(isZeroCount(0, "hand: nothing"), true);
  strictEqual(isZeroCount(0, "crib: nothing"), true);
  strictEqual(isZeroCount(4, "hand: 15s 4"), false);
  strictEqual(isZeroCount(0, "fifteen"), false);
  strictEqual(isZeroCount(0, "go"), false);
  strictEqual(isZeroCount(0, "his heels"), false);
  strictEqual(isZeroCount(null, "hand: nothing"), false); // a New Game's reset
  strictEqual(isZeroCount(0, null), false);
});
check("sounds: a 19 hand -- silent wherever the count is hidden", () => {
  strictEqual(zeroSoundAllowed({ isMuggins: false, hideCounts: false }), true);
  strictEqual(zeroSoundAllowed({ isMuggins: true, hideCounts: false }), false);
  strictEqual(zeroSoundAllowed({ isMuggins: false, hideCounts: true }), false);
  strictEqual(zeroSoundAllowed({ isMuggins: true, hideCounts: true }), false);
});
check("sounds: a 19 hand -- one key per game, hand, player, and hand or crib", () => {
  const key = zeroKey("g", 3, "a", "hand: nothing");
  strictEqual(zeroKey("g", 3, "a", "hand: nothing"), key); // a repeated row
  strictEqual(zeroKey("g", 4, "a", "hand: nothing") === key, false);
  strictEqual(zeroKey("h", 3, "a", "hand: nothing") === key, false);
  strictEqual(zeroKey("g", 3, "b", "hand: nothing") === key, false);
  strictEqual(zeroKey("g", 3, "a", "crib: nothing") === key, false); // the dealer's hand, then their crib
  strictEqual(new Set([key, playKey("g", 3, 1), discardKey("g", 3, "a"), endKey("g")]).size, 4);
});
check("sounds: a 19 hand -- what a catch-up read finds is heard, not played", () => {
  const rows = [
    { user_id: "a", last_points: 0, last_reason: "hand: nothing" },
    { user_id: "b", last_points: 0, last_reason: "crib: nothing" },
    { user_id: "c", last_points: 2, last_reason: "pair" },
    { user_id: "d", last_points: null, last_reason: null },
  ];
  deepStrictEqual(heardZeroKeys("g", 3, rows), [zeroKey("g", 3, "a", "hand: nothing"), zeroKey("g", 3, "b", "crib: nothing")]);
});

// WINGS (lib/wings.ts).
const withStorage = (run: (store: Map<string, string>) => void) => {
  const store = new Map<string, string>();
  const g = globalThis as unknown as { localStorage?: unknown };
  g.localStorage = {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v),
    removeItem: (k: string) => void store.delete(k),
  };
  try {
    run(store);
  } finally {
    delete g.localStorage;
  }
};

check("wings: a tier at every threshold, and either side of it", () => {
  const expected: [number, string | null][] = [
    [0, null], [9, null],
    [10, "white"], [24, "white"],
    [25, "silver"], [49, "silver"],
    [50, "gold"], [99, "gold"],
    [100, "black"], [101, "black"],
  ];
  for (const [count, tier] of expected) strictEqual(tierForCount(count), tier, String(count));
});
check("wings: the next tier, and the Profile's progress line", () => {
  strictEqual(nextTier(0)?.tier, "white");
  strictEqual(nextTier(9)?.wins, 10);
  strictEqual(nextTier(10)?.tier, "silver");
  strictEqual(nextTier(99)?.tier, "black");
  strictEqual(nextTier(100), null);
  strictEqual(nextTier(101), null);
  strictEqual(progress(7).text, "7 / 10 to white wings");
  strictEqual(progress(0).text, "0 / 10 to white wings");
  strictEqual(progress(10).text, "10 / 25 to silver wings");
  strictEqual(progress(49).text, "49 / 50 to gold wings");
  strictEqual(progress(99).text, "99 / 100 to black wings");
  strictEqual(progress(100).text, "Black wings. Legend.");
  strictEqual(progress(250).text, "Black wings. Legend.");
  strictEqual(progress(30).tier, "silver");
});
check("wings: a milestone is exactly a tier's count", () => {
  for (const count of [10, 25, 50, 100]) strictEqual(isMilestone(count), true, String(count));
  for (const count of [0, 9, 11, 24, 26, 49, 51, 99, 101, 200]) strictEqual(isMilestone(count), false, String(count));
});
check("wings: the seen tier -- saved per player, safe with nothing stored", () => {
  strictEqual(readSeenTier("a"), null); // no localStorage at all, as here in Node
  writeSeenTier("a", "gold"); // and doesn't throw
  initSeenTier("a", 50);
  withStorage((store) => {
    strictEqual(readSeenTier("a"), null);
    writeSeenTier("a", "gold");
    strictEqual(store.get(wingsSeenKey("a")), "gold");
    strictEqual(wingsSeenKey("a"), "nobs:wings-seen:a");
    strictEqual(readSeenTier("a"), "gold");
    strictEqual(readSeenTier("b"), null); // per player
    writeSeenTier("a", null);
    strictEqual(readSeenTier("a"), "none");
    store.set(wingsSeenKey("a"), "purple");
    strictEqual(readSeenTier("a"), null); // an edited value is no value
  });
});
check("wings: launch is silent -- the first read notes the tier, and never celebrates", () => {
  withStorage(() => {
    // A player already on 30, seen for the first time.
    initSeenTier("a", 30);
    strictEqual(readSeenTier("a"), "silver");
    strictEqual(shouldCelebrate(30, readSeenTier("a")), false);
    // Exactly on a milestone at launch: still silent.
    initSeenTier("b", 50);
    strictEqual(shouldCelebrate(50, readSeenTier("b")), false);
    // No wins yet: "none", so the first tier will be the moment.
    initSeenTier("c", 3);
    strictEqual(readSeenTier("c"), "none");
    // A later read never moves it: only a celebration does.
    initSeenTier("c", 9);
    initSeenTier("a", 60);
    strictEqual(readSeenTier("c"), "none");
    strictEqual(readSeenTier("a"), "silver");
  });
});
check("wings: the moment fires once -- on the milestone, for a tier above the seen one", () => {
  strictEqual(shouldCelebrate(10, "none"), true);
  strictEqual(shouldCelebrate(25, "white"), true);
  strictEqual(shouldCelebrate(50, "silver"), true);
  strictEqual(shouldCelebrate(100, "gold"), true);
  strictEqual(shouldCelebrate(10, "white"), false); // a refresh: seen is written first
  strictEqual(shouldCelebrate(11, "none"), false); // not a milestone
  strictEqual(shouldCelebrate(9, "none"), false);
  strictEqual(shouldCelebrate(25, "gold"), false); // never down
  strictEqual(shouldCelebrate(10, null), false); // never read, or no storage
  withStorage(() => {
    initSeenTier("a", 9);
    strictEqual(shouldCelebrate(10, readSeenTier("a")), true);
    writeSeenTier("a", tierForCount(10));
    strictEqual(shouldCelebrate(10, readSeenTier("a")), false);
  });
});
check("wings: blocked storage never throws, and never celebrates", () => {
  const g = globalThis as unknown as { localStorage?: unknown };
  const blocked = () => {
    throw new Error("blocked");
  };
  g.localStorage = { getItem: blocked, setItem: blocked, removeItem: blocked };
  try {
    strictEqual(readSeenTier("a"), null);
    writeSeenTier("a", "gold");
    initSeenTier("a", 50);
    strictEqual(shouldCelebrate(50, readSeenTier("a")), false);
    strictEqual(readWingsOn(), true);
    writeWingsOn(false);
  } finally {
    delete g.localStorage;
  }
});
check("wings: the setting -- on by default, stored as 1 or 0", () => {
  strictEqual(WINGS_SETTING_KEY, "nobs:wings");
  strictEqual(readWingsOn(), true);
  withStorage((store) => {
    strictEqual(readWingsOn(), true);
    writeWingsOn(false);
    strictEqual(store.get("nobs:wings"), "0");
    strictEqual(readWingsOn(), false);
    writeWingsOn(true);
    strictEqual(store.get("nobs:wings"), "1");
    strictEqual(readWingsOn(), true);
  });
});
check("wings: the placement table -- every spot and width, as decided", () => {
  const shown = Object.fromEntries(
    Object.entries(WINGS_PLACEMENT).map(([spot, p]) => [spot, p.mode === "mini" ? `mini ${p.scale}` : p.mode])
  );
  deepStrictEqual(shown, {
    profile: "full",
    milestone: "full",
    "header-seat": "mini 2",
    "side-tag": "mini 2",
    "plate-2": "mini 2",
    "plate-3": "mini 1.4",
    "plate-4": "badge",
    "plate-teams": "mini 2",
    beer: "mini 2",
    "classic-seat": "badge",
    "classic-side": "badge",
    "home-greeting": "mini 2",
    "open-tables": "mini 2",
    leaderboard: "mini 2.2",
    "god-chip": "none",
    "opponent-chooser": "none",
  });
  strictEqual(placementFor("god-chip").mode, "none");
  strictEqual(placementFor("profile").scale, 1 / 0.381);
});
check("wings: full wings only on Profile and the milestone; nothing for God or a computer", () => {
  deepStrictEqual(Object.entries(WINGS_PLACEMENT).filter(([, p]) => p.mode === "full").map(([s]) => s).sort(), ["milestone", "profile"]);
  deepStrictEqual(Object.entries(WINGS_PLACEMENT).filter(([, p]) => p.mode === "none").map(([s]) => s).sort(), ["god-chip", "opponent-chooser"]);
});
check("wings: the margin is the overhang, (width - 1) / 2 x the avatar", () => {
  const near = (a: number, b: number) => strictEqual(Math.abs(a - b) < 1e-9, true, `${a} vs ${b}`);
  near(wingsOverhang(48, 2.2), 28.8); // the leaderboard: about 29px a side
  near(wingsOverhang(28, 2), 14); // 2-player and Teams plates
  near(wingsOverhang(28, 1.4), 5.6); // 3-player plates
  near(wingsOverhang(48, 2), 24); // the Home greeting and Open Tables
  near(wingsOverhang(24, 2), 12); // the side seat tags
  // The art fills exactly the avatar plus its margin on both sides.
  for (const [d, scale] of [[48, 2.2], [28, 1.4], [28, 2]] as const) {
    const box = wingsBox(d, scale);
    near(box.left, -wingsOverhang(d, scale));
    near(box.width, d + 2 * wingsOverhang(d, scale));
  }
});
check("plates: one layout for every table -- name over score, score at the right", () => {
  const strip = readFileSync("components/table/ScoreStrip.tsx", "utf8");
  // One plate row only: the side-by-side version is gone.
  strictEqual((strip.match(/className="plate-stack /g) ?? []).length, 1);
  strictEqual(strip.includes("StackedScoreStrip"), false);
  strictEqual(strip.includes('plate-stack__score self-end'), true);
  // The score's size rule: as big as the plate allows, 30px at most, 16px at least.
  strictEqual(readFileSync("app/globals.css", "utf8").includes("font-size: clamp(16px, 54cqi, 30px);"), true);
});
check("wings: a plate's spot comes from its row", () => {
  strictEqual(plateSpot(2, 1), "plate-2");
  strictEqual(plateSpot(3, 1), "plate-3");
  strictEqual(plateSpot(4, 1), "plate-4");
  strictEqual(plateSpot(2, 2), "plate-teams");
});
check("wings: the art's place -- mini 2.0 x and full 2.62 x, centred, the avatar at 68.35%", () => {
  const near = (a: number, b: number) => strictEqual(Math.abs(a - b) < 1e-6, true, `${a} vs ${b}`);
  near(WINGS_ASPECT, 695 / 1075);
  near(WINGS_CENTRE_Y, 475 / 695);
  const mini = wingsBox(28, 2);
  near(mini.width, 56);
  near(mini.left, -14); // the 0.5 x overhang the margin makes room for
  near(mini.top + mini.height * (475 / 695), 14); // the avatar's centre
  const full = wingsBox(96, 1 / 0.381);
  near(full.width, 96 / 0.381);
  near(full.left + full.width / 2, 48);
  near(full.top + full.height * (475 / 695), 48);
  near(full.height, full.width * (695 / 1075));
});
check("wings: the badge -- the four colours, 11px on a 28px avatar", () => {
  deepStrictEqual(WINGS_BADGE, { white: "#ffffff", silver: "#cfe0ff", gold: "#ffd24a", black: "#ff5a14" });
  strictEqual(badgeSize(28), 11);
  strictEqual(badgeSize(24), 9);
  strictEqual(badgeSize(48), 19);
});
check("wings: batches of up to 50, no repeats", () => {
  deepStrictEqual(idBatches([]), []);
  deepStrictEqual(idBatches(["a", "b", "a"]), [["a", "b"]]);
  const ids = Array.from({ length: 120 }, (_, i) => `u${i}`);
  deepStrictEqual(idBatches(ids).map((b) => b.length), [50, 50, 20]);
  deepStrictEqual(idBatches([...ids, ...ids]).flat(), ids);
});
check("wings: every asset exists, nothing on disk is unlisted, and the flames are whole", () => {
  for (const url of wingsAssets()) strictEqual(existsSync(`public${url}`), true, url);
  const listed = new Set(wingsAssets().map((url) => url.split("/").pop()));
  for (const file of readdirSync("public/wings")) strictEqual(listed.has(file), true, file);
  strictEqual(existsSync("docs/wings-art.md"), true); // the notes aren't served
  const flames = JSON.parse(readFileSync("public/wings/black-flames.json", "utf8"));
  strictEqual(flames.back.length + flames.front.length, 136);
  strictEqual(flames.embers.length, 26);
  for (const f of [...flames.back, ...flames.front]) {
    strictEqual(f.grad in flames.gradients, true);
    strictEqual(f.dur > 0, true);
  }
});
check("wings: a touch screen gets half the front flames and 12 embers; desktop gets all", () => {
  const flames = JSON.parse(readFileSync("public/wings/black-flames.json", "utf8"));
  const full = flamesForPointer<{ grad: string; d: string }, { cx: number }>(flames, false);
  strictEqual(full.front.length, 88);
  strictEqual(full.embers.length, 26);
  const thin = flamesForPointer<{ grad: string; d: string }, { cx: number }>(flames, true);
  strictEqual(thin.front.length, 44);
  strictEqual(thin.embers.length, 12);
  strictEqual(new Set(thin.embers).size, 12); // no ember twice
  // Whole pairs: every outer flame keeps its core.
  thin.front.forEach((f, i) => strictEqual(f.grad, i % 2 ? "fl2" : "fl"));
  strictEqual(flames.back.length + thin.front.length + thin.embers.length, 104);
  deepStrictEqual(flamesForPointer({ front: [], embers: [] }, true), { front: [], embers: [] });
});
check("wings: every tier has its splash words", () => {
  for (const t of WINGS_TIERS) strictEqual(WINGS_SPLASH[t.tier].length > 0, true, t.tier);
  strictEqual(wingsSplashSub(25), "25 wins against God");
});
check("wings: a player with no tier carries nothing, so no plate or board changes", () => {
  const row: PlateRow = { user_id: "a", name: "A", avatar_url: null, score: 0, last_points: null, last_reason: null, last_awarded_at: null };
  const one = (r: PlateRow) => buildPlates({ rows: [r], myId: "a", dealerId: null, teamsPlayers: null })[0].members[0];
  deepStrictEqual(one(row), { userId: "a", name: "A", avatarUrl: null });
  deepStrictEqual(one({ ...row, wings: null }), { userId: "a", name: "A", avatarUrl: null });
  deepStrictEqual(one({ ...row, wings: "gold" }), { userId: "a", name: "A", avatarUrl: null, wings: "gold" });
  const scene = beerScene(375, 117, [beerPlate("a", ["walt"], 10, { isMine: true }), beerPlate("b", ["nick"], 20)]);
  strictEqual(scene.avatars.every((a) => !("wings" in a)), true);
  const winged = beerScene(375, 117, [
    beerPlate("a", ["walt"], 10, { isMine: true, members: [{ userId: "a", name: "walt", avatarUrl: null, wings: "black" }] }),
    beerPlate("b", ["nick"], 20),
  ]);
  strictEqual(winged.avatars[0].wings, "black");
  strictEqual("wings" in winged.avatars[1], false);
});
check("wings: God's splash keeps its numbers after moving them to lossTier", () => {
  strictEqual(godLossSplash("hard", true, 120), "stinkhole");
  strictEqual(godLossSplash("hard", true, 60), "double-skunk");
  strictEqual(godLossSplash("hard", true, 90), "skunk");
  strictEqual(godLossSplash("hard", true, 91), null);
  strictEqual(splashDurationMs("wings"), SPLASH_MS);
});

console.log(`All ${passed} Phase 3 helper checks passed.`);
