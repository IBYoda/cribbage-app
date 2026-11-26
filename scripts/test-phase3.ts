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
import { existsSync, readdirSync, readFileSync as readFileSyncRaw, statSync } from "node:fs";
import { createRequire } from "node:module";
import { createHash } from "node:crypto";
import {
  WINGS_ASPECT,
  WINGS_BADGE,
  WINGS_HALO,
  WINGS_CENTRE_Y,
  WINGS_PLACEMENT,
  WINGS_SETTING_KEY,
  WINGS_SPLASH,
  WINGS_TIERS,
  ALL_WINGS_TIERS,
  CREATOR_USER_IDS,
  badgeSize,
  claimHomeWingsMoment,
  claimWingsMoment,
  displayTier,
  flamesForPointer,
  hasFlames,
  idBatches,
  isCreator,
  wingsUrl,
  initSeenTier,
  isMilestone,
  isNewLadderMilestone,
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
import { createTableArgs, fourPlayerModeOffered, newTableFields, startTableOptions } from "../lib/newTable";
import {
  GENERIC_ERROR_TEXT,
  QUIET_CLOSE_NOTE,
  RATE_LIMITED_TEXT,
  REFUSED_TEXT,
  TABLE_EMPTY_ENDED_TEXT,
  TABLE_ENDED_TEXT,
  TABLE_FULL_TEXT,
  alreadyAtTableText,
  createdTableCode,
  joinOutcome,
  lockedOutText,
  notFoundText,
  rpcRefusal,
  tableEndedMessage,
  tableHref,
  tableIdFromSearch,
  createdTable,
} from "../lib/oneTable";
import { confirmView, MUGGINS_CONFIRM_LINE, previewFromRow, previewHasSeat } from "../lib/joinConfirm";
import {
  FULL_TEXT,
  NOBODY_SEATED,
  NOT_ALLOWED_TEXT,
  PLAY_PARAM,
  REMOVED_TEXT,
  SPECTATOR_NO_GAME_TEXT,
  TABLE_CLOSED_TEXT,
  WATCH_RETRY_MS,
  followGame,
  canRemoveSpectator,
  heartbeatStep,
  isLiveGameStatus,
  mergeChatRoster,
  showSpectatorsEye,
  soundSeatId,
  spectatorEyeCount,
  withoutSpectator,
  isWatchableTable,
  joinOrWatch,
  joinRowAction,
  playChosenFromSearch,
  playHref,
  rewatchOutcome,
  rewatchStep,
  spectatorViewerId,
  spectatorWaitingLine,
  splitOpenTableRows,
  waitingForPlayerTitle,
  watchHref,
  watchRefusal,
  watchRowState,
} from "../lib/spectators";
import { mugginsPlateStates, type MugginsPlateState } from "../lib/mugginsPlates";
import { adminTableLabel, isStaleWaitingTable, seatedNames, STALE_WAITING_TABLE_MS } from "../lib/tableListing";
import { godLossAlt, godLossSplash, hideRejoinedScores, lossTier, scoreFromThisGame } from "../lib/resultScores";
import {
  BURST_WINDOW_MS,
  CARD_FADE_IN_S,
  CARD_TICK_S,
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
  clipTiming,
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
  NICKNAME_LOCKED_FALLBACK,
  NICKNAME_MAX_LENGTH,
  needsNickname,
  nicknameProblem,
  nicknameSaveErrorMessage,
  nicknameStepHref,
  safeReturnPath,
} from "../lib/nickname";
import {
  mergePlays,
  nextPollDelayMs,
  playsCatchUpApplies,
  POLL_JITTER,
  pollRefreshesProfiles,
  PROFILE_REFRESH_POLLS,
  profilesToFetch,
  SAFETY_POLL_BACKOFF_MS,
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
import { COMPUTER_LEVEL_ORDER } from "../lib/computer/config";
import {
  computerFaces,
  formatWinPercent,
  multiplayerRecord,
  PROFILE_SOLO_ORDER,
  shapeSoloStats,
  skunkChips,
  winPercent,
  type SoloStatsRow,
} from "../lib/soloStats";
import {
  ALL_PLAYERS,
  computerBoardText,
  filterFromSearch,
  friendsFromSearch,
  leaderboardChips,
  sameFilter,
  searchForFilter,
  searchForView,
} from "../lib/leaderboardFilter";
import {
  FOLLOW_FAILED_MESSAGE,
  FOLLOW_LIMIT_MESSAGE,
  FOLLOW_NOBODY_HINT,
  FOLLOW_RATE_MESSAGE,
  followErrorOutcome,
  followMessage,
  followSucceeded,
  friendsHint,
  friendsView,
  rankWithTies,
  toggledSet,
} from "../lib/follows";
import { AVATAR_TYPE_MESSAGE, avatarExtension, avatarPath } from "../lib/avatarPath";
import {
  ALREADY_BLOCKED_TEXT,
  BLOCK_FAILED_TEXT,
  BLOCK_LIMIT,
  BLOCK_LIMIT_TEXT,
  BLOCK_NOT_ALLOWED_TEXT,
  BLOCK_NOT_FOUND_TEXT,
  BLOCK_RATE_TEXT,
  BLOCKED_TEXT,
  UNBLOCKED_TEXT,
  UNNAMED_PLAYER,
  blockErrorOutcome,
  blockMessage,
  blockedPlayersFromRows,
  chatBlockFailureText,
  unblockMessage,
} from "../lib/blocks";
import {
  blockQuestion,
  canOfferPersonMenu,
  mutedAtTable,
  mutedMark,
  mutedMarkText,
  personPopupButtons,
  shouldAskToBlock,
  spectatorRowButtons,
} from "../lib/personMenu";
import {
  REPORT_CHOOSE_TEXT,
  REPORT_DELETE_QUESTION,
  REPORT_NOTE_MAX,
  REPORT_NOTE_PLACEHOLDER,
  REPORT_QUESTION,
  REPORT_REASONS,
  REPORTS_AUTO_DELETE_TEXT,
  REPORTS_EMPTY_TEXT,
  adminReportsFromRows,
  afterReportStep,
  countLine,
  nicknameThenNow,
  noteOneLine,
  reportFailureText,
  reportNote,
  reportOutcomeText,
  reportReasonWords,
  reportSentNotice,
  reportTitle,
  reportedBlockQuestion,
  showNoteCounter,
} from "../lib/reports";
import {
  acceptGameEvent,
  acceptTableEvent,
  gameEventStep,
  parseGameEvent,
  parseTableEvent,
  tableEventRole,
  tableEventTopic,
  type GameEvent,
  type GameSeen,
  type TableEvent,
} from "../lib/tableEvents";
import { newestPlayTime, playEventApplies, playsReadApplies } from "../lib/tableSync";
import { tableToStopWatching } from "../lib/spectators";
import {
  CHAT_MUTE_KEEP_MS,
  CHAT_MUTE_LIMIT,
  chatMutedKey,
  muteSender,
  mutedIdsText,
  parseMuted,
  readMutedIds,
  staleMuteKeys,
  touchMuted,
  unmuteSender,
  withMuted,
  withoutMuted,
} from "../lib/chatMute";
import {
  KICK_EVENT,
  KICK_FAILED_TEXT,
  KICK_GAME_LINE,
  isKickRefusal,
  kickConfirm,
  kickFailureText,
  kickNoticeAction,
  kickTopic,
  kickedNotice,
  parseKickNotice,
  recentKickLine,
  recentKicksFromRows,
} from "../lib/kicks";
import { cardName, comboText, handBreakdown, type HandBreakdown } from "../lib/handBreakdown";
import { scoreHand } from "../lib/scoring";
import {
  CHAT_LAYER_Z,
  CHAT_MAX_CARDS,
  CHAT_MAX_LENGTH,
  CHAT_MEMORY,
  OWN_CARD_FADE_MS,
  OWN_CARD_MS,
  addChatMessage,
  chatSenderId,
  chatStackCounts,
  chatStackRoom,
  chatThrottleAllows,
  chatTopic,
  cleanChatText,
  createChatThrottle,
  createPerSenderThrottle,
  ownCardShowing,
  ownChatCard,
  mutedSenders,
  visibleChatCards,
  withoutSenders,
  type ChatMessage,
} from "../lib/tableChat";
import { suitSymbol } from "../lib/cards";

let passed = 0;
// EVERY SOURCE READ in this file goes through here: text is returned with
// CRLF turned into LF, so the checks below give the same result on a CRLF
// working copy (core.autocrlf=true on Windows) as on an LF one -- the
// patterns are written with "\n". Binary reads (no encoding) are untouched.
function normalizeEol(text: string): string {
  return text.replace(/\r\n/g, "\n");
}
function readFileSync(path: string, encoding: "utf8"): string;
function readFileSync(path: string): Buffer;
function readFileSync(path: string, encoding?: "utf8"): string | Buffer {
  return encoding === undefined ? readFileSyncRaw(path) : normalizeEol(readFileSyncRaw(path, encoding));
}

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
        allow_spectators: false,
      });
    }
  }
  // 2-player Self-Scoring, private: as before.
  deepStrictEqual(newTableFields({ isPublic: false, isMuggins: true, maxPlayers: 2, fourPlayerMode: "teams" }), {
    is_public: false,
    is_muggins: true,
    max_players: 2,
    allow_spectators: false,
  });
  // 4 players, Teams (the default): team_mode 'teams', as before.
  deepStrictEqual(newTableFields({ ...base, maxPlayers: 4, fourPlayerMode: "teams" }), {
    is_public: true,
    is_muggins: false,
    max_players: 4,
    allow_spectators: false,
    team_mode: "teams",
  });
  // 4 players, Solo: team_mode 'solo' -- the row the solo verification
  // suite (docs/sql/phase3-solo-verification.sql, C1) proves is accepted.
  deepStrictEqual(newTableFields({ ...base, maxPlayers: 4, fourPlayerMode: "solo" }), {
    is_public: true,
    is_muggins: false,
    max_players: 4,
    allow_spectators: false,
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
        allow_spectators: false,
      });
      // 3 and 4: 'solo', whatever the (hidden) Team/Solo choice left behind
      // -- the database requires it for 4 (tables_muggins_no_teams).
      for (const n of [3, 4] as const) {
        deepStrictEqual(newTableFields({ isPublic, isMuggins: true, maxPlayers: n, fourPlayerMode: mode }), {
          is_public: isPublic,
          is_muggins: true,
          max_players: n,
          allow_spectators: false,
          team_mode: "solo",
        });
      }
    }
  }
});

// SPECTATORS (PRD item 40): Start a Table, Open Tables' Watch rows, and
// join-by-code's Watch instead (lib/newTable.ts, lib/spectators.ts).
check("Start a Table: create_table gets every option the form picks, as the function's own parameters; no direct insert", () => {
  // Since step 3 slice A the page calls create_table (docs/sql/join-create.sql),
  // and the lockdown revokes the old direct INSERT. Every option the form
  // picks must reach the function, under the parameter names it declares.
  const sql = readFileSync("docs/sql/join-create.sql", "utf8");
  const decl = sql.match(/create or replace function public\.create_table\(([\s\S]*?)\)\s*returns/);
  strictEqual(decl !== null, true, "create_table is declared in join-create.sql");
  const params = decl![1].split(",").map((p) => p.trim().split(/\s+/)[0]);
  deepStrictEqual(params, ["p_is_public", "p_is_muggins", "p_max_players", "p_team_mode", "p_allow_spectators"]);
  for (const isPublic of [false, true]) {
    for (const isMuggins of [false, true]) {
      for (const n of [2, 3, 4] as const) {
        for (const mode of ["teams", "solo"] as const) {
          for (const allowSpectators of [false, true]) {
            const input = { isPublic, isMuggins, maxPlayers: n, fourPlayerMode: mode, allowSpectators };
            const row = newTableFields(input);
            const args = createTableArgs(input);
            deepStrictEqual(Object.keys(args), params, "the same parameters, in order");
            deepStrictEqual(args, {
              p_is_public: row.is_public,
              p_is_muggins: row.is_muggins,
              p_max_players: row.max_players,
              // An omitted team_mode was the column default; NULL is the same on the server.
              p_team_mode: row.team_mode ?? null,
              p_allow_spectators: row.allow_spectators,
            });
          }
        }
      }
    }
  }
  // The page: the RPC, its answer's code, the one-table refusals; no insert, no code loop.
  const page = codeOnly(readFileSync("app/tables/new/page.tsx", "utf8"));
  strictEqual(/supabase\.rpc\(\s*"create_table",\s*createTableArgs\(\{ isPublic, isMuggins, maxPlayers, fourPlayerMode, allowSpectators \}\)\s*\)/.test(page), true);
  // The new table's code AND id (step 3 slice B): the link carries the id.
  strictEqual(page.includes("createdTable(data)"), true);
  strictEqual(page.includes("router.replace(tableHref(made.code, made.tableId));"), true);
  strictEqual(/\.from\(\s*"tables"\s*\)|\.insert\(|\.upsert\(|generateCode|UNIQUE_VIOLATION/.test(page), false, "no direct insert, no client-side code loop");
  strictEqual(page.includes("rpcRefusal(error)") && page.includes("<RefusalNotice refusal={refusal} />"), true);
  strictEqual(page.includes("{QUIET_CLOSE_NOTE}"), true);
});
check("One table at a time: refusals map to plain messages, never raw server text (lib/oneTable.ts)", () => {
  // already_at_table: the message and the table's code (HINT) for its button.
  deepStrictEqual(
    rpcRefusal({ message: "You're already at table 0815. Rejoin it or leave it first.", details: "already_at_table", hint: "0815", code: "P0001" }),
    { kind: "already_at_table", text: "You're already at table 0815. Rejoin it or leave it first.", tableCode: "0815" }
  );
  strictEqual(alreadyAtTableText("0815"), "You're already at table 0815. Rejoin it or leave it first.");
  // No usable code anywhere: generic, never a button to nowhere.
  deepStrictEqual(rpcRefusal({ message: "x", details: "already_at_table", hint: "" }), { kind: "unknown", text: GENERIC_ERROR_TEXT });
  // The code from the message when the HINT is missing.
  strictEqual((rpcRefusal({ message: "You're already at table 1234. Rejoin it or leave it first.", details: "already_at_table" }) as { tableCode?: string }).tableCode, "1234");
  // locked_out: says when they can try again.
  deepStrictEqual(
    rpcRefusal({ message: "Too many wrong table codes. Please wait 15 minutes and try again.", details: "locked_out" }),
    { kind: "locked_out", text: "Too many wrong table codes. You can try again in 15 minutes." }
  );
  strictEqual(rpcRefusal({ message: "Too many wrong table codes. Please wait 1 minute and try again.", details: "locked_out" }).text,
    "Too many wrong table codes. You can try again in 1 minute.");
  strictEqual(rpcRefusal({ message: "garbled", details: "locked_out" }).text, "Too many wrong table codes. Please wait a few minutes and try again.");
  // rate_limited: the server's own limit messages, else the plain one.
  for (const m of [
    "You can start at most 10 tables an hour. Please try again later.",
    "You can join at most 30 tables an hour. Please try again later.",
    "You can start watching at most 30 tables an hour. Please try again later.",
    "You can start at most 10 single-player games an hour. Please try again later.",
  ]) {
    deepStrictEqual(rpcRefusal({ message: m, details: "rate_limited" }), { kind: "rate_limited", text: m });
  }
  deepStrictEqual(rpcRefusal({ message: "relation x does not exist", details: "rate_limited" }), { kind: "rate_limited", text: RATE_LIMITED_TEXT });
  // The seat trigger's full table, as before.
  deepStrictEqual(rpcRefusal({ message: "This table is full." }), { kind: "full", text: TABLE_FULL_TEXT });
  // Anything else: generic (permission denied, a network failure, nothing at all).
  for (const e of [{ message: "permission denied for table tables", code: "42501" }, { message: "Failed to fetch" }, null, undefined]) {
    deepStrictEqual(rpcRefusal(e), { kind: "unknown", text: GENERIC_ERROR_TEXT });
  }
  // not_found: an answer, not an error.
  strictEqual(notFoundText("9999"), "No table found with code 9999.");
  strictEqual(tableHref("0815"), "/tables/0815");
  // join_table_by_code's outcome column and create_table's code.
  for (const o of ["joined", "already_seated", "preview", "not_found"] as const) {
    strictEqual(joinOutcome([{ outcome: o, table_id: null }]), o);
  }
  strictEqual(joinOutcome([]), null);
  strictEqual(joinOutcome([{ outcome: "weird" }]), null);
  strictEqual(joinOutcome(null), null);
  strictEqual(createdTableCode([{ table_id: "t", code: "0420" }]), "0420");
  strictEqual(createdTableCode([]), null);
  strictEqual(createdTableCode([{ code: "42" }]), null);
  // The button: RefusalNotice links already_at_table to its table.
  const notice = readFileSync("components/brand/RefusalNotice.tsx", "utf8");
  strictEqual(notice.includes('refusal.kind === "already_at_table"') && notice.includes("href={tableHref(refusal.tableCode, refusal.tableId)}"), true);
  strictEqual(notice.includes("Go to table {refusal.tableCode}"), true);
  // Every start that can quietly end a single-player game says so.
  for (const f of ["app/tables/new/page.tsx", "app/single-player/page.tsx", "app/tables/join/page.tsx"]) {
    strictEqual(readFileSync(f, "utf8").includes("{QUIET_CLOSE_NOTE}"), true, f);
  }
  strictEqual(QUIET_CLOSE_NOTE.length > 0, true);
});
check("Ended tables: each tables.ended_reason has its own message, 'empty' included; unknown reasons fall through", () => {
  // Step 3 slice C (docs/sql/end-empty-tables.sql): the last seat leaving ends the table as 'empty'.
  strictEqual(tableEndedMessage("empty", null), "Everyone left, so this table has closed.");
  strictEqual(TABLE_EMPTY_ENDED_TEXT, "Everyone left, so this table has closed.");
  // A computer table the sweep ended (a human seat removed without leave_computer_table).
  strictEqual(tableEndedMessage("empty", "easy"), TABLE_EMPTY_ENDED_TEXT);
  // The existing ones, unchanged.
  strictEqual(tableEndedMessage(null, "easy"), "This single-player game has ended.");
  strictEqual(tableEndedMessage("timeout", null), "This table was automatically ended after being open for 12 hours.");
  strictEqual(tableEndedMessage("admin", null), "This table has been ended by an admin.");
  strictEqual(tableEndedMessage("admin", "hard"), "This table has been ended by an admin.");
  // Unknown or missing reasons fall through to the admin message, as before.
  strictEqual(tableEndedMessage("something-new", null), "This table has been ended by an admin.");
  strictEqual(tableEndedMessage(null, null), "This table has been ended by an admin.");
  strictEqual(tableEndedMessage(undefined, undefined), "This table has been ended by an admin.");
  // Every screen that shows a reason goes through it: the realtime UPDATE, the stale-tab check, a reloaded URL.
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual((view.match(/setError\(tableEndedMessage\(/g) ?? []).length, 3);
  strictEqual(view.includes("setError(tableEndedMessage(updatedTable.ended_reason, level));"), true);
  strictEqual(view.includes("setError(tableEndedMessage(tableRow.ended_reason, tableRow.computer_level));"), true);
  strictEqual(/function tableEndedMessage\(/.test(view), false, "one definition, in lib/oneTable.ts");
  // The "table must be open" trigger's refusal reads plainly.
  deepStrictEqual(rpcRefusal({ message: "This table has ended.", code: "P0001" }), { kind: "ended", text: TABLE_ENDED_TEXT });
});
check("Slice B: links carry the table id (?t=) everywhere the app knows it", () => {
  const ID = "0f3c2b1a-1234-4abc-8def-0123456789ab";
  // The helpers: with an id, ?t=; without (or a malformed one), the bare code.
  strictEqual(tableHref("0815", ID), `/tables/0815?t=${ID}`);
  strictEqual(tableHref("0815"), "/tables/0815");
  strictEqual(tableHref("0815", "not-an-id"), "/tables/0815");
  strictEqual(watchHref("0815", ID), `/watch/0815?t=${ID}`);
  strictEqual(watchHref("0815"), "/watch/0815");
  strictEqual(playHref("0815", ID), `/tables/0815?t=${ID}&play=1`);
  strictEqual(playHref("0815"), "/tables/0815?play=1");
  strictEqual(playChosenFromSearch(`?t=${ID}&play=1`), true);
  strictEqual(tableIdFromSearch(`?t=${ID}`), ID);
  strictEqual(tableIdFromSearch(`?t=${ID.toUpperCase()}&play=1`), ID);
  strictEqual(tableIdFromSearch("?t=1234"), null);
  strictEqual(tableIdFromSearch(""), null);
  // Home: Rejoin, Join, the Play-or-Watch sheet and Watch rows all carry it; the loaders read it.
  const menu = readFileSync("components/brand/HomeMenu.tsx", "utf8");
  strictEqual(menu.includes("href={tableHref(t.code, t.id)} className=\"rejoin-btn\""), true);
  strictEqual(menu.includes("setChoosing({ code: t.code, hostName: t.hostName, id: t.id })"), true);
  strictEqual(menu.includes("href={watchHref(t.code, t.id)}"), true);
  strictEqual(/`\/tables\/\$\{/.test(codeOnly(menu)), false, "no bare /tables/ link left on Home");
  const reads = readFileSync("lib/openTables.ts", "utf8");
  strictEqual((reads.match(/^\s+id: t\.id,$/gm) ?? []).length, 5, "mine; joinable and watchable, each in its row and its result");
  const choice = readFileSync("components/brand/JoinChoice.tsx", "utf8");
  strictEqual(choice.includes("tableId={table.id}"), true);
  // After a create, single player, "Go to table", the watch page's seated redirect, Watch instead.
  strictEqual(readFileSync("app/tables/new/page.tsx", "utf8").includes("router.replace(tableHref(made.code, made.tableId));"), true);
  strictEqual(readFileSync("app/single-player/page.tsx", "utf8").includes("router.replace(made ? tableHref(made.code, made.tableId) : `/tables/${code}`);"), true);
  strictEqual(readFileSync("components/brand/RefusalNotice.tsx", "utf8").includes("href={tableHref(refusal.tableCode, refusal.tableId)}"), true);
  const watch = readFileSync("app/watch/[code]/page.tsx", "utf8");
  strictEqual(watch.includes("router.replace(tableHref(code, held));"), true);
  strictEqual(watch.includes("router.replace(tableHref(code, answer.preview.tableId));"), true);
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("<Link href={watchHref(code, heldId)} className=\"peg-btn peg-btn--brass\">"), true);
  strictEqual(view.includes("tableId={heldId}"), true);
  // createdTable: code and id, or null.
  deepStrictEqual(createdTable([{ table_id: ID, code: "0420" }]), { code: "0420", tableId: ID });
  strictEqual(createdTable([{ table_id: "x", code: "0420" }]), null);
  strictEqual(createdTable([]), null);
});
check("Slice B: the already_at_table HINT carries the id; an older bare HINT still works", () => {
  const ID = "0f3c2b1a-1234-4abc-8def-0123456789ab";
  deepStrictEqual(
    rpcRefusal({ message: "You're already at table 0815. Rejoin it or leave it first.", details: "already_at_table", hint: `0815 ${ID}` }),
    { kind: "already_at_table", text: "You're already at table 0815. Rejoin it or leave it first.", tableCode: "0815", tableId: ID }
  );
  deepStrictEqual(
    rpcRefusal({ message: "You're already at table 0815. Rejoin it or leave it first.", details: "already_at_table", hint: "0815" }),
    { kind: "already_at_table", text: "You're already at table 0815. Rejoin it or leave it first.", tableCode: "0815" }
  );
  // A HINT the app doesn't understand: the code from the message, no id.
  strictEqual((rpcRefusal({ message: "You're already at table 0815. Rejoin it or leave it first.", details: "already_at_table", hint: "junk" }) as { tableId?: string }).tableId, undefined);
});
check("Slice B: with ?t=, the table is read by id; a code that now belongs to another table reads as ended", () => {
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  const code = codeOnly(view);
  // Which table: the watch page's ticket, the id already held (Retry, Play's re-run), or the link's ?t=.
  strictEqual(code.includes("? (spectateRef.current?.tableId ?? null)"), true);
  strictEqual(code.includes(": (heldIdRef.current ?? tableIdFromSearch(window.location.search));"), true);
  // By id, never by code, once an id is known.
  strictEqual(/\.from\("tables"\)\s*\.select\(TABLE_ROW_COLUMNS\)\s*\.eq\("id", heldId\)/.test(code), true);
  strictEqual(/\.eq\("code", code\)/.test(code), false, "no lookup by code left");
  // A different table behind the code, or no row: "This table has ended.", closed (no Retry), never a seat.
  strictEqual(/if \(!tableRow \|\| tableRow\.code !== code\) \{[\s\S]{0,200}setClosedHumanTable\(true\);\s*setError\(TABLE_ENDED_TEXT\);\s*return;/.test(code), true);
  // An ended table read by id: its own reason.
  strictEqual(code.includes("setError(tableEndedMessage(tableRow.ended_reason, tableRow.computer_level));"), true);
  // The closed human table's screen: Back to home and Try a different code, no Retry.
  const closed = code.slice(code.indexOf(") : closedHumanTable ? ("), code.indexOf(") : (", code.indexOf(") : closedHumanTable ? (") + 5));
  strictEqual(closed.includes('<Link href="/" className="peg-btn peg-btn--brass">'), true);
  strictEqual(closed.includes('<Link href="/tables/join" className="peg-btn peg-btn--ghost">'), true);
  strictEqual(closed.includes("Retry"), false);
  strictEqual(TABLE_ENDED_TEXT, "This table has ended.");
});
check("Slice B: the confirm screen is only for a brand-new seat by a bare code (typed, or a link without ?t=)", () => {
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  const code = codeOnly(view);
  const bare = code.slice(code.indexOf("if (!heldId) {"), code.indexOf('.select(TABLE_ROW_COLUMNS)'));
  strictEqual(bare.length > 0, true);
  // The bare code is previewed (seats nobody); not found -> "No table found".
  strictEqual(bare.includes('playerRpc("join_table_by_code", {\n          p_code: code,\n          p_preview: true,\n        })'), true);
  strictEqual(bare.includes("setError(notFoundText(code));"), true);
  // Already seated: no confirm, straight in (no RPC), and the URL then carries the id.
  strictEqual(/if \(answer\.outcome === "already_seated"\) \{\s*router\.replace\(tableHref\(code, previewed\.id\), \{ scroll: false \}\);\s*await takeSeat\(previewed, \(\) => cancelled, true\);/.test(bare), true);
  // A new seat: the nickname step only when there's a seat, then the confirm screen.
  strictEqual(/if \(previewHasSeat\(answer\.preview\)\)[\s\S]{0,300}nicknameStepHref\(`\/tables\/\$\{code\}`\)/.test(bare), true);
  strictEqual(bare.includes("setConfirm(answer.preview);"), true);
  // The confirm is set ONLY there: never on the id path (in-app links, Open Tables rows).
  strictEqual((code.match(/setConfirm\(answer\.preview\)/g) ?? []).length, 1);
  strictEqual(code.indexOf("setConfirm(answer.preview)") < code.indexOf('.select(TABLE_ROW_COLUMNS)'), true);
  // Its Join takes exactly the previewed table, by id, and never asks Play again.
  strictEqual(/onJoin=\{\(\) => \{\s*const row = tableRowFromPreview\(previewed\);\s*playChosenRef\.current = true;\s*setConfirm\(null\);\s*router\.replace\(tableHref\(code, row\.id\), \{ scroll: false \}\);\s*void takeSeat\(row, \(\) => false, false\);/.test(code), true);
  // The screen's rules (lib/joinConfirm.ts).
  const base = {
    tableId: "0f3c2b1a-1234-4abc-8def-0123456789ab", code: "0815", status: "open", endedReason: null, isPublic: true,
    isMuggins: false, allowSpectators: false, createdBy: null, maxPlayers: 2, teamMode: "teams", computerLevel: null,
    seatedCount: 1, gameLive: false, hostNickname: "Sam", hostAvatarUrl: null,
  };
  const plain = confirmView(base, "join");
  strictEqual(plain.title, "Join table 0815 hosted by Sam?");
  deepStrictEqual(plain.join, { label: "Join" });
  strictEqual(plain.watch, false);
  strictEqual(plain.mugginsLine, null);
  strictEqual(plain.seatsLine, "1 of 2 seats taken");
  deepStrictEqual(plain.badges, ["2 players"]);
  // Play-or-Watch folded in: Join AND Watch when the table allows spectators.
  const both = confirmView({ ...base, allowSpectators: true }, "join");
  strictEqual(both.join !== null && both.watch, true);
  deepStrictEqual(both.badges, ["2 players", "Spectators allowed"]);
  // Muggins folded in: the line and the agreeing button.
  const mug = confirmView({ ...base, isMuggins: true, maxPlayers: 4, teamMode: "solo" }, "join");
  strictEqual(mug.mugginsLine, MUGGINS_CONFIRM_LINE);
  deepStrictEqual(mug.join, { label: "Join Self-Scoring (Muggins) table" });
  deepStrictEqual(mug.badges, ["Self-Scoring (Muggins)", "4 players"]);
  deepStrictEqual(confirmView({ ...base, maxPlayers: 4, teamMode: "solo" }, "join").badges, ["4 players", "Solo"]);
  deepStrictEqual(confirmView({ ...base, maxPlayers: 4, teamMode: "teams" }, "join").badges, ["4 players", "Teams"]);
  // Full or started: no seat; Watch only if allowed.
  const full = confirmView({ ...base, seatedCount: 2, allowSpectators: true }, "join");
  strictEqual(full.join, null);
  strictEqual(full.watch, true);
  strictEqual(full.notice, "Table 0815 is full. You can watch the game instead.");
  const started = confirmView({ ...base, gameLive: true }, "join");
  strictEqual(started.join, null);
  strictEqual(started.watch, false);
  strictEqual(started.notice, "The game at table 0815 has already started. This table doesn't allow spectators.");
  // A single-player table: nothing to take, nothing to watch.
  const solo = confirmView({ ...base, computerLevel: "easy" }, "join");
  strictEqual(solo.join === null && !solo.watch, true);
  strictEqual(solo.title, "Table 0815 is a single-player game.");
  // No host name: the title without one.
  strictEqual(confirmView({ ...base, hostNickname: null }, "join").title, "Join table 0815?");
  strictEqual(previewHasSeat(base), true);
  strictEqual(previewHasSeat({ ...base, seatedCount: 2 }), false);
  strictEqual(previewHasSeat({ ...base, gameLive: true }), false);
  // The preview's row.
  deepStrictEqual(previewFromRow([{ outcome: "not_found" }]), { outcome: "not_found" });
  strictEqual(previewFromRow([]), null);
  strictEqual(previewFromRow([{ outcome: "preview", table_id: "nope", code: "0815" }]), null);
  const row = previewFromRow([{ outcome: "already_seated", table_id: base.tableId, code: "0815", status: "open", is_muggins: false,
    allow_spectators: true, max_players: 3, team_mode: "teams", computer_level: null, seated_count: 2, game_live: false,
    host_nickname: "Sam", host_avatar_url: "https://x/a.png", created_by: base.tableId, is_public: false, ended_reason: null }]);
  strictEqual(row !== null && row.outcome === "already_seated" && row.preview.maxPlayers === 3 && row.preview.hostAvatarUrl === "https://x/a.png", true);
});
check("Slice B: the watch confirm -- a bare /watch/<code> previews first; with ?t= one tap, by id", () => {
  // Watch mode: Watch only, or why not.
  const base = {
    tableId: "0f3c2b1a-1234-4abc-8def-0123456789ab", code: "0815", status: "open", endedReason: null, isPublic: true,
    isMuggins: false, allowSpectators: true, createdBy: null, maxPlayers: 2, teamMode: "teams", computerLevel: null,
    seatedCount: 2, gameLive: true, hostNickname: "Sam", hostAvatarUrl: null,
  };
  const w = confirmView(base, "watch");
  strictEqual(w.title, "Watch table 0815 hosted by Sam?");
  strictEqual(w.watch && w.join === null && w.notice === null, true);
  const no = confirmView({ ...base, allowSpectators: false }, "watch");
  strictEqual(!no.watch && no.notice === "This table doesn't allow spectators.", true);
  strictEqual(confirmView({ ...base, computerLevel: "hard", allowSpectators: false }, "watch").notice, "Computer tables cannot be watched.");
  const page = codeOnly(readFileSync("app/watch/[code]/page.tsx", "utf8"));
  // No id: the preview, then the confirm (not found, seated -> the seat, refusals).
  strictEqual(page.includes("const held = heldIdRef.current ?? tableIdFromSearch(window.location.search);"), true);
  strictEqual(/if \(!held\) \{\s*const answer = await callTablePreview\(code\);/.test(page), true);
  strictEqual(page.includes('setState({ kind: "confirm", preview: answer.preview });'), true);
  strictEqual(page.includes("setState({ kind: \"refused\", text: notFoundText(code), login: false });"), true);
  // With the id: watch_table by id; no row = closed.
  strictEqual(page.includes("const result = await trackedWatch(code, held);"), true);
  strictEqual(/if \("closed" in result\) \{\s*setState\(\{ kind: "closed" \}\);/.test(page), true);
  // The confirm's Watch: by the previewed id, the URL then carries it.
  strictEqual(/onWatch=\{\(\) => \{\s*heldIdRef\.current = previewed\.tableId;\s*router\.replace\(watchHref\(code, previewed\.tableId\), \{ scroll: false \}\);/.test(page), true);
  strictEqual(page.includes('mode="watch"'), true);
  // The preview changes nothing: it is join_table_by_code with p_preview: true, and only that.
  strictEqual(readFileSync("lib/spectatorData.ts", "utf8").includes('supabase.rpc("join_table_by_code", { p_code: code, p_preview: true })'), true);
});
check("Slice B: the spectator's rewatch, the seat and Retry go by id", () => {
  const page = codeOnly(readFileSync("app/watch/[code]/page.tsx", "utf8"));
  strictEqual(page.includes("const again = await trackedWatch(code, ticketRef.current?.tableId ?? heldIdRef.current);"), true);
  // A rewatch with no row by id: closed, never the table that holds the code now.
  deepStrictEqual(rewatchStep({ closed: true }), { kind: "closed" });
  const data = codeOnly(readFileSync("lib/spectatorData.ts", "utf8"));
  strictEqual(data.includes('tableId ? { p_code: code, p_table_id: tableId } : { p_code: code }'), true);
  // The spectating table view reads the ticket's table, by id.
  strictEqual(page.includes("tableId: watchingTableId,"), true);
  const view = codeOnly(readFileSync("components/table/TableView.tsx", "utf8"));
  // The seat: by id.
  strictEqual(view.includes('playerRpc("join_table_by_code", { p_code: row.code, p_table_id: row.id })'), true);
  // Retry and Play's re-run re-run the setup, which reads heldIdRef first (set once the table is known).
  strictEqual(view.includes("heldIdRef.current = tableRow.id;"), true);
  strictEqual(view.includes("heldIdRef.current = answer.preview.tableId;"), true);
  strictEqual(view.includes("setRetryKey((k) => k + 1)"), true);
});
check("Single player: create_computer_table keeps its code retry and 'not set up yet', and maps the one-table refusals", () => {
  const page = readFileSync("app/single-player/page.tsx", "utf8");
  strictEqual(page.includes("if (error.code === UNIQUE_VIOLATION) {\n        continue;\n      }") || page.includes("if (error.code === UNIQUE_VIOLATION) {\r\n        continue;\r\n      }"), true);
  strictEqual(page.includes('error.message.includes("not set up yet")'), true);
  strictEqual(page.includes("const why = rpcRefusal(error);"), true);
  strictEqual(page.includes('logUnexpectedError("create_computer_table", error)'), true);
  strictEqual(page.includes("<RefusalNotice refusal={refusal} />"), true);
  // No raw server text on screen.
  strictEqual(/:\s*error\.message\b/.test(codeOnly(page)), false);
});
check("Join: takeSeat seats through join_table_by_code and maps every outcome; a seated player makes no call", () => {
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  const code = codeOnly(view);
  const seat = code.slice(code.indexOf("const takeSeat = useCallback("), code.indexOf("// Look up the table, join it"));
  strictEqual(seat.length > 0, true);
  // A seated player (a refresh, Rejoin, the creator from create_table) makes no call.
  strictEqual(/async \(row: TableRow, isCancelled: \(\) => boolean, alreadySeated = false\) => \{/.test(seat), true);
  // By the table's id (step 3 slice B): exactly this table, never whatever holds the code now.
  strictEqual(seat.includes('const { data, error: joinError } = await playerRpc("join_table_by_code", { p_code: row.code, p_table_id: row.id });'), true);
  strictEqual(/if \(!alreadySeated\) \{/.test(seat), true);
  // Refusals: plain text, already_at_table keeps its code for the button, unknown is logged.
  strictEqual(seat.includes("const why = rpcRefusal(joinError);"), true);
  strictEqual(seat.includes('setGoToCode(why.kind === "already_at_table" ? why.tableCode : null);'), true);
  strictEqual(seat.includes('if (why.kind === "unknown") logUnexpectedError("join_table_by_code", joinError);'), true);
  strictEqual(seat.includes("setError(joinError.message)"), false, "never raw server text");
  // Outcomes: not_found -> not found; joined / already_seated -> the table; anything else -> generic.
  // not_found with the id = this table ended (or its code moved on): closed, "This table has ended."
  strictEqual(/if \(outcome === "not_found"\) \{\s*setClosedHumanTable\(true\);\s*setError\(TABLE_ENDED_TEXT\);/.test(seat), true);
  strictEqual(/if \(outcome !== "joined" && outcome !== "already_seated"\) \{[\s\S]{0,120}setError\(GENERIC_ERROR_TEXT\);/.test(seat), true);
  strictEqual(seat.includes("await refreshTableState(row.id);"), true);
  // The setup passes isMember; the Muggins notice's Join is a new seat.
  strictEqual(code.includes("await takeSeat(tableRow, () => cancelled, isMember);"), true);
  strictEqual(code.includes("takeSeat(row, () => false);"), true);
  // The error screen: Go to table NNNN for already_at_table.
  strictEqual(view.includes("<Link href={tableHref(goToCode, goToId)} className=\"peg-btn peg-btn--brass\">"), true);
  strictEqual(view.includes("Go to table {goToCode}"), true);
  // Play-or-Watch still comes before the nickname gate, the Muggins notice and the seat.
  strictEqual(view.indexOf('setWatchOffer("choose")') < view.indexOf("// THE NICKNAME GATE."), true);
  strictEqual(view.indexOf("// THE NICKNAME GATE.") < view.indexOf("// THE JOINER'S MUGGINS NOTICE. A Muggins"), true);
  strictEqual(view.indexOf("// THE JOINER'S MUGGINS NOTICE. A Muggins") < view.indexOf("await takeSeat(tableRow, () => cancelled, isMember);"), true);
});
check("Stale tab: losing my own seat reads the table's status once; an ended single-player game shows its ended screen", () => {
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  // Both signs: the roster read without me, and the realtime DELETE of my row.
  strictEqual(/if \(me && membersRef\.current\.some\(\(m\) => m\.user_id === me\) && !fresh\.some\(\(m\) => m\.user_id === me\)\) \{\s*checkTableEndedRef\.current\(tableId\);/.test(view), true);
  strictEqual(view.includes("if (goneRow.user_id === myUserIdRef.current) checkTableEndedRef.current(table.id);"), true);
  // The check: never a spectator or my own Leave; an ended table gets its message.
  strictEqual(/checkTableEndedRef\.current = \(tableId: string\) => \{\s*if \(spectating \|\| leavingRef\.current\) return;/.test(view), true);
  strictEqual(/\.select\("status, ended_reason, computer_level"\)\s*\.eq\("id", tableId\)/.test(view), true);
  strictEqual(view.includes("setError(tableEndedMessage(data.ended_reason, data.computer_level));"), true);
  strictEqual(readFileSync("lib/oneTable.ts", "utf8").includes('if (computerLevel && endedReason == null) return "This single-player game has ended.";'), true);
  // The closed screen offers a new single-player game and home.
  strictEqual(view.includes('<Link href="/single-player" className="peg-btn peg-btn--brass">'), true);
});
check("Watch page: an already_at_table refusal gets its Go to table button; unknown refusals are logged", () => {
  const page = readFileSync("app/watch/[code]/page.tsx", "utf8");
  strictEqual(page.includes("href={tableHref(state.tableCode, state.tableId)}"), true);
  strictEqual(page.includes("Go to table {state.tableCode}"), true);
  strictEqual(page.includes('if (refusal.kind === "other") console.error('), true);
  const data = readFileSync("lib/spectatorData.ts", "utf8");
  strictEqual(data.includes('return { refused: why.text, goTo: { code: why.tableCode, tableId: why.tableId } };'), true);
  strictEqual(data.includes('if (why.kind === "locked_out" || why.kind === "rate_limited")'), true);
});
check("Start a Table: allow_spectators is always sent, false unless ticked", () => {
  for (const n of [2, 3, 4] as const) {
    for (const isMuggins of [false, true]) {
      const base = { isPublic: true, isMuggins, maxPlayers: n, fourPlayerMode: "teams" as const };
      strictEqual(newTableFields(base).allow_spectators, false, `${n} ${isMuggins} default`);
      strictEqual(newTableFields({ ...base, allowSpectators: false }).allow_spectators, false, `${n} ${isMuggins} off`);
      strictEqual(newTableFields({ ...base, allowSpectators: true }).allow_spectators, true, `${n} ${isMuggins} on`);
    }
  }
  // Ticking it changes nothing else in the row.
  const off = newTableFields({ isPublic: false, isMuggins: false, maxPlayers: 4, fourPlayerMode: "solo" });
  const on = newTableFields({ isPublic: false, isMuggins: false, maxPlayers: 4, fourPlayerMode: "solo", allowSpectators: true });
  deepStrictEqual({ ...on, allow_spectators: false }, off);
  // The computer-table path never builds its row here: create_computer_table
  // lists its own columns, and the page that calls it never sends this field.
  const single = readFileSync("app/single-player/page.tsx", "utf8");
  strictEqual(single.includes("create_computer_table") && !single.includes("allow_spectators") && !single.includes("newTableFields"), true);
});
const WATCH_NOW = Date.parse("2026-11-20T12:00:00Z");
const watchable = {
  status: "open",
  isPublic: true,
  allowSpectators: true,
  computerLevel: null,
  seatedIds: ["h", "g"],
  capacity: 2,
  gameLive: true,
  createdAt: "2026-11-20T11:00:00Z",
};
check("Open Tables: a Watch row needs open, public, spectators allowed, human, viewer not seated, and a live game OR a full table", () => {
  strictEqual(isWatchableTable(watchable, "v", WATCH_NOW), true);
  strictEqual(isWatchableTable({ ...watchable, status: "ended" }, "v", WATCH_NOW), false, "ended");
  strictEqual(isWatchableTable({ ...watchable, isPublic: false }, "v", WATCH_NOW), false, "private: never listed");
  strictEqual(isWatchableTable({ ...watchable, allowSpectators: false }, "v", WATCH_NOW), false, "no spectators");
  strictEqual(isWatchableTable({ ...watchable, allowSpectators: null }, "v", WATCH_NOW), false, "unknown");
  strictEqual(isWatchableTable({ ...watchable, computerLevel: "easy" }, "v", WATCH_NOW), false, "computer");
  // JOIN-OR-WATCH: a FULL table that has not started is a Watch row too ...
  strictEqual(isWatchableTable({ ...watchable, gameLive: false }, "v", WATCH_NOW), true, "full, not started");
  strictEqual(isWatchableTable({ ...watchable, gameLive: false, seatedIds: ["a", "b", "c", "d"], capacity: 4 }, "v", WATCH_NOW), true, "4/4");
  // ... but a free seat before the game is a Join row (Play or Watch), never a Watch row.
  strictEqual(isWatchableTable({ ...watchable, gameLive: false, seatedIds: ["h"] }, "v", WATCH_NOW), false, "1/2, not started");
  strictEqual(isWatchableTable({ ...watchable, gameLive: false, seatedIds: ["a", "b", "c"], capacity: 4 }, "v", WATCH_NOW), false, "3/4");
  strictEqual(isWatchableTable({ ...watchable, seatedIds: ["h"] }, "v", WATCH_NOW), true, "a free seat but the game is on");
  strictEqual(isWatchableTable(watchable, "g", WATCH_NOW), false, "the viewer is seated");
  strictEqual(isWatchableTable({ ...watchable, seatedIds: [] }, "v", WATCH_NOW), false, "nobody seated");
  // The joinable list's age rule: never hides a live game, however old; hides an old waiting one.
  strictEqual(isWatchableTable({ ...watchable, createdAt: "2026-11-19T12:00:00Z" }, "v", WATCH_NOW), true, "old but live");
  strictEqual(isWatchableTable({ ...watchable, gameLive: false, createdAt: "2026-11-19T12:00:00Z" }, "v", WATCH_NOW), false, "old, full, never started");
  strictEqual(isLiveGameStatus("cutting") && isLiveGameStatus("active"), true);
  strictEqual(isLiveGameStatus("ended") || isLiveGameStatus(null), false);
  strictEqual(watchHref("0427"), "/watch/0427");
  // The row says which: the game is on, or the table is full and waiting.
  strictEqual(watchRowState(true), "Game in progress");
  strictEqual(watchRowState(false), "Not started");
});
check("Join-or-Watch: joinOrWatch answers watch | choose | seat", () => {
  const t = { isMember: false, seated: 2, capacity: 2, gameLive: true, allowSpectators: true, computerLevel: null };
  strictEqual(joinOrWatch(t), "watch", "full, game on");
  strictEqual(joinOrWatch({ ...t, gameLive: false }), "watch", "full, between games");
  strictEqual(joinOrWatch({ ...t, seated: 1, gameLive: true }), "watch", "a seat free but the game started");
  // A free seat before the game, spectators allowed: ask Play or Watch.
  strictEqual(joinOrWatch({ ...t, seated: 1, gameLive: false }), "choose", "1/2, not started");
  strictEqual(joinOrWatch({ ...t, seated: 0, gameLive: false }), "choose", "0/2, not started");
  strictEqual(joinOrWatch({ ...t, seated: 3, capacity: 4, gameLive: false }), "choose", "3/4, not started");
  strictEqual(joinOrWatch({ ...t, seated: 1, capacity: 3, gameLive: false }), "choose", "1/3, not started");
  // Chose Play already: the seat, never the choice again ...
  strictEqual(joinOrWatch({ ...t, seated: 1, gameLive: false, playChosen: true }), "seat", "chose Play");
  strictEqual(joinOrWatch({ ...t, seated: 3, capacity: 4, gameLive: false, playChosen: true }), "seat", "chose Play, 4 players");
  // ... unless the seat has gone meanwhile (Watch instead, as before).
  strictEqual(joinOrWatch({ ...t, playChosen: true }), "watch", "chose Play, but the table filled and started");
  strictEqual(joinOrWatch({ ...t, gameLive: false, playChosen: true }), "watch", "chose Play, but the table filled");
  // Exactly as before: seated, no spectators, unknown, a computer table.
  strictEqual(joinOrWatch({ ...t, isMember: true }), "seat", "already seated: back to their seat");
  strictEqual(joinOrWatch({ ...t, isMember: true, seated: 1, gameLive: false }), "seat", "seated, not started: no choice");
  strictEqual(joinOrWatch({ ...t, allowSpectators: false }), "seat", "no spectators: exactly as today");
  strictEqual(joinOrWatch({ ...t, allowSpectators: false, seated: 1, gameLive: false }), "seat", "no spectators, free seat: straight in");
  strictEqual(joinOrWatch({ ...t, allowSpectators: null, seated: 1, gameLive: false }), "seat", "unknown: as today");
  strictEqual(joinOrWatch({ ...t, computerLevel: "hard", seated: 1, gameLive: false }), "seat", "computer table: as today");
  strictEqual(joinOrWatch({ ...t, seated: 4, capacity: 4 }), "watch", "4 players, full");
});
check("Join-or-Watch: the table's creator never gets the choice -- seat, at every table size", () => {
  // Start a Table lands the creator on the table page before their seat exists.
  for (const capacity of [2, 3, 4]) {
    const fresh = { isMember: false, seated: 0, capacity, gameLive: false, allowSpectators: true, computerLevel: null };
    strictEqual(joinOrWatch({ ...fresh, isCreator: true }), "seat", `creator, new ${capacity}-player table`);
    strictEqual(joinOrWatch({ ...fresh, seated: capacity - 1, isCreator: true }), "seat", `creator, ${capacity - 1}/${capacity}`);
    // Anyone else in the same state: the choice.
    strictEqual(joinOrWatch(fresh), "choose", `non-creator, new ${capacity}-player table`);
    strictEqual(joinOrWatch({ ...fresh, isCreator: false }), "choose", `non-creator (false), ${capacity}`);
    strictEqual(joinOrWatch({ ...fresh, seated: capacity - 1 }), "choose", `non-creator, ${capacity - 1}/${capacity}`);
    // A creator who finds it full or started (left and came back): unchanged, watch.
    strictEqual(joinOrWatch({ ...fresh, seated: capacity, isCreator: true }), "watch", `creator, full ${capacity}`);
    strictEqual(joinOrWatch({ ...fresh, seated: capacity - 1, gameLive: true, isCreator: true }), "watch", `creator, started ${capacity}`);
    // Seated: seat. No spectators: seat.
    strictEqual(joinOrWatch({ ...fresh, isMember: true, seated: 1, isCreator: true }), "seat", `creator seated, ${capacity}`);
    strictEqual(joinOrWatch({ ...fresh, allowSpectators: false, isCreator: true }), "seat", `creator, no spectators, ${capacity}`);
    strictEqual(joinOrWatch({ ...fresh, allowSpectators: false, seated: capacity, isCreator: true }), "seat", `creator, no spectators, full ${capacity}`);
  }
  // Home: a creator who left sees their table as a plain Join, never the sheet.
  strictEqual(joinRowAction({ allowSpectators: true, isCreator: true }), "join");
  strictEqual(joinRowAction({ allowSpectators: true, isCreator: false }), "choose");
  // The table page reads it from the table row it already has (no extra query).
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("isCreator: tableRow.created_by === session!.user.id,"), true);
  const setup = view.slice(view.indexOf("// WATCH INSTEAD (joinOrWatch"), view.indexOf("// THE NICKNAME GATE."));
  strictEqual(/\.from\(/.test(setup.slice(setup.indexOf("joinOrWatch({"))), false, "no read after the rule");
  // The joinable read carries created_by into isCreator, and the menu passes it on.
  const reads = readFileSync("lib/openTables.ts", "utf8");
  strictEqual(reads.includes("created_at, created_by, allow_spectators, table_members(user_id, seat)"), true);
  strictEqual(reads.includes("isCreator: t.created_by === userId,"), true);
  strictEqual(readFileSync("components/brand/HomeMenu.tsx", "utf8").includes("joinRowAction({ allowSpectators: t.allowSpectators ?? false, isCreator: t.isCreator })"), true);
});
check("Join-or-Watch: choosing Play never asks again (?play=1 from Home, a flag on the table page)", () => {
  strictEqual(PLAY_PARAM, "play");
  strictEqual(playHref("0427"), "/tables/0427?play=1");
  strictEqual(playChosenFromSearch("?play=1"), true);
  strictEqual(playChosenFromSearch("?layout=classic&play=1"), true);
  strictEqual(playChosenFromSearch(""), false);
  strictEqual(playChosenFromSearch("?play=0"), false);
  strictEqual(playChosenFromSearch("?layout=classic"), false);
  // Home's sheet: Play links to playHref; Watch to the watch page; Cancel closes.
  const choice = readFileSync("components/brand/JoinChoice.tsx", "utf8");
  // Both carry the table's id (?t=, step 3 slice B).
  strictEqual(choice.includes("<Link href={playHref(code, tableId)}"), true);
  strictEqual(choice.includes("<Link href={watchHref(code, tableId)}"), true);
  strictEqual(choice.includes("onClick={onCancel}"), true);
  // 44px targets with 12px corners.
  const css = readFileSync("app/globals.css", "utf8");
  strictEqual(/\.join-choice__btn \{[^}]*min-height: 44px;[^}]*border-radius: 12px;/.test(css), true);
  strictEqual(/\.join-choice__cancel \{[^}]*min-height: 44px;[^}]*border-radius: 12px;/.test(css), true);
  // The table page: the flag or the URL decides; its own Play sets the flag and re-runs the setup.
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("playChosen: playChosenRef.current || playChosenFromSearch(window.location.search),"), true);
  strictEqual(/onPlay=\{\(\) => \{\s*playChosenRef\.current = true;\s*setWatchOffer\(null\);\s*setRetryKey\(\(k\) => k \+ 1\);/.test(view), true);
  // "choose" shows the choice and stops BEFORE any seat, nickname gate or Muggins notice.
  const setup = view.slice(view.indexOf("// WATCH INSTEAD (joinOrWatch"), view.indexOf("// THE NICKNAME GATE."));
  strictEqual(/if \(choice === "choose"\) \{\s*setWatchOffer\("choose"\);\s*return;\s*\}/.test(setup), true);
  strictEqual(view.indexOf('setWatchOffer("choose")') < view.indexOf("await takeSeat(tableRow"), true);
  // The full / started "Watch instead" screens stay.
  strictEqual(view.includes("You can watch the game instead."), true);
});
check("Open Tables: one row per table -- Join (with the choice), Join (straight in), Watch for full-not-started, Watch for started", () => {
  const mine = new Set(["9000"]);
  const joinable = [
    { code: "1111", allowSpectators: true }, // free seat, not started, spectators: Join -> choice
    { code: "2222", allowSpectators: false }, // free seat, no spectators: Join straight in
    { code: "3333", allowSpectators: true }, // free seat but a live game: listed by both reads
    { code: "9000", allowSpectators: true }, // the viewer's own table
  ];
  const watchableRows = [
    { code: "3333", gameLive: true },
    { code: "4444", gameLive: false }, // full, not started
    { code: "5555", gameLive: true }, // full, started
    { code: "9000", gameLive: true },
  ];
  const { joinRows, watchRows } = splitOpenTableRows(mine, joinable, watchableRows);
  deepStrictEqual(joinRows.map((t) => t.code), ["1111", "2222"]);
  deepStrictEqual(watchRows.map((t) => t.code), ["3333", "4444", "5555"]);
  deepStrictEqual(joinRows.map((t) => joinRowAction(t)), ["choose", "join"]);
  deepStrictEqual(watchRows.map((t) => watchRowState(t.gameLive)), ["Game in progress", "Not started", "Game in progress"]);
  strictEqual(joinRowAction({ allowSpectators: true, computerLevel: "easy" }), "join");
  strictEqual(joinRowAction({ allowSpectators: null }), "join");
  // The joinable read selects allow_spectators and carries it; Watch rows carry gameLive.
  const reads = readFileSync("lib/openTables.ts", "utf8");
  strictEqual(reads.includes('.select("id, code, status, is_public, is_muggins, max_players, created_at, created_by, allow_spectators, table_members(user_id, seat)")'), true);
  strictEqual(reads.includes("allowSpectators: t.allow_spectators === true,"), true);
  strictEqual(reads.includes("capacity: t.max_players ?? 2,\n        gameLive: live.has(t.id),"), true);
  // The menu: a "choose" Join opens the sheet (a button); a plain Join is the old link; Watch says its state.
  const menu = readFileSync("components/brand/HomeMenu.tsx", "utf8");
  strictEqual(menu.includes("splitOpenTableRows(myCodes, joinable ?? [], state.watchable ?? [])"), true);
  strictEqual(/joinRowAction\(\{ allowSpectators: t\.allowSpectators \?\? false, isCreator: t\.isCreator \}\) === "choose" \? \(\s*<button[\s\S]{0,120}onClick=\{\(\) => setChoosing\(/.test(menu), true);
  strictEqual(/<Link\s+href=\{tableHref\(t\.code, t\.id\)\}[\s\S]{0,160}>\s*Join\s*</.test(menu), true);
  strictEqual(menu.includes("<JoinChoiceSheet table={choosing} onClose={() => setChoosing(null)} />"), true);
  strictEqual(menu.includes("href={watchHref(t.code, t.id)}"), true);
  strictEqual(/key=\{`watch-\$\{t\.code\}`\}[\s\S]{0,1200}\{watchRowState\(t\.gameLive \?\? true\)\}[\s\S]{0,400}>\s*Watch\s*</.test(menu), true);
  // Every row's button is the same small brass button, so rows keep one height.
  strictEqual((menu.match(/className="peg-btn peg-btn--brass peg-btn--small shrink-0"/g) ?? []).length, 3);
});
check("Spectators: the players are told -- the tag in the headers and the waiting screens", () => {
  const page = readFileSync("components/table/TableView.tsx", "utf8");
  // The headers no longer take muggins (2026-11-26: no Muggins tag line);
  // every one gets the watcher count.
  strictEqual(page.includes("muggins={isMuggins}"), false);
  strictEqual((page.match(/spectators=\{headerSpectatorCount\}/g) ?? []).length, 5);
  strictEqual(/<WaitingForPlayer[\s\S]{0,120}spectators=\{allowsSpectators\}/.test(page), true);
  strictEqual(/<WaitingRoom[\s\S]{0,80}spectators=\{allowsSpectators\}/.test(page), true);
  // The in-game header never gets a line of its own for it: the eye beside
  // the code on EVERY table, a Muggins one too (2026-11-26: the Muggins tag
  // line and the eye's pill are gone) -- only while someone is watching
  // (SpectatorsEye renders nothing at 0).
  for (const f of ["components/table/TableShell.tsx", "components/table/SquareTable.tsx"]) {
    const src = readFileSync(f, "utf8");
    strictEqual((src.match(/<SpectatorsEye count=\{spectators\} onOpen=\{onSpectators\} \/>/g) ?? []).length, 1, f);
    strictEqual(/!muggins|\bpill\b|MugginsTag|sq-muggins-tag/.test(src.replace(/\/\/[^\n]*/g, "")), false, `${f}: no Muggins line, no pill`);
    strictEqual((src.match(/\{watching && <WatchingRow \/>\}/g) ?? []).length, 1, f);
  }
});
check("Header: 'Hand N' sits under the table code, the spectators eye stays on the top row beside it", () => {
  for (const f of ["components/table/TableShell.tsx", "components/table/SquareTable.tsx"]) {
    const src = readFileSync(f, "utf8");
    strictEqual(src.includes('<h1 className="flex min-w-0 flex-col justify-center font-semibold" data-header="title">'), true, f);
    const start = src.indexOf('data-header="title"');
    const h1 = src.slice(start, src.indexOf("</h1>", start));
    // A column: the code line (with the eye inside it), then the hand line.
    const code = h1.indexOf('data-header="code"');
    const eye = h1.indexOf("<SpectatorsEye count={spectators}");
    const hand = h1.indexOf('data-header="hand"');
    const codeEnd = h1.lastIndexOf("</span>", hand);
    strictEqual(code > 0 && eye > code && eye < codeEnd, true, `${f}: the eye on the code line`);
    strictEqual(hand > codeEnd, true, `${f}: the hand line under it`);
    strictEqual(/data-header="hand"\s*>\s*Hand \{handNo\}\s*<\/span>/.test(h1), true, `${f}: "Hand N", no separator`);
    strictEqual(src.includes("· Hand"), false, f);
    // Small and one line, inside the header's own height.
    const handClass = h1.slice(Math.max(0, hand - 200), hand);
    strictEqual(handClass.includes("text-[10px]"), true, `${f}: 10px`);
    strictEqual(handClass.includes("truncate"), true, `${f}: one line`);
  }
  strictEqual(readFileSync("components/table/TableShell.tsx", "utf8").includes('<header className="flex h-6 items-center justify-between gap-2 text-sm">{line}</header>'), true, "classic stays 24px");
  // Square: the hand line's width never counts toward the column, so the across player keeps its room.
  strictEqual(readFileSync("components/table/SquareTable.tsx", "utf8").includes('[contain:inline-size]"\n            data-header="hand"'), true);
  strictEqual(/\.sq-header \{[^}]*height: 28px;/.test(readFileSync("app/globals.css", "utf8")), true, "square stays 28px");
});
check("Watching with no game: a NULL game id is accepted, and the old refusal still waits", () => {
  // A quiet re-watch that lets the spectator in STAYS, with or without a game.
  deepStrictEqual(rewatchStep({ ok: { gameId: null } }), { kind: "continue" });
  deepStrictEqual(rewatchStep({ ok: { gameId: "g1" } }), { kind: "continue" });
  // The old SQL's refusal still means "between games, stay" (and "waiting" on first watch).
  deepStrictEqual(rewatchStep({ refused: "There is no game to watch at this table yet." }), { kind: "continue" });
  strictEqual(watchRefusal("There is no game to watch at this table yet.").kind, "waiting");
  deepStrictEqual(rewatchStep({ refused: "You were removed from watching this table." }), { kind: "home", text: REMOVED_TEXT });
  deepStrictEqual(rewatchStep({ refused: "This table has ended." }), { kind: "closed" });
  deepStrictEqual(rewatchStep({ refused: "Spectators full: this table already has 4 spectators." }), { kind: "screen", text: FULL_TEXT });
  // game_ended (the new SQL's waiting room answer) still means stay.
  deepStrictEqual(heartbeatStep("game_ended"), { kind: "continue" });
  // The data layer: only the table id is required; game_id may be null.
  const data = readFileSync("lib/spectatorData.ts", "utf8");
  strictEqual(data.includes("export type WatchTicket = { tableId: string; code: string; gameId: string | null };"), true);
  // No row = a wrong or unknown code since step 3 slice A (watch_table
  // returns no row instead of raising): "No table found" again.
  // ...and with the table's id (step 3 slice B), no row means that table is gone: closed.
  strictEqual(data.includes("if (!row?.table_id) return tableId ? { closed: true } : { refused: notFoundText(code) };"), true);
  strictEqual(data.includes("gameId: row.game_id ?? null"), true);
  strictEqual(data.includes("!row.game_id"), false);
  // Reveals: only ever a real game id.
  strictEqual(/export async function readSpectatorReveals\(gameId: string\)[^{]*\{\s*\/\/[^\n]*\n\s*if \(!gameId\) return null;/.test(data), true);
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  const viewCode = codeOnly(view);
  strictEqual((viewCode.match(/fetchRevealed\(/g) ?? []).length, 2, "two calls");
  for (const call of viewCode.match(/fetchRevealed\([^)]*\)/g) ?? []) strictEqual(/fetchRevealed\((row|existingGame)\.id\)/.test(call), true, call);
  // The page: let in -> the table view at once (no own waiting screen); the
  // re-watch goes through rewatchStep; the old "waiting" path stays as the fallback.
  const page = readFileSync("app/watch/[code]/page.tsx", "utf8");
  strictEqual(/if \("ok" in result\) \{\s*ticketRef\.current = result\.ok;\s*setState\(\{ kind: "watching", ticket: result\.ok \}\);/.test(page), true);
  strictEqual(page.includes("const outcome: RewatchOutcome = rewatchStep(again);"), true);
  strictEqual(page.includes('if (refusal.kind === "waiting") {'), true);
  strictEqual(page.includes("timer = window.setTimeout(attempt, WATCH_RETRY_MS);"), true);
});
check("Watching: the spectator's waiting room for 2, 3 and 4 players -- read-only, no 'you', who it waits on", () => {
  // 2 players: WaitingForPlayer.
  strictEqual(waitingForPlayerTitle({ seated: 1, capacity: 2, spectating: true }), "Waiting for a second player");
  strictEqual(waitingForPlayerTitle({ seated: 0, capacity: 2, spectating: true }), "Waiting for players");
  strictEqual(waitingForPlayerTitle({ seated: 0, capacity: 2, spectating: false }), "Waiting for a second player");
  strictEqual(waitingForPlayerTitle({ seated: 1, capacity: 2, spectating: false }), "Waiting for a second player");
  // 3 and 4 players (the counts, whoever is looking).
  strictEqual(waitingForPlayerTitle({ seated: 2, capacity: 3, spectating: true }), "Waiting for players (2 of 3)");
  strictEqual(waitingForPlayerTitle({ seated: 2, capacity: 4, spectating: false }), "Waiting for players (2 of 4)");
  const wfp = readFileSync("components/table/WaitingForPlayer.tsx", "utf8");
  strictEqual(wfp.includes(`{spectating ? "You're watching this table." : "Send them this table code:"}`), true);
  // 3 and 4 players: WaitingRoom -- never the host, never "(you)", who it waits on.
  strictEqual(spectatorWaitingLine({ full: true, hostName: "Elsa" }), "You're watching. Waiting for Elsa to start.");
  strictEqual(spectatorWaitingLine({ full: true, hostName: null }), "You're watching. Waiting for the host to start.");
  strictEqual(spectatorWaitingLine({ full: false, hostName: "Elsa" }), "You're watching. Waiting for players to sit down.");
  const room = readFileSync("components/table/WaitingRoom.tsx", "utf8");
  strictEqual(room.includes("const isHost = !spectating && hostId !== null && hostId === myId;"), true);
  strictEqual(/\{spectating \? \(\s*<p className="text-sm text-zinc-500">\{spectatorWaitingLine\(\{ full, hostName \}\)\}<\/p>\s*\) : isHost \? \(/.test(room), true);
  // Moves and Start exist only behind isHost.
  strictEqual(/const action = !isHost\s*\? undefined/.test(room), true);
  // The page passes spectating to both, myId = NOBODY_SEATED (no "(you)"), Start only for the host.
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(/<WaitingForPlayer[\s\S]{0,160}spectating=\{spectating\}/.test(view), true);
  strictEqual(/<WaitingRoom[\s\S]{0,120}spectating=\{spectating\}/.test(view), true);
  strictEqual(/<WaitingRoom[\s\S]{0,900}myId=\{meId\}/.test(view), true);
  strictEqual(/<WaitingRoom[\s\S]{0,1400}canStart=\{isHost && members\.length === capacity\}/.test(view), true);
  // A full 2-player table with no game yet: the result stage's spectator line.
  strictEqual(SPECTATOR_NO_GAME_TEXT, "You're watching. Waiting for the players to start.");
  strictEqual(/finishedGame\s*\? "Waiting for the next game\.\.\."\s*: \/\/[^\n]*\n\s*SPECTATOR_NO_GAME_TEXT\}/.test(view), true);
});

check("Spectator chat: the eye shows only while someone is watching, with the count", () => {
  strictEqual(spectatorEyeCount(null), 0);
  strictEqual(spectatorEyeCount(undefined), 0);
  strictEqual(spectatorEyeCount([]), 0);
  strictEqual(spectatorEyeCount([{}, {}]), 2);
  strictEqual(showSpectatorsEye(0), false);
  strictEqual(showSpectatorsEye(1), true);
  strictEqual(showSpectatorsEye(4), true);
  // The component renders nothing at 0, the count above it, and opens the list.
  const tag = readFileSync("components/SpectatorsTag.tsx", "utf8");
  strictEqual(tag.includes("if (count <= 0) return null;"), true);
  strictEqual(tag.includes('aria-haspopup="dialog"'), true);
  strictEqual(tag.includes('<span aria-hidden="true">{count}</span>'), true, "the count only, never the word");
  // No pill variant; "watching" stays only in the tooltip and the screen-reader label.
  strictEqual(/\bpill\b/.test(tag.slice(tag.indexOf("export function SpectatorsEye"), tag.indexOf("export function WatchingRow"))), false);
  // Its tap target is 44x44 around the small eye.
  const css = readFileSync("app/globals.css", "utf8");
  strictEqual(/\.spectators-eye::after \{[^}]*width: 44px;[^}]*height: 44px;/.test(css), true);
  // The page: the count from get_table_spectators, at a table that allows spectators, for players and spectators alike.
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("const headerSpectatorCount = allowsSpectators ? spectatorEyeCount(spectatorList) : 0;"), true);
  strictEqual((view.match(/spectators=\{headerSpectatorCount\}\n\s*onSpectators=\{openSpectators\}\n\s*watching=\{spectating\}/g) ?? []).length, 5);
  // Refreshed on the safety poll, on every full refresh (game-state changes) and after a Remove.
  strictEqual(/async function pollOnce\(\) \{[\s\S]{0,2600}await loadSpectators\(tableId\);/.test(view), true);
  strictEqual(/const refreshTableState = useCallback\([\s\S]{0,500}void loadSpectators\(tableId\);/.test(view), true);
  strictEqual(view.includes("if (!list || ticket < spectatorsAppliedSeqRef.current) return;"), true, "a failed read keeps the list (and an older read never overwrites a newer one: moderation M5a)");
  // Muggins: the same eye beside the code (no pill, no tag line).
  strictEqual(/\.spectators-eye--pill|\.sq-muggins-tag/.test(css), false);
});
check("Spectator chat: the roster merges players and spectators; a spectator's own echo has their name", () => {
  const players = [
    { user_id: "p1", nickname: "Walt", avatar_url: null },
    { user_id: "p2", nickname: "Elsa", avatar_url: "e.png" },
  ];
  const spectators = [
    { userId: "s1", joinedAt: "t1", nickname: "Kim", avatarUrl: "k.png" },
    { userId: "p2", joinedAt: "t2", nickname: "Elsa", avatarUrl: "e.png" }, // seated and listed: a player
  ];
  deepStrictEqual(mergeChatRoster(players, spectators), [
    { user_id: "p1", nickname: "Walt", avatar_url: null, spectator: false },
    { user_id: "p2", nickname: "Elsa", avatar_url: "e.png", spectator: false },
    { user_id: "s1", nickname: "Kim", avatar_url: "k.png", spectator: true },
  ]);
  deepStrictEqual(mergeChatRoster(players, null).map((r) => r.user_id), ["p1", "p2"]);
  // The spectator's own card: their name and their eye, from the roster.
  const me = mergeChatRoster(players, spectators).find((r) => r.user_id === "s1");
  const card = ownChatCard({ result: "ok", text: "nice peg", me, myUserId: "s1", now: 10, id: "own-s" });
  strictEqual(card?.name, "Kim");
  strictEqual(card?.spectator, true);
  // The page builds the roster this way and passes it to the chat hook.
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("mergeChatRoster(members, allowsSpectators ? spectatorList : null)"), true);
  strictEqual(view.includes("roster: chatRoster,"), true);
  // A spectator chats while listed (a current spectator), a player while seated.
  strictEqual(/\(spectating\s*\?\s*!!spectatorList\?\.some\(\(s\) => s\.userId === session\.user\.id\)\s*:\s*members\.some\(\(m\) => m\.user_id === session\.user\.id\)\)/.test(view), true);
  // Messages carry the roster's spectator flag; the card draws an eye for it.
  const hook = readFileSync("components/table/useTableChat.ts", "utf8");
  strictEqual(hook.includes("spectator: member.spectator === true,"), true);
  const ui = readFileSync("components/table/TableChat.tsx", "utf8");
  strictEqual(ui.includes("{m.spectator &&"), true);
  strictEqual(ui.includes("<SpectatorEyeGlyph size={12} />"), true);
});
check("Spectator chat: a spectator who leaves the list is dropped; the host's client drops them at once after Remove", () => {
  const list = [
    { userId: "s1", joinedAt: "t1", nickname: "Kim", avatarUrl: null },
    { userId: "s2", joinedAt: "t2", nickname: "Lou", avatarUrl: null },
  ];
  deepStrictEqual(withoutSpectator(list, "s1")?.map((s) => s.userId), ["s2"]);
  strictEqual(withoutSpectator(null, "s1"), null);
  // Out of the list = out of the roster: their channel is left and anything still arriving is dropped.
  const roster = mergeChatRoster([], withoutSpectator(list, "s1"));
  strictEqual(roster.some((r) => r.user_id === "s1"), false);
  const hook = readFileSync("components/table/useTableChat.ts", "utf8");
  strictEqual(/const member = rosterRef\.current\.find\(\(m\) => m\.user_id === senderId\);\s*\/\/[^\n]*\n\s*if \(!member\) return;/.test(hook), true);
  strictEqual(hook.includes("const others = on ? roster.map((m) => m.user_id).filter((id) => id !== myUserId).sort() : [];"), true);
  // The host's Kick (moderation M3, the old Remove): the list loses them on success, before the next read.
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(/return;\s*\}\s*setSpectatorList\(\(list\) => withoutSpectator\(list, ask\.userId\)\);/.test(view), true);
});
check("Spectator chat: Kick (the old Remove) is the host's only -- the list's rows and the chat card's eye", () => {
  strictEqual(canRemoveSpectator({ isHost: true, spectating: false, targetIsSpectator: true }), true);
  strictEqual(canRemoveSpectator({ isHost: false, spectating: false, targetIsSpectator: true }), false, "a player who isn't the host");
  strictEqual(canRemoveSpectator({ isHost: true, spectating: true, targetIsSpectator: true }), false, "never a spectator");
  strictEqual(canRemoveSpectator({ isHost: true, spectating: false, targetIsSpectator: false }), false, "never a player");
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("const hostMayRemove = canRemoveSpectator({ isHost, spectating, targetIsSpectator: true });"), true);
  strictEqual(view.includes("canKick={hostMayRemove}"), true);
  strictEqual(/onRemoveSpectator=\{\s*hostMayRemove\s*\?/.test(view), true);
  // Moderation M3: kick_player through lib/kicks.ts, the host only (never a spectator).
  strictEqual(view.includes("const result = await writeKick(table.id, ask.userId);"), true);
  strictEqual(view.includes("if (!ask || !table || !popupIsHost || kickBusyRef.current) return;"), true);
  // The card: the eye is a button only when the host's handler is passed; a 44px layer; the confirm is a native dialog.
  const ui = readFileSync("components/table/TableChat.tsx", "utf8");
  strictEqual(ui.includes("onRemove={m.spectator && onRemoveSpectator ? () => onRemoveSpectator(m.senderId, m.name) : undefined}"), true);
  strictEqual(/\.chat-eye-tap::after \{[^}]*width: 44px;[^}]*height: 44px;/.test(readFileSync("app/globals.css", "utf8")), true);
  const list = readFileSync("components/table/SpectatorsList.tsx", "utf8");
  strictEqual(list.includes("d.showModal()"), true, "the top layer: above the chat portal (55), counts (62), composer (70)");
  strictEqual(list.includes("{canKick && ("), true);
  strictEqual(/\.person-btn \{[^}]*min-height: 44px;[^}]*border-radius: 12px;/.test(readFileSync("app/globals.css", "utf8")), true);
  // The removed spectator goes home with the message (the heartbeat), the only forced exit home.
  deepStrictEqual(heartbeatStep("removed"), { kind: "home", text: REMOVED_TEXT });
  strictEqual(REMOVED_TEXT, "The host removed you from this table.");
});
check("Spectator chat: a spectator hears the table from Seat 1, no deal sound, nothing twice", () => {
  // Whose win or loss: a player's own seat; a spectator's Seat 1.
  strictEqual(soundSeatId({ spectating: false, viewerId: "me", myId: "me" }), "me");
  strictEqual(soundSeatId({ spectating: true, viewerId: "seat1", myId: null }), "seat1");
  strictEqual(soundSeatId({ spectating: true, viewerId: NOBODY_SEATED, myId: null }), null);
  strictEqual(gameOutcome({ players: ["seat1", "b"], winnerId: "seat1", myId: soundSeatId({ spectating: true, viewerId: "seat1", myId: null }), teams: false }), "win");
  strictEqual(gameOutcome({ players: ["seat1", "b"], winnerId: "b", myId: soundSeatId({ spectating: true, viewerId: "seat1", myId: null }), teams: false }), "loss");
  // The deal (realtime stopgap, option B): no deal sound for a spectator --
  // only the deal animation plays it, and a spectator has none. Gone from
  // the rules and the view; the player's animation still starts it.
  strictEqual(readFileSync("lib/spectators.ts", "utf8").includes("spectatorDealSound"), false);
  const dealView = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(dealView.includes("spectatorDealSound"), false);
  strictEqual(dealView.includes("spectatorDealKey"), false);
  strictEqual(dealView.includes("onStart={() => tableSound.dealStart(dealKey(dealHandKey))}"), true);
  strictEqual((dealView.match(/tableSound\.dealStart\(/g) ?? []).length, 1, "only the deal animation starts the deal sound");
  // The discard tick is unchanged: another player's discard plays from the
  // games row with the toss's landing delay (0 with no toss, as a spectator).
  strictEqual(dealView.includes("tableSound.setTossLanding(cardAnimationsOn && !dealInFlight ? TOSS_CARD_MS : 0);"), true);
  // The watch page no longer claims spectators hear nothing.
  const watchPage = readFileSync("app/watch/[code]/page.tsx", "utf8");
  strictEqual(watchPage.includes("get_spectator_reveals, no sounds."), false);
  strictEqual(watchPage.includes("but no deal sound"), true);
  // No silent mode any more: the hook plays for everyone; keys still play once.
  const hook = readFileSync("components/table/useTableSounds.ts", "utf8");
  strictEqual(hook.includes("silent"), false);
  strictEqual(/const claim = \(key: string\) => \{\s*if \(handledRef\.current\.has\(key\)\) return false;\s*handledRef\.current\.add\(key\);\s*return true;/.test(hook), true);
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("silent: spectating"), false);
  strictEqual(view.includes("if (spectatorDealKey && phase === \"discard\") tableSound.dealStart(dealKey(spectatorDealKey));"), false);
  // The game-end sound asks whose seat: Seat 1 (the game's first player) for a spectator.
  strictEqual(/const myId = soundSeatId\(\{\s*spectating,\s*viewerId: updatedGame\.players\?\.\[0\] \?\? NOBODY_SEATED,\s*myId: myHandRef\.current\?\.userId \?\? null,\s*\}\);/.test(view), true);
  // A player's own tap still plays their cut and discard once: the games row's key stays quiet after the tap.
  strictEqual(view.includes("tableSound.card(cutKey(activeGame.id, round, session.user.id));"), true);
  strictEqual(view.includes("tableSound.card(discardKey(updatedGame.id, updatedGame.hand_no, id), cards, landIn);"), true);
});

// SPECTATOR SEAT, PART B: the watch page (app/watch/[code]) and the shared
// table view's spectating mode (components/table/TableView.tsx).
check("Watching: Seat 1 at the bottom, the others placed as Seat 1 sees them (2, 3, 4 Teams and Solo)", () => {
  const roster = (ids: string[]) => ids.map((id, i) => ({ user_id: id, seat: i + 1 }));
  // 2 players: Seat 1 at the bottom, Seat 2 across.
  let v = spectatorViewerId({ gamePlayers: ["s1", "s2"], roster: roster(["s1", "s2"]) });
  strictEqual(v, "s1");
  deepStrictEqual(seatsOnScreen(["s1", "s2"], v), { bottom: "s1", left: null, top: "s2", right: null });
  // 3 players: the next clockwise on the left, the last on the right.
  v = spectatorViewerId({ gamePlayers: ["s1", "s2", "s3"], roster: [] });
  deepStrictEqual(seatsOnScreen(["s1", "s2", "s3"], v), { bottom: "s1", left: "s2", top: null, right: "s3" });
  // 4 players (Teams or Solo: the same seats): Seat 3 across -- Seat 1's partner in Teams.
  v = spectatorViewerId({ gamePlayers: ["s1", "s2", "s3", "s4"], roster: [] });
  deepStrictEqual(seatsOnScreen(["s1", "s2", "s3", "s4"], v), { bottom: "s1", left: "s2", top: "s3", right: "s4" });
  strictEqual(teamOfPosition(["s1", "s2", "s3", "s4"], "s1"), teamOfPosition(["s1", "s2", "s3", "s4"], "s3"));
  // The game's own order wins over the roster's; before a game, the roster's seat 1.
  strictEqual(spectatorViewerId({ gamePlayers: ["b", "a"], roster: roster(["a", "b"]) }), "b");
  strictEqual(spectatorViewerId({ gamePlayers: null, roster: [{ user_id: "x", seat: 2 }, { user_id: "y", seat: 1 }] }), "y");
  strictEqual(spectatorViewerId({ gamePlayers: [], roster: [] }), NOBODY_SEATED);
  // "You" is nobody: the stand-in matches no player.
  for (const ids of [["s1", "s2"], ["s1", "s2", "s3", "s4"]]) strictEqual(ids.includes(NOBODY_SEATED), false);
});
check("Watching: the counting views never offer a spectator a count, and never say 'you'", () => {
  for (const [step, phase] of [[0, "counting"], [1, "counting"], [2, "counting"], [2, "done"]] as const) {
    for (const dealer of ["s1", "s2"]) {
      const v = countingView({
        myId: "s1", dealerId: dealer, oppName: "Bea", phase, step, myHand: [], oppCards: ["AS", "2S", "3S", "4S"],
        cribCards: null, starter: "5D", viewerName: "Ann",
      });
      strictEqual(v.myTurn, false, `2p ${dealer} ${step}`);
      strictEqual(v.canConfirm, false);
      strictEqual(v.hint, "");
      deepStrictEqual(v.myRow, { kind: "faceDown", count: 4 }, "Seat 1's hand face-down until it is turned over");
      strictEqual(/\byour?\b/i.test([v.headline, v.waitingOn ?? "", ...v.recap].join(" ")), false, v.headline);
    }
  }
  // Once turned over (the page passes the cards), the bottom row shows them.
  const shown = countingView({ myId: "s1", dealerId: "s2", oppName: "Bea", phase: "counting", step: 1, myHand: ["AS", "2S", "3S", "4S"], oppCards: null, cribCards: null, starter: "5D", viewerName: "Ann" });
  deepStrictEqual(shown.myRow, { kind: "full", cards: ["AS", "2S", "3S", "4S"] });
  strictEqual(shown.waitingOn, "Bea is counting");
  const players = ["s1", "s2", "s3", "s4"];
  for (let step = 0; step <= 4; step++) {
    const n = countingViewN({
      players, myId: "s1", dealerId: "s4", names: { s1: "Ann", s2: "Bea", s3: "Cal", s4: "Dee" }, phase: "counting", step,
      myHand: [], hands: {}, cribCards: null, starter: "5D", viewerName: "Ann",
    });
    strictEqual(n.myTurn || n.canConfirm, false, `4p step ${step}`);
    strictEqual(/\byour?\b/i.test([n.headline, n.middleLabel ?? "", n.waitingOn ?? "", ...n.recap.map((r) => r.text)].join(" ")), false);
    deepStrictEqual(n.myRow, { kind: "faceDown", count: 4 });
  }
  // Seat 1 counting (step 0, dealer on its right): "Ann is counting", never a button.
  const annCounts = countingViewN({ players, myId: "s1", dealerId: "s4", names: { s1: "Ann" }, phase: "counting", step: 0, myHand: [], hands: {}, cribCards: null, starter: "5D", viewerName: "Ann" });
  strictEqual(annCounts.waitingOn, "Ann is counting");
  strictEqual(annCounts.headline, "Counting: Ann's hand");
  // A player's view is exactly as before (no viewerName).
  strictEqual(countingViewN({ players, myId: "s1", dealerId: "s4", names: {}, phase: "counting", step: 0, myHand: ["AS"], hands: {}, cribCards: null, starter: "5D" }).canConfirm, true);
});
// Source with its comments removed, so a scan reads code only (these files
// talk about table_members and the hand reads they never make).
function codeOnly(src: string): string {
  return src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\{\/\*[\s\S]*?\*\/\}/g, "").replace(/(^|[^:])\/\/[^\n]*/g, "$1");
}
check("Watching: every action flag of the shared table view is off when spectating", () => {
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  // The flags and controls, each defined with !spectating (or a spectator branch first).
  for (const needle of [
    "const isHost = !spectating && hostId === viewerId;",
    "const isMyTurn = !spectating && isPlaying && activeGame?.current_player === viewerId;",
    "const canDiscard =\n    !spectating && // an action flag",
    "const dealInFlight =\n    !spectating &&",
    "const cardAnimationsOn = !spectating &&",
    "const computerTable = !spectating &&",
    "!spectating && finishedGame && finishedGame.winner_id === myUserId",
    "const mugginsWinBar =\n    !spectating && isMuggins",
    "{!spectating && myHand.length > 0 && !sortLocked && (",
    "const countActions = view\n    ? isDone && spectating ? (",
    "const discardPrompt = spectating ? (",
    "myUserId={viewerId}\n          spectating={spectating}",
  ]) {
    strictEqual(view.includes(needle), true, needle);
  }
  // Every action handler returns at once for a spectator.
  const handlers = [...view.matchAll(/\n  (?:async )?function (handle\w+|run\w+Action)\(/g)].map((m) => m[1]);
  deepStrictEqual([...handlers].sort(), [
    "handleAcknowledgeCut", "handleConfirmCount", "handleDiscard", "handleDrawCutCard", "handleLeave", "handleNextHand",
    "handlePlayCard", "handleSeatMove", "handleStartNewGame", "runCountAction", "runWinAction",
  ]);
  for (const name of handlers) {
    // The handler's signature line ends with "{", and its first statement is the guard.
    strictEqual(new RegExp(`function ${name}\\([^\\n]*\\{\\n    if \\(spectating\\) return`).test(view), true, name);
  }
  // ONE HEADER (spectator chat): the players' own -- chat, speaker, the "⋯"
  // menu and Leave -- for a spectator too; a spectator's Leave stops watching
  // (no "End game & leave" confirm), and "Watching" is a row under it.
  strictEqual(view.includes("const headerRight = spectating ? ("), false, "no spectator-only header");
  const start = view.indexOf("const headerRight = (");
  const header = view.slice(start, view.indexOf("const header = (", start));
  for (const present of ["<ChatButton", "<SoundToggle />", "<CountsToggle", "<SpectatorsList"]) strictEqual(header.includes(present), true, present);
  strictEqual(/spectating \? spectateRef\.current\?\.onStop\(\) : activeGame \? setLeaveConfirming\(true\) : handleLeave\(\)/.test(header), true);
  strictEqual(header.includes("Stop watching"), false);
  // "You" is nobody: identity wording uses meId, placement viewerId.
  strictEqual(view.includes("const meId = spectating ? NOBODY_SEATED : session.user.id;"), true);
  // The cut: read-only for a spectator.
  const cut = readFileSync("components/CutForDealView.tsx", "utf8");
  strictEqual(cut.includes("const interactive = !spectating && !iHaveDrawn && !drawPending;"), true);
  strictEqual(cut.includes("if (spectating || iHaveDrawn || drawPending) return;"), true);
  for (const btn of ["{!spectating && isTie && (", "{!spectating && isDecisive && ("]) strictEqual(cut.includes(btn), true, btn);
  // Sounds: a spectator hears the table now (from Seat 1; see the spectator chat checks).
  strictEqual(view.includes("silent: spectating"), false);
});
check("Watching: the heartbeat's answers (part C: stay through game over, closed screen, removal goes home)", () => {
  deepStrictEqual(heartbeatStep("ok"), { kind: "continue" });
  deepStrictEqual(heartbeatStep(null), { kind: "continue" }, "a failed call: try again on the next poll");
  // game_ended: STAY on the table (game-over or waiting screen), keep heartbeating.
  deepStrictEqual(heartbeatStep("game_ended"), { kind: "continue" });
  // table_ended: the closed screen, no redirect.
  deepStrictEqual(heartbeatStep("table_ended"), { kind: "closed" });
  strictEqual(TABLE_CLOSED_TEXT, "This table has closed.");
  // removed: home, with the message.
  deepStrictEqual(heartbeatStep("removed"), { kind: "home", text: REMOVED_TEXT });
  strictEqual(REMOVED_TEXT, "The host removed you from this table.");
  deepStrictEqual(heartbeatStep("not_watching"), { kind: "rewatch" });
  // A refused quiet re-watch: "no game yet" stays (between games); removed goes
  // home; ended shows the closed screen; anything else its screen -- no redirect.
  deepStrictEqual(rewatchOutcome("There is no game to watch at this table yet."), { kind: "continue" });
  deepStrictEqual(rewatchOutcome("You were removed from watching this table."), { kind: "home", text: REMOVED_TEXT });
  deepStrictEqual(rewatchOutcome("This table has ended."), { kind: "closed" });
  deepStrictEqual(rewatchOutcome("Spectators full: this table already has 4 spectators."), { kind: "screen", text: FULL_TEXT });
  deepStrictEqual(rewatchOutcome("This table does not allow spectators."), { kind: "screen", text: NOT_ALLOWED_TEXT });
  // The page: only a removal redirects; the closed screen has Back home and
  // stops the heartbeat (no table view, and heartbeat() returns once left).
  const page = readFileSync("app/watch/[code]/page.tsx", "utf8");
  strictEqual((page.match(/router\.replace\("\/"\)/g) ?? []).length, 1, "one redirect home");
  strictEqual(/if \(outcome\.kind === "home"\) \{[\s\S]{0,120}router\.replace\("\/"\);/.test(page), true);
  strictEqual(page.includes('onTableEnded: () => leave({ kind: "closed" }),'), true);
  strictEqual(page.includes("if (!ticket || beatingRef.current || exitedRef.current || stopRequestedRef.current) return;"), true);
  strictEqual(/state\.kind === "closed"[\s\S]{0,300}\{TABLE_CLOSED_TEXT\}[\s\S]{0,300}Back home/.test(page), true);
  // The table view no longer sends a spectator away when the game ends.
  const tv = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(tv.includes("onGameEnded"), false);
  // Under the 90 s cutoff: the safety poll's longest wait, backed off and
  // jittered up (60 s + 25%), and the connected pace jittered up.
  strictEqual(nextPollDelayMs({ connected: false, disconnectedPolls: 99, random: 0.999999 }) < 90_000, true);
  strictEqual(nextPollDelayMs({ connected: true, disconnectedPolls: 0, random: 0.999999 }) < 90_000, true);
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  // Step 3 slice D: the heartbeat is AWAITED before the reads (a private
  // table is readable by a current spectator only), on the poll and on the
  // catch-up; the watch page hands back the beat in flight.
  strictEqual(/async function pollOnce\(\) \{[\s\S]{0,400}await spectateRef\.current\?\.heartbeat\(\);/.test(view), true, "on the safety poll, awaited");
  strictEqual(/const catchUp = \(\) => \{[\s\S]{0,400}const beat = spectateRef\.current\?\.heartbeat\(\);[\s\S]{0,120}void Promise\.resolve\(beat\)\.then\(\(\) => refreshTableState\(table\.id\)\);/.test(view), true, "visible / online: refresh after the beat");
  strictEqual(view.includes("heartbeat: () => Promise<void>;"), true);
  strictEqual(page.includes("heartbeat: () => heartbeat(),"), true);
  strictEqual(page.includes("if (beatingRef.current) return beatInFlightRef.current ?? undefined;"), true);
});
check("Watching: watch_table's refusals become screens; 'no game yet' waits and asks again", () => {
  strictEqual(watchRefusal("There is no game to watch at this table yet.").kind, "waiting");
  strictEqual(watchRefusal("There is no game to watch at this table yet.").text, "Waiting for the next game...");
  strictEqual(WATCH_RETRY_MS, 5_000);
  strictEqual(watchRefusal("You are seated at this table.").kind, "seated");
  deepStrictEqual(watchRefusal("Spectators full: this table already has 4 spectators."), { kind: "full", text: FULL_TEXT });
  deepStrictEqual(watchRefusal("You were removed from watching this table."), { kind: "removed", text: REMOVED_TEXT });
  deepStrictEqual(watchRefusal("This table has ended."), { kind: "ended", text: "This table has ended." });
  deepStrictEqual(watchRefusal("This table does not allow spectators."), { kind: "not_allowed", text: NOT_ALLOWED_TEXT });
  deepStrictEqual(watchRefusal("Computer tables cannot be watched."), { kind: "not_allowed", text: NOT_ALLOWED_TEXT });
  strictEqual(watchRefusal("You must be logged in to watch a table.").kind, "login");
  strictEqual(watchRefusal("No table found with code 1234.").kind, "not_found");
  // Never raw server text: anything unrecognised is the generic message.
  deepStrictEqual(watchRefusal("something new"), { kind: "other", text: GENERIC_ERROR_TEXT });
  // One table at a time (lib/oneTable.ts texts, made plain by callWatchTable).
  deepStrictEqual(watchRefusal(alreadyAtTableText("4321")), { kind: "already_at_table", text: alreadyAtTableText("4321"), tableCode: "4321" });
  strictEqual(watchRefusal(lockedOutText(7)).kind, "locked_out");
  strictEqual(watchRefusal(RATE_LIMITED_TEXT).kind, "rate_limited");
  strictEqual(watchRefusal("You can start watching at most 30 tables an hour. Please try again later.").kind, "rate_limited");
  deepStrictEqual(watchRefusal(notFoundText("0042")), { kind: "not_found", text: "No table found with code 0042." });
  // A quiet re-watch refused for another table carries the code to its screen.
  deepStrictEqual(rewatchStep({ refused: alreadyAtTableText("4321") }), { kind: "screen", text: alreadyAtTableText("4321"), tableCode: "4321" });
  // The page: waiting re-asks on a timer; seated goes to the player's own seat.
  const page = readFileSync("app/watch/[code]/page.tsx", "utf8");
  strictEqual(page.includes("timer = window.setTimeout(attempt, WATCH_RETRY_MS);"), true);
  strictEqual(page.includes("router.replace(tableHref(code, held));"), true);
  strictEqual(page.includes("Waiting for the next game..."), true);
});
check("Watching: the RPC allowlist -- the spectator route and its own modules call only the four spectator RPCs and write nothing", () => {
  // get_table_spectators (spectator chat): the eye, the list and the chat
  // roster -- read by players and spectators alike. remove_spectator is the
  // host's, through the shared view's playerRpc: never in these modules.
  // join_table_by_code: ONLY as the watch confirm's preview (p_preview: true,
  // step 3 slice B) -- it seats nobody and changes nothing.
  const ALLOWED = new Set(["watch_table", "stop_watching", "spectator_heartbeat", "get_spectator_reveals", "get_table_spectators", "join_table_by_code"]);
  // The route and every module only it (or the spectating mode) uses.
  const spectatorOnly = ["app/watch/[code]/page.tsx", "lib/spectatorData.ts", "lib/spectators.ts", "lib/lobbyNotice.ts"];
  const WRITE = /\.(insert|upsert|update|delete)\(/;
  let rpcs = 0;
  for (const f of spectatorOnly) {
    const src = codeOnly(readFileSync(f, "utf8"));
    for (const m of src.matchAll(/\.rpc\(\s*([^,)]+)/g)) {
      rpcs++;
      const name = m[1].trim().replace(/^["'`]|["'`]$/g, "");
      strictEqual(ALLOWED.has(name), true, `${f}: .rpc(${m[1]})`);
    }
    strictEqual(WRITE.test(src), false, `${f} writes a table`);
    strictEqual(/takeSeat|table_members/.test(src), false, f);
    strictEqual(src.includes("remove_spectator"), false, `${f}: a spectator never removes`);
  }
  strictEqual(rpcs, 6, "exactly the five spectator calls and the preview");
  {
    const data = codeOnly(readFileSync("lib/spectatorData.ts", "utf8"));
    strictEqual((data.match(/\.rpc\(\s*"join_table_by_code"/g) ?? []).length, 1);
    strictEqual(data.includes('supabase.rpc("join_table_by_code", { p_code: code, p_preview: true })'), true, "only ever a preview");
  }
  strictEqual(codeOnly(readFileSync("lib/spectatorData.ts", "utf8")).includes('supabase.rpc("get_table_spectators", { p_table_id: tableId })'), true);
  // remove_spectator: no longer called by the app at all (moderation M3:
  // the host's Kick is kick_player, through lib/kicks.ts).
  const viewSrc = codeOnly(readFileSync("components/table/TableView.tsx", "utf8"));
  strictEqual((viewSrc.match(/remove_spectator/g) ?? []).length, 0);
  // The shared view: one supabase.rpc, inside playerRpc, refused for a spectator;
  // NO direct write at all since step 3 slice A: the seat is
  // join_table_by_code through playerRpc, in takeSeat, which a spectator
  // never reaches.
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual((view.match(/supabase\.rpc\(/g) ?? []).length, 1);
  strictEqual(/const playerRpc = useCallback\(\s*\([^)]*\)[^{]*\{\s*if \(spectating\) \{/.test(view), true);
  strictEqual((view.match(/\.(insert|update|delete)\(/g) ?? []).length, 0);
  strictEqual((view.match(/\.upsert\(/g) ?? []).length, 0);
  strictEqual(view.includes('const { data, error: joinError } = await playerRpc("join_table_by_code", { p_code: row.code, p_table_id: row.id });'), true);
  strictEqual(/const takeSeat = useCallback\(\s*async \([^\n]*=> \{\s*\/\/[^\n]*\n\s*if \(spectating\) return;/.test(view), true);
  // A spectator's setup never reaches the seat code.
  strictEqual(/if \(spectating\) \{\s*setTable\(tableRow\);\s*await refreshTableState\(tableRow\.id\);\s*return;\s*\}/.test(view), true);
});
check("Private tables (step 3 slice D): a non-member reads a private table through the by-id preview, never an open read", () => {
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  // The by-id setup: the direct read first (public tables, members, former
  // players, admins, current spectators), then -- for a PLAYER only -- the
  // definer preview by id when that read finds no row.
  strictEqual(/if \(!readRow && !spectating\) \{\s*const \{ data: previewData, error: previewError \} = await playerRpc\("join_table_by_code", \{\s*p_code: code,\s*p_table_id: heldId,\s*p_preview: true,\s*\}\);/.test(view), true, "setup: preview by id, players only");
  strictEqual(view.includes("tableRow = tableRowFromPreview(answer.preview);"), true);
  // The seats and the live game come from the preview, not from reads a
  // non-member can no longer make.
  strictEqual(view.includes("const seatedCount = previewed ? previewed.seatedCount : seated.length;"), true);
  strictEqual(view.includes("const isMember = previewed ? previewSeated : !seatsError && seated.includes(session!.user.id);"), true);
  strictEqual(view.includes("? { data: previewed.gameLive ? { id: \"live\" } : null, error: null }"), true);
  // The stale-tab check: no row -> the preview by id; not_found -> the ended screen.
  strictEqual(/checkTableEndedRef\.current = \(tableId: string\) => \{\s*if \(spectating \|\| leavingRef\.current\) return;[\s\S]{0,600}(?:await )?playerRpc\("join_table_by_code", \{\s*p_code: code,\s*p_table_id: tableId,\s*p_preview: true,\s*\}\);[\s\S]{0,900}if \(previewFromRow\(previewData\)\?\.outcome !== "not_found"\) return;\s*setClosedHumanTable\(true\);\s*setError\(TABLE_ENDED_TEXT\);/.test(view), true, "stale tab: preview by id");
  // Every preview call in the view is a preview (seats nobody) or the seat in takeSeat.
  const calls = [...view.matchAll(/playerRpc\("join_table_by_code", \{([^}]*)\}/g)].map((m) => m[1]);
  strictEqual(calls.length, 5, "bare-code preview, by-id preview, stale-tab preview, the Block List entry check (moderation M1), takeSeat");
  strictEqual(calls.filter((c) => c.includes("p_preview: true")).length, 4);
  // playerRpc is declared before the stale-tab effect that uses it.
  strictEqual(view.indexOf("const playerRpc = useCallback(") < view.indexOf("const checkTableEndedRef = useRef"), true);
});
check("Watching: nothing in the spectator path reads its own hand; hidden cards only via get_spectator_reveals", () => {
  for (const f of ["app/watch/[code]/page.tsx", "lib/spectatorData.ts", "lib/spectators.ts", "lib/lobbyNotice.ts"]) {
    const src = codeOnly(readFileSync(f, "utf8"));
    strictEqual(/fetchMyHand|readOwnHand|game_hands|game_cribs|game_decks/.test(src), false, f);
  }
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  // fetchMyHand is called in exactly one place: readOwnHand, which returns first for a spectator.
  strictEqual((view.match(/fetchMyHand\(/g) ?? []).length, 1);
  strictEqual(/const readOwnHand = useCallback\(\s*async \(gameId: string\) => \{\s*if \(spectating\) return;\s*await fetchMyHand\(gameId\);/.test(view), true);
  // Revealed hands and the crib: the spectator branch reads get_spectator_reveals only.
  strictEqual(/const fetchRevealed = useCallback\(async \(gameId: string\) => \{[\s\S]{0,400}if \(spectating\) \{\s*const shown = await readSpectatorReveals\(gameId\);/.test(view), true);
  strictEqual(readFileSync("lib/spectatorData.ts", "utf8").includes('supabase.rpc("get_spectator_reveals"'), true);
  // Seat 1's hand in play: card backs with the public count (opponentCardCount), never a face.
  strictEqual(view.includes("{Array.from({ length: opponentCardCount(viewerId) }, (_, i) => (\n        <FaceDownCard key={i} sizing={HAND_CARD} />"), true);
  // In the count: only once the counting sequence has turned it over.
  strictEqual(view.includes("const bottomHand: string[] = spectating ? (bottomTurnedOver ? (revealedHands[viewerId] ?? []) : []) : myHand;"), true);
});
check("Watching (part C): the hold's button says Show Hands for a spectator only", () => {
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes('const holdButtonLabel = spectating ? "Show Hands" : undefined;'), true);
  // Every hold button (PlayArea and CenterCount) gets the label.
  const holds = view.match(/handOver=\{onPegHold \? \{[^}]*\}/g) ?? [];
  strictEqual(holds.length, 3);
  for (const h of holds) strictEqual(h.includes("label: holdButtonLabel"), true, h);
  // Players keep "Count hands": the components fall back to it.
  for (const f of ["components/PlayArea.tsx", "components/table/CenterCount.tsx"]) {
    strictEqual(readFileSync(f, "utf8").includes('{handOver.label ?? "Count hands"}'), true, f);
  }
});
check("Watching (part C): a new game at the table is followed -- the game id change is picked up", () => {
  // The first game, a rematch, the next game after waiting: a different id.
  strictEqual(followGame("g1", "g2"), true);
  strictEqual(followGame(null, "g1"), true);
  // The same game, or no live game (game over, waiting): nothing to follow.
  strictEqual(followGame("g1", "g1"), false);
  strictEqual(followGame("g1", null), false);
  // The table view reports each live game; the page follows it (a quiet
  // watch_table, the ticket's game moved on); reveals read the game on screen.
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(/if \(spectating && liveGameId\) spectateRef\.current\?\.onLiveGame\(liveGameId\);/.test(view), true);
  strictEqual(view.includes("const shown = await readSpectatorReveals(gameId);"), true);
  const page = readFileSync("app/watch/[code]/page.tsx", "utf8");
  strictEqual(/!followGame\(ticket\.gameId, gameId\)\) return;\s*ticketRef\.current = \{ \.\.\.ticket, gameId \};\s*void rewatch\(\);/.test(page), true);
  // The heartbeat uses the table (not a stale game id) and the current ticket.
  strictEqual(page.includes("callSpectatorHeartbeat(ticket.tableId)"), true);
});
check("Watching (part C): the game-over and waiting screens are the players', read-only, in names", () => {
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  // No New Game for a spectator: who it waits on, by name.
  strictEqual(/\{spectating \? \(\s*\/\/ A SPECTATOR: who the next game waits on, never a button\./.test(view), true);
  strictEqual(view.includes("to start a new game…`"), true);
  strictEqual(view.includes('{rematchDealerId && <p className="text-xs text-zinc-500">Next dealer: {nameOf(rematchDealerId)}</p>}'), true);
  // The headline: never "You win!" for a spectator (meId is nobody).
  strictEqual(view.includes(": finishedGame.winner_id === meId"), true);
  strictEqual(winHeadline({ players: ["a", "b", "c"], winnerId: "b", myId: NOBODY_SEATED, nameOf: () => "Bea", teams: false }), "Bea wins!");
  strictEqual(
    winHeadline({ players: ["a", "b", "c", "d"], winnerId: "a", myId: NOBODY_SEATED, nameOf: (id) => id.toUpperCase(), teams: true }).includes("You"),
    false
  );
  // The waiting room: no host controls (isHost is off), no "(you)".
  strictEqual(view.includes("const isHost = !spectating && hostId === viewerId;"), true);
  strictEqual(view.includes("          myId={meId}"), true);
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
check("table sync: the safety poll is 30 s connected and backs off 12 s, 24 s, 60 s while not, each +/-25%", () => {
  strictEqual(SAFETY_POLL_MS, 12_000);
  strictEqual(SAFETY_POLL_CONNECTED_MS, 30_000);
  deepStrictEqual([...SAFETY_POLL_BACKOFF_MS], [12_000, 24_000, 60_000]);
  strictEqual(POLL_JITTER, 0.25);
  const at = (connected: boolean, disconnectedPolls: number, random: number) =>
    nextPollDelayMs({ connected, disconnectedPolls, random });
  // The middle of the jitter is the base.
  strictEqual(at(true, 0, 0.5), 30_000);
  strictEqual(at(false, 0, 0.5), 12_000);
  strictEqual(at(false, 1, 0.5), 24_000);
  strictEqual(at(false, 2, 0.5), 60_000);
  strictEqual(at(false, 7, 0.5), 60_000, "stays at 60 s");
  // Connected ignores the backoff step: reset to 30 s.
  strictEqual(at(true, 7, 0.5), 30_000);
  // The bounds: 75% .. 125% of the base, never outside.
  strictEqual(at(true, 0, 0), 22_500);
  strictEqual(at(true, 0, 0.999999) <= 37_500 && at(true, 0, 0.999999) > 37_000, true);
  strictEqual(at(false, 0, 0), 9_000);
  strictEqual(at(false, 2, 0), 45_000);
  strictEqual(at(false, 2, 0.999999) <= 75_000, true);
  strictEqual(at(false, -3, 2), 15_000, "out-of-range input is clamped");
  for (let i = 0; i < 2000; i++) {
    const r = Math.random();
    const connected = at(true, 0, r);
    const backedOff = at(false, i % 5, r);
    const base = SAFETY_POLL_BACKOFF_MS[Math.min(i % 5, 2)];
    strictEqual(connected >= 22_500 && connected <= 37_500, true);
    strictEqual(backedOff >= base * 0.75 && backedOff <= base * 1.25, true);
  }
  // The view: one timeout at a time with the chosen wait, no fixed interval;
  // a change of channel status restarts the chain (reset on connect).
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("pollIntervalMs"), false);
  strictEqual(view.includes("const delay = nextPollDelayMs({ connected: realtimeConnected, disconnectedPolls, random: Math.random() });"), true);
  strictEqual(view.includes("if (!realtimeConnected) disconnectedPolls++;"), true);
  const pollStart = view.indexOf("async function pollOnce()");
  strictEqual(view.slice(pollStart, pollStart + 4000).includes("setInterval"), false);
  strictEqual(view.includes("}, [table, refreshTableState, reconcileGame, loadMembers, fetchPlays, loadSpectators, realtimeConnected]);"), true);
});
check("realtime stopgap: game_plays is filtered by game, re-subscribed per game, caught up, never doubled", () => {
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  // No unfiltered game_plays listener anywhere: exactly one, with the filter.
  strictEqual((view.match(/table: "game_plays"/g) ?? []).length, 1);
  strictEqual(view.includes('{ event: "INSERT", schema: "public", table: "game_plays", filter: `game_id=eq.${gameId}` }'), true);
  strictEqual(view.includes('{ event: "INSERT", schema: "public", table: "game_plays" }'), false);
  // Its own channel, keyed to the game on screen: a new game (or none) is a
  // new subscription; the old one is removed.
  strictEqual(view.includes("const playsGameId = activeGame?.id ?? null;"), true);
  strictEqual(view.includes(".channel(`table-plays-${table.id}-${gameId}`)"), true);
  strictEqual(view.includes("if (!table || !playsGameId) return;"), true);
  const effectEnd = "}, [table, playsGameId, tableSound, showGo, catchUpPlays]);";
  strictEqual(view.includes(effectEnd), true);
  const playsEffect = view.slice(view.indexOf("const playsGameId = activeGame?.id ?? null;"), view.indexOf(effectEnd));
  strictEqual(playsEffect.includes("supabase.removeChannel(channel);"), true);
  // A catch-up read on every SUBSCRIBED (the first and each reconnect).
  strictEqual(/\.subscribe\(\(status\) => \{\s*if \(status === "SUBSCRIBED" && !cancelled\) void catchUpPlays\(gameId\);/.test(playsEffect), true);
  // Both paths merge by seq; the catch-up applies only to its game and hand.
  strictEqual(playsEffect.includes("setPlays((current) => mergePlays(current, [event]));"), true);
  const catchUpStart = view.indexOf("const catchUpPlays = useCallback(");
  const catchUp = view.slice(catchUpStart, catchUpStart + 900);
  strictEqual(catchUp.includes('.eq("game_id", gameId)'), true);
  strictEqual(catchUp.includes("playsCatchUpApplies(issued, { gameId: activeGameIdRef.current, handNo: activeGameRef.current?.hand_no })"), true);
  strictEqual(catchUp.includes("setPlays((current) => mergePlays(current, data as PlayEvent[]));"), true);
  // The sound and the Go splash stay with the live event only.
  strictEqual(playsEffect.includes("tableSound.card(playKey("), true);
  strictEqual(playsEffect.includes("showGo(`go:"), true);
  strictEqual(catchUp.includes("tableSound"), false);
});
check("realtime stopgap: mergePlays adds each seq once, in order; the catch-up skips another hand", () => {
  const p = (seq: number, card: string | null = `c${seq}`) => ({ seq, segment: 1, user_id: "a", kind: "play" as const, card, count_after: seq });
  const shown = [p(1), p(2)];
  // A duplicate event: the same array back (nothing re-renders).
  strictEqual(mergePlays(shown, [p(2)]), shown);
  strictEqual(mergePlays(shown, []), shown);
  // The live event and the catch-up read overlapping: each seq once.
  deepStrictEqual(mergePlays(shown, [p(1), p(2), p(3), p(4)]).map((x) => x.seq), [1, 2, 3, 4]);
  // Out of order in, in order out; a seq repeated within the input once.
  deepStrictEqual(mergePlays([p(3)], [p(5), p(1), p(5), p(2)]).map((x) => x.seq), [1, 2, 3, 5]);
  // The screen's copy of a seq is kept.
  strictEqual(mergePlays([p(1, "AS")], [p(1, "KH")])[0].card, "AS");
  // From empty (a new hand): the read's plays.
  deepStrictEqual(mergePlays([], [p(2), p(1)]).map((x) => x.seq), [1, 2]);
  // The catch-up: same game and hand only.
  strictEqual(playsCatchUpApplies({ gameId: "g", handNo: 3 }, { gameId: "g", handNo: 3 }), true);
  strictEqual(playsCatchUpApplies({ gameId: "g", handNo: 3 }, { gameId: "g", handNo: 4 }), false, "a Next Hand during the read");
  strictEqual(playsCatchUpApplies({ gameId: "g", handNo: 3 }, { gameId: "h", handNo: 3 }), false, "a new game");
  strictEqual(playsCatchUpApplies({ gameId: "g", handNo: 3 }, { gameId: null, handNo: undefined }), false, "the game ended");
  strictEqual(playsCatchUpApplies({ gameId: "g", handNo: undefined }, { gameId: "g", handNo: null }), true);
});
check("realtime stopgap: no profiles listener; the poll re-reads every profile every 4th poll", () => {
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes('table: "profiles"'), false);
  strictEqual(PROFILE_REFRESH_POLLS, 4);
  deepStrictEqual([1, 2, 3, 4, 5, 8, 12].map(pollRefreshesProfiles), [false, false, false, true, false, true, true]);
  strictEqual(pollRefreshesProfiles(0), false);
  strictEqual(view.includes("pollCountRef.current++;"), true);
  strictEqual(view.includes("await loadMembers(tableId, true, pollRefreshesProfiles(pollCountRef.current));"), true);
  // The refresh reads everyone on screen; a poll without it, only new seats.
  const shown = [
    { user_id: "a", seat: 1, nickname: "Walt" },
    { user_id: "b", seat: 2, nickname: "Yoda" },
  ];
  const rows = [{ user_id: "a", seat: 1 }, { user_id: "b", seat: 2 }, { user_id: "c", seat: 3 }];
  deepStrictEqual(profilesToFetch(rows, shown, true), ["c"]);
  deepStrictEqual(profilesToFetch(rows, shown, true, true), ["a", "b", "c"]);
  // A changed name or avatar is a difference the poll applies.
  strictEqual(view.includes("if (s && (s.nickname !== m.nickname || s.avatar_url !== m.avatar_url)) out.push(`profile ${m.user_id}`);"), true);
});
check("realtime stopgap: a table_members delete from another table is ignored; leavers have two fallbacks", () => {
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  // Still listening (filtered), but the table is checked on the client too:
  // Supabase only filters delete events under replica identity FULL.
  strictEqual(/event: "DELETE",\s*schema: "public",\s*table: "table_members",\s*filter: `table_id=eq\.\$\{table\.id\}`/.test(view), true);
  strictEqual(view.includes("if (goneRow.table_id !== undefined && goneRow.table_id !== table.id) return;"), true);
  // Fallback 1: the poll's roster read notices a leaver.
  strictEqual(view.includes("for (const s of shown) if (!fresh.some((m) => m.user_id === s.user_id)) out.push(`left ${s.user_id}`);"), true);
  // Fallback 2 (mid-game): leave_table ends the game, which the filtered
  // games UPDATE listener brings at once.
  strictEqual(/event: "UPDATE",\s*schema: "public",\s*table: "games",\s*filter: `table_id=eq\.\$\{table\.id\}`/.test(view), true);
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
check("nickname: the 7-day lock (step 3 slice E) shows the server's words, or a plain fallback", () => {
  strictEqual(
    nicknameSaveErrorMessage({ code: "P0001", message: "You can change your nickname again in 3 days.", details: "nickname_locked" }),
    "You can change your nickname again in 3 days."
  );
  strictEqual(nicknameSaveErrorMessage({ code: "P0001", message: "", details: "nickname_locked" }), NICKNAME_LOCKED_FALLBACK);
  // Still: a taken nickname in words, anything else as sent.
  strictEqual(nicknameSaveErrorMessage({ code: "23505", message: "duplicate key value", details: "Key exists" }), "That nickname is taken.");
  strictEqual(nicknameSaveErrorMessage({ code: "P0001", message: "something else", details: null }), "something else");
  // The save sends the error object as Supabase returns it (details included).
  const save = readFileSync("lib/profileNickname.ts", "utf8");
  strictEqual(save.includes("if (error) return { ok: false, message: nicknameSaveErrorMessage(error) };"), true);
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
  for (const level of ["easy", "casual", "medium", "Hard", "", null, undefined]) strictEqual(isGodLevel(level), false, String(level));
});
check("splash: the new Normie (casual) and Rainman (medium) are not God; no God splash at their tables", () => {
  for (const level of ["casual", "medium"]) {
    strictEqual(isGodLevel(level), false, level);
    for (const score of [120, 75, 40]) strictEqual(godLossSplash(level, true, score), null, `${level}, ${score}`);
  }
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
    for (const level of ["easy", "casual", "medium", null, undefined]) {
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
check("sounds: the card clip starts so its tick meets the card landing", () => {
  const card = CORE_SOUNDS.card[0];
  // The tick's onset in card.mp3 is ~358 ms of 460: the offset stops just short.
  strictEqual(CARD_TICK_S > 0.3 && CARD_TICK_S < 0.358, true);
  strictEqual(CARD_FADE_IN_S > 0 && CARD_FADE_IN_S <= 0.358 - CARD_TICK_S, true);
  // Already on screen (a pegging play, a cut): the slide is skipped.
  deepStrictEqual(clipTiming(card, 0), { delayS: 0, offsetS: CARD_TICK_S });
  deepStrictEqual(clipTiming(card, -0.04), { delayS: 0, offsetS: CARD_TICK_S });
  // A toss's flight: the whole clip, held back so the tick is at the landing.
  const toss = clipTiming(card, 0.55);
  strictEqual(toss.offsetS, 0);
  strictEqual(Math.abs(toss.delayS + CARD_TICK_S - 0.55) < 1e-9, true);
  // Landing sooner than the tick: at once, part of the slide skipped.
  const soon = clipTiming(card, 0.1);
  strictEqual(soon.delayS, 0);
  strictEqual(Math.abs(soon.offsetS - (CARD_TICK_S - 0.1)) < 1e-9, true);
  // Every other clip plays from its start, at once, as before.
  for (const url of clipsFor(null).filter((u) => u !== card)) {
    deepStrictEqual(clipTiming(url, 0), { delayS: 0, offsetS: 0 });
    deepStrictEqual(clipTiming(url, 0.55), { delayS: 0, offsetS: 0 });
  }
  deepStrictEqual(clipTiming("/boards/x/card.mp3", 0.55), { delayS: 0, offsetS: 0 });
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

// THE HEADER (header-room): Hide counts in the "⋯" menu, no Muggins label
// on the right, and "Reconnecting..." a dot on narrow screens.
check("header: Hide counts sits in an accessible ⋯ menu that opens over the speaker", () => {
  const src = readFileSync("components/table/CountsToggle.tsx", "utf8");
  for (const needle of ['aria-haspopup="true"', "aria-expanded={open}", 'aria-label="Table options"', 'role="menu"', 'role="menuitem"', "min-h-10", '"Escape"', "pointerdown"]) {
    strictEqual(src.includes(needle), true, needle);
  }
  // Locked (Muggins): nothing in the header -- the tag line says Self-Scoring.
  strictEqual(src.includes("if (locked) return null;"), true);
  strictEqual(src.includes("Self-Scoring (Muggins)"), false);
  // The popover sits above the speaker, which sits above the deal overlay.
  const css = readFileSync("app/globals.css", "utf8");
  const speaker = Number(css.match(/\.sound-toggle \{[^}]*z-index: (\d+)/)?.[1]);
  const popover = Number(src.match(/z-\[(\d+)\]/)?.[1]);
  strictEqual(popover > speaker, true, `${popover} > ${speaker}`);
});
check("header: Reconnecting is a dot under 400px, the words kept for screen readers", () => {
  const src = readFileSync("components/table/ReconnectingNote.tsx", "utf8");
  for (const needle of ['role="status"', 'title="Reconnecting..."', "max-[399px]:sr-only", "min-[400px]:hidden", "max-[399px]:hidden"]) {
    strictEqual(src.includes(needle), true, needle);
  }
  const page = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(page.includes('realtimeStatus === "disconnected" && <ReconnectingNote beside={leaveConfirming} />'), true);
  strictEqual(page.includes(">Reconnecting...</span>"), false);
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

const LADDER: [number, string][] = [
  [10, "white"], [20, "bronze"], [30, "silver"], [40, "gold"], [50, "emerald"],
  [60, "sapphire"], [70, "ruby"], [80, "diamond"], [90, "prismatic"], [100, "black"],
];
check("wings: the ladder -- ten tiers, one every 10 God wins", () => {
  deepStrictEqual(WINGS_TIERS.map((t) => [t.wins, t.tier]), LADDER);
  for (const t of WINGS_TIERS) strictEqual(t.name, t.tier); // the Profile line's word
});
check("wings: a tier at every threshold, and either side of it", () => {
  // Every boundary, both sides: 9|10, 19|20 ... 99|100.
  for (let i = 0; i < LADDER.length; i++) {
    const [wins, tier] = LADDER[i];
    strictEqual(tierForCount(wins - 1), i === 0 ? null : LADDER[i - 1][1], String(wins - 1));
    strictEqual(tierForCount(wins), tier, String(wins));
  }
  for (const [count, tier] of [[0, null], [25, "bronze"], [101, "black"], [150, "black"], [250, "black"]] as const) {
    strictEqual(tierForCount(count), tier, String(count));
  }
});
check("wings: the next tier, and the Profile's progress line", () => {
  strictEqual(nextTier(0)?.tier, "white");
  strictEqual(nextTier(9)?.wins, 10);
  strictEqual(nextTier(10)?.tier, "bronze");
  strictEqual(nextTier(25)?.tier, "silver");
  strictEqual(nextTier(99)?.tier, "black");
  strictEqual(nextTier(100), null);
  strictEqual(nextTier(101), null);
  strictEqual(progress(7).text, "7 / 10 to white wings");
  strictEqual(progress(0).text, "0 / 10 to white wings");
  strictEqual(progress(10).text, "10 / 20 to bronze wings");
  strictEqual(progress(27).text, "27 / 30 to silver wings");
  strictEqual(progress(49).text, "49 / 50 to emerald wings");
  strictEqual(progress(85).text, "85 / 90 to prismatic wings");
  strictEqual(progress(99).text, "99 / 100 to black wings");
  strictEqual(progress(100).text, "Black wings. Legend.");
  strictEqual(progress(250).text, "Black wings. Legend.");
  strictEqual(progress(30).tier, "silver");
  strictEqual(progress(65).tier, "sapphire");
});
check("wings: a milestone is exactly a tier's count", () => {
  for (let n = 0; n <= 200; n++) strictEqual(isMilestone(n), n >= 10 && n <= 100 && n % 10 === 0, String(n));
});
check("wings: the ten-tier ladder's new milestones are 20 to 90, not 10 or 100", () => {
  for (let n = 0; n <= 200; n++) strictEqual(isNewLadderMilestone(n), n >= 20 && n <= 90 && n % 10 === 0, String(n));
});
check("wings: the seen tier -- saved per player under the v2 key, safe with nothing stored", () => {
  strictEqual(readSeenTier("a"), null); // no localStorage at all, as here in Node
  writeSeenTier("a", "gold"); // and doesn't throw
  initSeenTier("a", 50);
  withStorage((store) => {
    strictEqual(readSeenTier("a"), null);
    writeSeenTier("a", "gold");
    strictEqual(wingsSeenKey("a"), "nobs:wings-seen:v2:a");
    strictEqual(store.get("nobs:wings-seen:v2:a"), "gold");
    strictEqual(readSeenTier("a"), "gold");
    strictEqual(readSeenTier("b"), null); // per player
    writeSeenTier("a", null);
    strictEqual(readSeenTier("a"), "none");
    for (const t of WINGS_TIERS) {
      writeSeenTier("a", t.tier);
      strictEqual(readSeenTier("a"), t.tier); // every tier reads back
    }
    store.set(wingsSeenKey("a"), "purple");
    strictEqual(readSeenTier("a"), null); // an edited value is no value
    strictEqual(store.has("nobs:wings-seen:a"), false); // the old key is never written
  });
});
check("wings: the old key is ignored -- a stale value never suppresses a splash", () => {
  withStorage((store) => {
    store.set("nobs:wings-seen:a", "black"); // the four-tier ladder's key, at its top
    strictEqual(readSeenTier("a"), null); // not read
    initSeenTier("a", 19);
    strictEqual(readSeenTier("a"), "white");
    strictEqual(shouldCelebrate(20, readSeenTier("a")), true);
  });
});
check("wings: launch is silent -- the first read notes the tier, and never celebrates", () => {
  withStorage(() => {
    // A player already on 34, seen for the first time.
    initSeenTier("a", 34);
    strictEqual(readSeenTier("a"), "silver");
    strictEqual(shouldCelebrate(34, readSeenTier("a")), false);
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
  strictEqual(shouldCelebrate(20, "white"), true);
  strictEqual(shouldCelebrate(30, "bronze"), true);
  strictEqual(shouldCelebrate(30, "white"), true); // a skipped splash never blocks the next
  strictEqual(shouldCelebrate(40, "silver"), true);
  strictEqual(shouldCelebrate(50, "gold"), true);
  strictEqual(shouldCelebrate(60, "emerald"), true);
  strictEqual(shouldCelebrate(70, "sapphire"), true);
  strictEqual(shouldCelebrate(80, "ruby"), true);
  strictEqual(shouldCelebrate(90, "diamond"), true);
  strictEqual(shouldCelebrate(100, "prismatic"), true);
  strictEqual(shouldCelebrate(10, "white"), false); // a refresh: seen is written first
  strictEqual(shouldCelebrate(20, "bronze"), false);
  strictEqual(shouldCelebrate(11, "none"), false); // not a milestone
  strictEqual(shouldCelebrate(25, "white"), false); // the four-tier ladder's 25 is no milestone now
  strictEqual(shouldCelebrate(9, "none"), false);
  strictEqual(shouldCelebrate(30, "gold"), false); // never down
  strictEqual(shouldCelebrate(10, null), false); // never read, or no storage
  withStorage(() => {
    initSeenTier("a", 9);
    strictEqual(shouldCelebrate(10, readSeenTier("a")), true);
    writeSeenTier("a", tierForCount(10));
    strictEqual(shouldCelebrate(10, readSeenTier("a")), false);
  });
});

// The table page's milestone check (wingsMoment, app/tables/[code]/page.tsx)
// claims through this: note a first read, ask, write the seen tier, and only
// then show.
const wingsMomentFor = claimWingsMoment;
check("wings v2: exactly on a new milestone at the first read -- that splash once (BK on 20)", () => {
  withStorage(() => {
    // Home or Profile reads first: notes white, not bronze.
    initSeenTier("bk", 20);
    strictEqual(readSeenTier("bk"), "white");
    // Home again, then the table's roster read: nothing moves.
    initSeenTier("bk", 20);
    strictEqual(readSeenTier("bk"), "white");
    // The won game's result on screen: the catch-up asks, and gets bronze.
    strictEqual(wingsMomentFor("bk", 20), "bronze");
    strictEqual(readSeenTier("bk"), "bronze");
    // Dismissed, then a refresh and every later read: never again.
    strictEqual(wingsMomentFor("bk", 20), null);
    initSeenTier("bk", 20);
    strictEqual(wingsMomentFor("bk", 20), null);
    // The next win is 21: silent. Silver is next, at 30.
    strictEqual(wingsMomentFor("bk", 21), null);
    strictEqual(wingsMomentFor("bk", 30), "silver");
  });
  withStorage(() => {
    // The catch-up is this device's very first read: it notes and fires at once.
    strictEqual(wingsMomentFor("bk", 20), "bronze");
    strictEqual(wingsMomentFor("bk", 20), null);
  });
  // Every new milestone, 20 to 90, the same: the tier below noted, its splash due.
  for (const [wins, tier] of LADDER.slice(1, -1)) {
    withStorage(() => {
      initSeenTier("p", wins);
      strictEqual(readSeenTier("p"), tierForCount(wins - 1), String(wins));
      strictEqual(wingsMomentFor("p", wins), tier, String(wins));
      strictEqual(wingsMomentFor("p", wins), null, String(wins));
    });
  }
});
check("wings v2: one past a new milestone (21) -- silent, the tier just noted", () => {
  withStorage(() => {
    initSeenTier("a", 21);
    strictEqual(readSeenTier("a"), "bronze");
    strictEqual(wingsMomentFor("a", 21), null);
  });
  withStorage(() => strictEqual(wingsMomentFor("a", 21), null));
});
check("wings v2: 10 and 100 at the first read -- silent, as at the first launch", () => {
  for (const [count, tier] of [[10, "white"], [100, "black"]] as const) {
    withStorage(() => {
      initSeenTier("a", count);
      strictEqual(readSeenTier("a"), tier);
      strictEqual(wingsMomentFor("a", count), null);
    });
    withStorage(() => strictEqual(wingsMomentFor("a", count), null)); // the win's own read
  }
});
check("wings v2: 25-29 wins with an old silver -- bronze silently now, the silver splash at 30", () => {
  for (let count = 25; count <= 29; count++) {
    withStorage((store) => {
      store.set("nobs:wings-seen:a", "silver"); // the four-tier ladder's value
      initSeenTier("a", count);
      strictEqual(readSeenTier("a"), "bronze", String(count));
      strictEqual(wingsMomentFor("a", count), null, String(count));
      for (let n = count + 1; n < 30; n++) strictEqual(wingsMomentFor("a", n), null, String(n));
      strictEqual(wingsMomentFor("a", 30), "silver", String(count));
      strictEqual(wingsMomentFor("a", 30), null);
    });
  }
});
check("wings v2: blocked storage still never celebrates, even on a new milestone", () => {
  const g = globalThis as unknown as { localStorage?: unknown };
  const blocked = () => {
    throw new Error("blocked");
  };
  g.localStorage = { getItem: blocked, setItem: blocked };
  try {
    strictEqual(wingsMomentFor("bk", 20), null);
  } finally {
    delete g.localStorage;
  }
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
check("wings: the badge -- eleven colours (ten tiers and the creator), 11px on a 28px avatar", () => {
  // The four-tier ladder's dots, unchanged.
  for (const [t, c] of [["white", "#ffffff"], ["silver", "#cfe0ff"], ["gold", "#ffd24a"], ["black", "#ff5a14"], ["creator", "#2ee07a"]] as const) {
    strictEqual(WINGS_BADGE[t], c, t);
  }
  deepStrictEqual(Object.keys(WINGS_BADGE).sort(), [...ALL_WINGS_TIERS].sort());
  // All ten tiers' dots are different, and none is the creator's.
  const tierDots = WINGS_TIERS.map((t) => WINGS_BADGE[t.tier]);
  strictEqual(new Set(tierDots).size, 10);
  strictEqual(tierDots.includes(WINGS_BADGE.creator), false);
  // Diamond is a pale ice-blue gradient, so it can't read as white or silver;
  // prismatic a rainbow.
  strictEqual(WINGS_BADGE.diamond.startsWith("linear-gradient("), true);
  strictEqual(WINGS_BADGE.prismatic.startsWith("conic-gradient("), true);
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
  strictEqual(new Set(wingsAssets()).size, wingsAssets().length); // each file once
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
check("wings: the creator -- creator wings at any count, or none to read", () => {
  const walt = "f190b27b-a23b-4464-8445-023edbee28b2";
  deepStrictEqual([...CREATOR_USER_IDS], [walt]);
  strictEqual(isCreator(walt), true);
  for (const earned of [null, undefined, tierForCount(0), tierForCount(9), tierForCount(100), tierForCount(250)]) {
    strictEqual(displayTier(walt, earned), "creator");
  }
  strictEqual(displayTier(walt, "black"), "creator"); // wins over any God-win tier
  for (const t of WINGS_TIERS) strictEqual(displayTier(walt, t.tier), "creator", t.tier); // every new tier too
  for (let n = 0; n <= 150; n++) strictEqual(displayTier(walt, tierForCount(n)), "creator", String(n));
});
check("wings: the creator -- everyone else is exactly as before", () => {
  for (const id of ["a", "00000000-0000-0000-0000-000000000000", "F190B27B-A23B-4464-8445-023EDBEE28B2"]) {
    strictEqual(isCreator(id), false, id);
    strictEqual(displayTier(id, null), null);
    strictEqual(displayTier(id, "gold"), "gold");
    for (const t of WINGS_TIERS) strictEqual(displayTier(id, t.tier), t.tier, t.tier);
  }
  strictEqual(isCreator(null), false);
  strictEqual(isCreator(undefined), false);
  strictEqual(displayTier(null, "white"), "white");
});
check("wings: the creator -- a count never earns it, and the milestone rules don't change", () => {
  for (let n = 0; n <= 250; n++) strictEqual(tierForCount(n) === ("creator" as unknown), false);
  deepStrictEqual(
    WINGS_TIERS.map((t) => t.tier),
    ["white", "bronze", "silver", "gold", "emerald", "sapphire", "ruby", "diamond", "prismatic", "black"]
  );
  for (let count = 10; count <= 100; count += 10) strictEqual(isMilestone(count), true);
  strictEqual(shouldCelebrate(10, "none"), true);
  strictEqual(shouldCelebrate(100, "prismatic"), true);
  strictEqual(shouldCelebrate(10, "white"), false);
});
check("wings: the creator -- the seen tier moves as for anyone, and the ears stay", () => {
  const walt = CREATOR_USER_IDS[0];
  withStorage((store) => {
    initSeenTier(walt, 20); // a new milestone at the first read: due, as for anyone
    strictEqual(readSeenTier(walt), "white");
    strictEqual(store.has(`nobs:wings-seen:v2:${walt}`), true);
    // The claim writes the seen tier, but there is no splash for the creator.
    strictEqual(wingsMomentFor(walt, 20), null);
    strictEqual(readSeenTier(walt), "bronze");
    strictEqual(wingsMomentFor(walt, 20), null);
    strictEqual(displayTier(walt, tierForCount(20)), "creator");
  });
});

// HOME'S CATCH-UP (claimHomeWingsMoment, used by components/brand/HomeView.tsx).
check("wings home: exactly 20 with the tier unseen -- Bronze once, never after dismissal or a refresh", () => {
  withStorage((store) => {
    // Home is this device's first read: notes white, and claims bronze.
    strictEqual(claimHomeWingsMoment("bk", 20), "bronze");
    strictEqual(store.get("nobs:wings-seen:v2:bk"), "bronze"); // written before it shows
    // Dismissed, then a refresh, then Home again later: nothing.
    strictEqual(claimHomeWingsMoment("bk", 20), null);
    strictEqual(claimHomeWingsMoment("bk", 20), null);
    // Nor at the table's catch-up afterwards: the seen tier is shared.
    strictEqual(claimWingsMoment("bk", 20), null);
  });
  withStorage(() => {
    // Profile (or anything) read first and noted white: Home still claims it.
    initSeenTier("bk", 20);
    strictEqual(readSeenTier("bk"), "white");
    strictEqual(claimHomeWingsMoment("bk", 20), "bronze");
    strictEqual(claimHomeWingsMoment("bk", 20), null);
  });
  // Every new milestone the same, 20 to 90.
  for (const [wins, tier] of LADDER.slice(1, -1)) {
    withStorage(() => {
      strictEqual(claimHomeWingsMoment("p", wins), tier, String(wins));
      strictEqual(claimHomeWingsMoment("p", wins), null, String(wins));
    });
  }
});
check("wings home: 21, or any count that is not a new milestone -- nothing, only noted", () => {
  withStorage(() => {
    strictEqual(claimHomeWingsMoment("a", 21), null);
    strictEqual(readSeenTier("a"), "bronze");
  });
  for (let n = 0; n <= 150; n++) {
    if (isNewLadderMilestone(n)) continue;
    withStorage(() => strictEqual(claimHomeWingsMoment("a", n), null, String(n)));
  }
});
check("wings home: 10 and 100 stay the table's -- silent at the first read, and never claimed by Home", () => {
  for (const [count, below] of [[10, "none"], [100, "prismatic"]] as const) {
    withStorage(() => {
      strictEqual(claimHomeWingsMoment("a", count), null); // a first read: silent
      strictEqual(readSeenTier("a"), tierForCount(count));
    });
    withStorage(() => {
      // Seen below it (the win's splash missed at the table): Home leaves it
      // due for the table's result screen, and doesn't write it.
      writeSeenTier("a", below === "none" ? null : below);
      strictEqual(claimHomeWingsMoment("a", count), null);
      strictEqual(readSeenTier("a"), below);
      strictEqual(claimWingsMoment("a", count), tierForCount(count));
    });
  }
});
check("wings home: never for the creator, whose seen tier still moves", () => {
  const walt = CREATOR_USER_IDS[0];
  withStorage(() => {
    strictEqual(claimHomeWingsMoment(walt, 20), null);
    strictEqual(readSeenTier(walt), "bronze");
    strictEqual(claimHomeWingsMoment(walt, 30), null);
    strictEqual(readSeenTier(walt), "silver");
    strictEqual(displayTier(walt, tierForCount(30)), "creator");
  });
});
check("wings home: a splash already shown at the table is not shown again on Home", () => {
  withStorage(() => {
    initSeenTier("a", 19);
    strictEqual(claimWingsMoment("a", 20), "bronze"); // the live win, at the table
    strictEqual(claimHomeWingsMoment("a", 20), null);
  });
  withStorage(() => {
    initSeenTier("a", 20);
    strictEqual(claimWingsMoment("a", 20), "bronze"); // the result screen's catch-up
    strictEqual(claimHomeWingsMoment("a", 20), null);
  });
  withStorage(() => {
    // Blocked or missing storage: no claim can be kept, so none shows.
    const g = globalThis as unknown as { localStorage?: unknown };
    const keep = g.localStorage;
    g.localStorage = undefined;
    strictEqual(claimHomeWingsMoment("a", 20), null);
    g.localStorage = keep;
  });
});
check("wings home: God's skunk splash still follows only the table's live win", () => {
  // The follow-up waits out the wings splash, exactly as before.
  strictEqual(splashDurationMs("wings"), SPLASH_MS);
  strictEqual(godLossSplash("hard", true, 90), "skunk");
  // Home shows the wings splash alone: no God's splash is passed with it.
  const home = readFileSync("components/brand/HomeView.tsx", "utf8");
  const calls = home.match(/showWings\([^;]*;/g) ?? [];
  strictEqual(calls.length, 1);
  strictEqual(/showWings\(`wings:home:\$\{userId\}:\$\{myCount\}`, moment\)/.test(calls[0]), true);
  strictEqual(home.includes("showGodLoss"), false);
  // The table still passes it, from the live win only.
  const table = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(table.includes("showWings(`wings:${wonGameId}`, wings, loss ? { key: lossKey, loss } : undefined)"), true);
  strictEqual(table.includes("showWings(`wings:${myGodWinId}`, moment)"), true);
});
// THE MADE ART (scripts/make-wings-tiers.mjs): every made tier's alpha must be
// its source original's, byte for byte (docs/art/sources/). Decoded once here
// with sharp (it comes with Next), before the synchronous checks below.
const MADE_FROM: Record<string, string> = {
  bronze: "silver",
  silver: "silver",
  gold: "gold",
  emerald: "emerald",
  sapphire: "silver",
  ruby: "silver",
  diamond: "silver",
  prismatic: "silver",
};
const madeAlpha: Record<string, boolean> = await (async () => {
  const sharp = createRequire(import.meta.url)("sharp");
  const alphaOf = async (file: string) => {
    const { data } = await sharp(file).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    const out = Buffer.alloc(data.length / 4);
    for (let i = 0; i < out.length; i++) out[i] = data[i * 4 + 3];
    return out;
  };
  const result: Record<string, boolean> = {};
  for (const [tier, source] of Object.entries(MADE_FROM)) {
    for (const size of ["full", "mini"]) {
      const [made, original] = await Promise.all([
        alphaOf(`public/wings/${size}-${tier}.webp`),
        alphaOf(`docs/art/sources/${size}-${source}-original.webp`),
      ]);
      result[`${size}-${tier}`] = made.equals(original);
    }
  }
  return result;
})();

check("wings: the creator -- the ears art, no flames or glow, an emerald dot", () => {
  strictEqual(wingsUrl("creator", "full"), "/wings/full-ears.webp");
  strictEqual(wingsUrl("creator", "mini"), "/wings/mini-ears.webp");
  strictEqual(wingsUrl("black", "full"), "/wings/full-black.webp"); // unchanged
  strictEqual(wingsAssets().includes("/wings/full-ears.webp"), true);
  strictEqual(wingsAssets().includes("/wings/mini-ears.webp"), true);
  strictEqual(existsSync("public/wings/full-ears.webp"), true);
  strictEqual(existsSync("public/wings/mini-ears.webp"), true);
  // The old green wings are back as emerald, under emerald's own name; nothing
  // points at the green files.
  strictEqual(existsSync("public/wings/full-green.webp"), false);
  strictEqual(existsSync("public/wings/mini-green.webp"), false);
  strictEqual(wingsAssets().some((url) => url.includes("green")), false);
  strictEqual(wingsUrl("emerald", "full"), "/wings/full-emerald.webp");
  strictEqual(wingsUrl("emerald", "mini"), "/wings/mini-emerald.webp");
  // The restored green wings are emerald's source now, kept as they came back
  // from bc1ee3b^:public/wings/full-green.webp and mini-green.webp.
  strictEqual(statSync("docs/art/sources/full-emerald-original.webp").size, 69964);
  strictEqual(statSync("docs/art/sources/mini-emerald-original.webp").size, 7188);
  strictEqual(WINGS_BADGE.creator, "#2ee07a");
  // Flames are the black tier's only: not the ears, not emerald, not any new tier.
  strictEqual(hasFlames("creator"), false);
  strictEqual(hasFlames("black"), true);
  for (const t of WINGS_TIERS) strictEqual(hasFlames(t.tier), t.tier === "black", t.tier);
  // No glow behind the ears; every earned tier has its own, all different.
  strictEqual(WINGS_HALO.creator, null);
  strictEqual(WINGS_HALO.black, "rgb(255 90 20 / 0.38)");
  for (const t of WINGS_TIERS) strictEqual(typeof WINGS_HALO[t.tier], "string", t.tier);
  strictEqual(new Set(WINGS_TIERS.map((t) => WINGS_HALO[t.tier])).size, 10);
  deepStrictEqual(
    [...ALL_WINGS_TIERS],
    ["white", "bronze", "silver", "gold", "emerald", "sapphire", "ruby", "diamond", "prismatic", "black", "creator"]
  );
  // Every tier has art of its own, full and mini, under its own name, at the
  // art's sizes; no tier borrows another's; wingsAssets lists every one.
  const webpSize = (file: string) => {
    // A VP8X WebP keeps its canvas size, less one, in bytes 24-29.
    const b = readFileSync(file);
    strictEqual(b.toString("ascii", 12, 16), "VP8X", file);
    return [1 + b.readUIntLE(24, 3), 1 + b.readUIntLE(27, 3)];
  };
  for (const t of WINGS_TIERS) {
    for (const [size, wh] of [["full", [860, 556]], ["mini", [168, 109]]] as const) {
      const url = `/wings/${size}-${t.tier}.webp`;
      strictEqual(wingsUrl(t.tier, size), url, `${t.tier} ${size}`);
      strictEqual(existsSync(`public${url}`), true, url);
      deepStrictEqual(webpSize(`public${url}`), [...wh], url);
      strictEqual(wingsAssets().includes(url), true, url);
    }
  }
  strictEqual(new Set(WINGS_TIERS.map((t) => wingsUrl(t.tier, "full"))).size, 10);
  strictEqual(new Set(WINGS_TIERS.map((t) => wingsUrl(t.tier, "mini"))).size, 10);
  // Every file in public/wings is listed, once (no stray copies, nothing shared).
  deepStrictEqual(readdirSync("public/wings").filter((f) => f.endsWith(".webp")).sort(), wingsAssets().filter((u) => u.endsWith(".webp")).map((u) => u.slice(7)).sort());
  // The made tiers come from the committed script, from Walt's originals in
  // docs/art/sources, at the art's sizes; each made file's alpha is its
  // original's, byte for byte. White, black and the ears are not made.
  strictEqual(existsSync("scripts/make-wings-tiers.mjs"), true);
  deepStrictEqual(Object.keys(MADE_FROM).sort(), WINGS_TIERS.map((t) => t.tier).filter((t) => t !== "white" && t !== "black").sort());
  for (const source of ["silver", "gold", "emerald"]) {
    for (const [size, wh] of [["full", [860, 556]], ["mini", [168, 109]]] as const) {
      deepStrictEqual(webpSize(`docs/art/sources/${size}-${source}-original.webp`), [...wh], `${size}-${source}-original`);
    }
  }
  for (const [key, same] of Object.entries(madeAlpha)) strictEqual(same, true, `${key}: alpha differs from its original`);
  strictEqual(Object.keys(madeAlpha).length, 16);
  // Nothing from docs/art is served: the sources, the approval sheets.
  deepStrictEqual(readdirSync("docs/art/sources").sort(), ["full-emerald-original.webp", "full-gold-original.webp", "full-silver-original.webp", "mini-emerald-original.webp", "mini-gold-original.webp", "mini-silver-original.webp"]);
  for (const v of [1, 2, 3]) strictEqual(existsSync(`docs/art/wings-ladder-preview-v${v}.png`), true, `preview v${v}`);
  strictEqual(readdirSync("public/wings").some((f) => /original|preview|polished|crystal|candidate|\.png$/.test(f)), false);
  strictEqual(existsSync("public/art"), false);
  // The creator takes no splash words: WINGS_SPLASH is the earned tiers only.
  strictEqual("creator" in WINGS_SPLASH, false);
});
check("wings: every tier has its splash words", () => {
  for (const t of WINGS_TIERS) strictEqual(WINGS_SPLASH[t.tier].length > 0, true, t.tier);
  strictEqual(new Set(Object.values(WINGS_SPLASH)).size, 10); // no two the same
  deepStrictEqual(WINGS_SPLASH, {
    white: "YOU'VE GOT WINGS, MY CHILD",
    bronze: "BRONZE WINGS, MY CHILD",
    silver: "SILVER WINGS, MY CHILD",
    gold: "GOLD WINGS, MY CHILD",
    emerald: "EMERALD WINGS, MY CHILD",
    sapphire: "SAPPHIRE WINGS, MY CHILD",
    ruby: "RUBY WINGS, MY CHILD",
    diamond: "DIAMOND WINGS, MY CHILD",
    prismatic: "PRISMATIC WINGS, MY CHILD",
    black: "EVEN GOD FEARS YOU",
  });
  strictEqual(wingsSplashSub(25), "25 wins against God");
  // Profile's "Creator · N wins against God" line: singular for one.
  strictEqual(wingsSplashSub(1), "1 win against God");
  strictEqual(wingsSplashSub(2), "2 wins against God");
  strictEqual(wingsSplashSub(0), "0 wins against God");
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

// ---- Profile stats (lib/soloStats.ts, PRD item 35 S3) -----------------------
const soloRow = (level: string, w: number, l: number, sk = 0, dsk = 0, tsk = 0, user = "me"): SoloStatsRow => ({
  user_id: user,
  level,
  wins: w,
  losses: l,
  skunks: sk,
  double_skunks: dsk,
  times_skunked: tsk,
  skunk_tracking_since: "2026-10-20T00:00:00Z",
});
check("solo stats: four entries in ladder order, whatever order the rows come in", () => {
  const shaped = shapeSoloStats([soloRow("hard", 1, 9), soloRow("easy", 5, 1), soloRow("medium", 2, 2), soloRow("casual", 3, 0)], "me");
  deepStrictEqual(shaped.map((e) => e.level), [...COMPUTER_LEVEL_ORDER]);
  deepStrictEqual(shaped.map((e) => e.level), ["easy", "casual", "medium", "hard"]);
  deepStrictEqual(shaped.map((e) => [e.wins, e.losses]), [[5, 1], [3, 0], [2, 2], [1, 9]]);
  strictEqual(shaped.every((e) => e.played), true);
});
check("solo stats: a level with no row is zeros, not played, with a dash for win %", () => {
  const shaped = shapeSoloStats([soloRow("casual", 4, 2)], "me");
  strictEqual(shaped.length, 4);
  for (const e of shaped.filter((x) => x.level !== "casual")) {
    deepStrictEqual(
      { w: e.wins, l: e.losses, g: e.games, pct: e.winPct, sk: e.skunks, dsk: e.doubleSkunks, tsk: e.timesSkunked, played: e.played },
      { w: 0, l: 0, g: 0, pct: null, sk: 0, dsk: 0, tsk: 0, played: false }
    );
    strictEqual(formatWinPercent(e.winPct), "–");
  }
  strictEqual(shapeSoloStats([], "me").every((e) => !e.played), true);
});
check("solo stats: win % rounded, null (a dash) with zero games", () => {
  strictEqual(winPercent(0, 0), null);
  strictEqual(winPercent(2, 1), 67);
  strictEqual(winPercent(1, 2), 33);
  strictEqual(winPercent(1, 7), 13); // 12.5 rounds up
  strictEqual(winPercent(5, 0), 100);
  strictEqual(winPercent(0, 4), 0);
  strictEqual(formatWinPercent(67), "67%");
  strictEqual(formatWinPercent(0), "0%");
  strictEqual(formatWinPercent(null), "–");
});
check("solo stats: skunks stay with their own level, never summed across levels", () => {
  const shaped = shapeSoloStats([soloRow("easy", 6, 0, 3, 1, 0), soloRow("hard", 1, 8, 0, 0, 5)], "me");
  const byLevel = Object.fromEntries(shaped.map((e) => [e.level, [e.skunks, e.doubleSkunks, e.timesSkunked]]));
  deepStrictEqual(byLevel, { easy: [3, 1, 0], casual: [0, 0, 0], medium: [0, 0, 0], hard: [0, 0, 5] });
  deepStrictEqual(skunkChips(shaped[0]), [{ label: "Skunks", value: 3 }, { label: "Double Skunks", value: 1 }]);
  deepStrictEqual(skunkChips(shaped[3]), [{ label: "Skunked", value: 5 }]);
  deepStrictEqual(skunkChips(shaped[1]), []);
});
check("solo stats: other players' rows, unknown levels and repeats are ignored", () => {
  const shaped = shapeSoloStats(
    [soloRow("easy", 9, 9, 0, 0, 0, "someone"), soloRow("bogus", 1, 1), soloRow("easy", 2, 1), soloRow("easy", 7, 7)],
    "me"
  );
  deepStrictEqual([shaped[0].wins, shaped[0].losses], [2, 1]);
  strictEqual(shaped.filter((e) => e.played).length, 1);
});
check("multiplayer record: own row, null with no row or no human games", () => {
  const lb = (user: string, w: number, l: number) => ({
    user_id: user,
    wins: w,
    losses: l,
    skunks: 2,
    double_skunks: 1,
    times_skunked: 3,
    skunk_tracking_since: null,
  });
  const mine = multiplayerRecord([lb("other", 9, 1), lb("me", 3, 1)], "me");
  deepStrictEqual(mine, { wins: 3, losses: 1, games: 4, winPct: 75, skunks: 2, doubleSkunks: 1, timesSkunked: 3 });
  strictEqual(multiplayerRecord([lb("other", 9, 1)], "me"), null); // no row (or hidden)
  strictEqual(multiplayerRecord([lb("me", 0, 0)], "me"), null); // listed only for Beat God
  strictEqual(multiplayerRecord([], "me"), null);
});
check("profile stats: Solo Play shows God first, Shortbus last; the ladder itself is unchanged", () => {
  deepStrictEqual([...PROFILE_SOLO_ORDER], ["hard", "medium", "casual", "easy"]);
  deepStrictEqual([...COMPUTER_LEVEL_ORDER], ["easy", "casual", "medium", "hard"]);
  const shaped = shapeSoloStats(
    [soloRow("easy", 6, 0, 3, 1, 0), soloRow("hard", 1, 8, 0, 0, 5), soloRow("bogus", 9, 9)],
    "me",
    PROFILE_SOLO_ORDER
  );
  // All four levels, in the Profile's order, with zeros filled in.
  deepStrictEqual(shaped.map((e) => e.level), ["hard", "medium", "casual", "easy"]);
  deepStrictEqual(shaped.map((e) => [e.wins, e.losses, e.played]), [[1, 8, true], [0, 0, false], [0, 0, false], [6, 0, true]]);
  strictEqual(shaped[1].winPct, null);
  // Skunks kept with their own level.
  deepStrictEqual(
    shaped.map((e) => [e.skunks, e.doubleSkunks, e.timesSkunked]),
    [[0, 0, 5], [0, 0, 0], [0, 0, 0], [3, 1, 0]]
  );
});
check("profile stats: computer faces fall back cleanly", () => {
  const fallback = computerFaces([]);
  deepStrictEqual(COMPUTER_LEVEL_ORDER.map((l) => fallback[l].name), ["Shortbus", "Normie", "Rainman", "God"]);
  strictEqual(fallback.hard.url, null);
  const live = computerFaces([{ level: "hard", nickname: "God", avatar_url: "https://x/god.png" }, { level: "x", nickname: "?", avatar_url: null }]);
  deepStrictEqual(live.hard, { name: "God", url: "https://x/god.png" });
  deepStrictEqual(live.easy, { name: "Shortbus", url: null });
});

// ---- Leaderboard filters (lib/leaderboardFilter.ts, PRD item 35 S4) --------
check("leaderboard filter: each valid ?vs is that computer's board", () => {
  for (const level of ["easy", "casual", "medium", "hard"] as const) {
    deepStrictEqual(filterFromSearch(`?vs=${level}`), { kind: "computer", level });
    deepStrictEqual(filterFromSearch(new URLSearchParams({ vs: level })), { kind: "computer", level });
  }
});
check("leaderboard filter: missing or invalid ?vs is Multiplayer", () => {
  for (const search of ["", "?", "?vs=", "?vs=god", "?vs=normie", "?vs=all", "?vs=hard2", "?other=1", "?VS=hard", "?vs=%20"]) {
    deepStrictEqual(filterFromSearch(search), ALL_PLAYERS, search);
  }
});
check("leaderboard filter: any case and stray spaces read; the FIRST ?vs wins when repeated", () => {
  deepStrictEqual(filterFromSearch("?vs=HARD"), { kind: "computer", level: "hard" });
  deepStrictEqual(filterFromSearch("?vs=Casual"), { kind: "computer", level: "casual" });
  deepStrictEqual(filterFromSearch("?vs=%20medium%20"), { kind: "computer", level: "medium" });
  deepStrictEqual(filterFromSearch("?vs=easy&vs=hard"), { kind: "computer", level: "easy" });
  deepStrictEqual(filterFromSearch("?vs=bogus&vs=hard"), ALL_PLAYERS); // the first is invalid
});
check("leaderboard filter: the URL is written canonically, other params kept", () => {
  strictEqual(searchForFilter("", { kind: "computer", level: "hard" }), "?vs=hard");
  strictEqual(searchForFilter("?vs=HARD", ALL_PLAYERS), "");
  strictEqual(searchForFilter("?vs=easy&vs=hard", { kind: "computer", level: "medium" }), "?vs=medium");
  strictEqual(searchForFilter("?case=list&vs=easy", ALL_PLAYERS), "?case=list");
  strictEqual(searchForFilter("?case=list", { kind: "computer", level: "casual" }), "?case=list&vs=casual");
  // Round trip.
  for (const level of ["easy", "casual", "medium", "hard"] as const) {
    deepStrictEqual(filterFromSearch(searchForFilter("", { kind: "computer", level })), { kind: "computer", level });
  }
  strictEqual(sameFilter(ALL_PLAYERS, { kind: "all" }), true);
  strictEqual(sameFilter({ kind: "computer", level: "hard" }, { kind: "computer", level: "hard" }), true);
  strictEqual(sameFilter({ kind: "computer", level: "hard" }, { kind: "computer", level: "easy" }), false);
  strictEqual(sameFilter(ALL_PLAYERS, { kind: "computer", level: "easy" }), false);
});
check("leaderboard chips: Multiplayer, then the Profile's order (God first), live names with fallbacks", () => {
  const chips = leaderboardChips(computerFaces([{ level: "hard", nickname: "God", avatar_url: "https://x/god.png" }]));
  deepStrictEqual(chips.map((c) => c.id), ["all", ...PROFILE_SOLO_ORDER]);
  deepStrictEqual(chips.map((c) => c.label), ["Multiplayer", "God", "Rainman", "Normie", "Shortbus"]);
  deepStrictEqual(chips[0].filter, ALL_PLAYERS);
  strictEqual(chips[0].avatar, undefined);
  deepStrictEqual(chips[1].avatar, { name: "God", url: "https://x/god.png" });
  deepStrictEqual(chips[4].filter, { kind: "computer", level: "easy" });
  // With no faces read at all: LEVEL_INFO names, no avatar image.
  deepStrictEqual(leaderboardChips({}).map((c) => [c.label, c.avatar?.url ?? null]), [
    ["Multiplayer", null], ["God", null], ["Rainman", null], ["Normie", null], ["Shortbus", null],
  ]);
});
check("leaderboard filter: a computer board's words", () => {
  deepStrictEqual(computerBoardText("God"), {
    heading: "Against God",
    empty: "Nobody has finished a game against God yet.",
    failed: "Couldn't load this leaderboard. Try Refresh.",
  });
});

// ---- Friends (lib/follows.ts and ?friends, PRD item 36 F2/F3) ---------------
check("friends param: only ?friends=1 is on; the first wins when repeated; ?vs untouched", () => {
  strictEqual(friendsFromSearch("?friends=1"), true);
  strictEqual(friendsFromSearch(new URLSearchParams({ friends: "1" })), true);
  for (const off of ["", "?friends=", "?friends=0", "?friends=true", "?friends=yes", "?friends=01", "?friends=%201", "?FRIENDS=1", "?vs=hard"]) {
    strictEqual(friendsFromSearch(off), false, off);
  }
  strictEqual(friendsFromSearch("?friends=1&friends=0"), true);
  strictEqual(friendsFromSearch("?friends=0&friends=1"), false);
  strictEqual(friendsFromSearch("?vs=hard&friends=1"), true);
  deepStrictEqual(filterFromSearch("?vs=hard&friends=1"), { kind: "computer", level: "hard" });
  deepStrictEqual(filterFromSearch("?friends=1"), ALL_PLAYERS);
});
check("friends param: written canonically (?vs then friends=1), removed when off, other params kept", () => {
  strictEqual(searchForView("", ALL_PLAYERS, true), "?friends=1");
  strictEqual(searchForView("", { kind: "computer", level: "hard" }, true), "?vs=hard&friends=1");
  strictEqual(searchForView("?friends=1&vs=hard", { kind: "computer", level: "hard" }, true), "?vs=hard&friends=1");
  strictEqual(searchForView("?vs=hard&friends=1", { kind: "computer", level: "hard" }, false), "?vs=hard");
  strictEqual(searchForView("?vs=hard&friends=1", ALL_PLAYERS, false), "");
  strictEqual(searchForView("?friends=1&friends=1&vs=easy&vs=hard", ALL_PLAYERS, true), "?friends=1");
  strictEqual(searchForView("?case=x&friends=0", { kind: "computer", level: "easy" }, true), "?case=x&vs=easy&friends=1");
  // A chip keeps the switch as it is.
  strictEqual(searchForFilter("?friends=1", { kind: "computer", level: "medium" }), "?vs=medium&friends=1");
  strictEqual(searchForFilter("?vs=medium&friends=1", ALL_PLAYERS), "?friends=1");
  strictEqual(searchForFilter("?vs=medium", ALL_PLAYERS), "");
  strictEqual(searchForFilter("?vs=medium&friends=0", { kind: "computer", level: "hard" }), "?vs=hard");
});
type FRow = { user_id: string; wins: number; losses: number };
const fr = (user_id: string, wins: number, losses: number): FRow => ({ user_id, wins, losses });
const BOARD: FRow[] = [fr("a", 10, 1), fr("b", 9, 2), fr("me", 9, 2), fr("c", 9, 2), fr("d", 5, 5), fr("e", 5, 5), fr("f", 1, 9)];
check("friends view: followed players plus me, in the board's order, re-ranked with ties, no cut", () => {
  const view = friendsView(BOARD, new Set(["a", "c", "e", "zz"]), "me");
  deepStrictEqual(view.map((r) => r.user_id), ["a", "me", "c", "e"]);
  deepStrictEqual(rankWithTies(view).map((x) => [x.row.user_id, x.rank]), [["a", 1], ["me", 2], ["c", 2], ["e", 4]]);
  // The full board's ranks, for contrast: me shared 2nd with b and c.
  deepStrictEqual(rankWithTies(BOARD).map((x) => x.rank), [1, 2, 2, 2, 5, 5, 7]);
  // No cut: 51 rows all kept.
  const many = Array.from({ length: 60 }, (_, i) => fr(`p${i}`, 60 - i, i));
  const follows = new Set(many.slice(0, 50).map((r) => r.user_id));
  strictEqual(friendsView([...many, fr("me", 0, 99)], follows, "me").length, 51);
});
check("friends view: always me when I have a row; nothing extra when I don't; empty follows = only me", () => {
  deepStrictEqual(friendsView(BOARD, new Set(), "me").map((r) => r.user_id), ["me"]);
  const noMe = BOARD.filter((r) => r.user_id !== "me");
  deepStrictEqual(friendsView(noMe, new Set(["b"]), "me").map((r) => r.user_id), ["b"]);
  deepStrictEqual(friendsView(noMe, new Set(), "me"), []);
  deepStrictEqual(friendsView(BOARD, new Set(["a"]), null).map((r) => r.user_id), ["a"]);
});
check("friends view: the snapshot decides, so an unfollowed card stays until a new snapshot", () => {
  const snapshot = new Set(["a", "c"]); // taken when the switch turned on
  const live = toggledSet(snapshot, "c", false); // then c was unfollowed
  strictEqual(live.has("c"), false);
  strictEqual(snapshot.has("c"), true); // the snapshot isn't touched
  deepStrictEqual(friendsView(BOARD, snapshot, "me").map((r) => r.user_id), ["a", "me", "c"]); // c stays
  deepStrictEqual(friendsView(BOARD, new Set(live), "me").map((r) => r.user_id), ["a", "me"]); // Refresh: gone
  deepStrictEqual([...toggledSet(new Set(["a"]), "b", true)].sort(), ["a", "b"]);
  deepStrictEqual([...toggledSet(new Set(["a"]), "a", true)], ["a"]);
  deepStrictEqual([...toggledSet(new Set(["a"]), "zz", false)], ["a"]);
});
check("friends hint: follow nobody, nobody followed on the board, or none", () => {
  strictEqual(friendsHint([fr("me", 1, 1)], new Set(), "me", null), FOLLOW_NOBODY_HINT);
  strictEqual(
    FOLLOW_NOBODY_HINT,
    "You aren't following anyone yet. Turn Friends only off, then tap the star on a player's card to follow them."
  );
  strictEqual(friendsHint([], new Set(), "me", "God"), FOLLOW_NOBODY_HINT);
  strictEqual(
    friendsHint([fr("me", 1, 1)], new Set(["a"]), "me", "God"),
    "None of the players you follow have finished a game against God yet."
  );
  strictEqual(friendsHint([], new Set(["a"]), "me", null), "None of the players you follow have finished a multiplayer game yet.");
  strictEqual(friendsHint([fr("me", 1, 1), fr("a", 2, 0)], new Set(["a"]), "me", null), null);
});
check("follow outcomes: success, the cap message, and the failure message", () => {
  strictEqual(followSucceeded(true, "following"), true);
  strictEqual(followSucceeded(false, "not_following"), true);
  strictEqual(followSucceeded(true, "not_following"), false);
  strictEqual(followMessage(true, "following"), null);
  strictEqual(followMessage(false, "not_following"), null);
  strictEqual(followMessage(true, "limit"), "You can follow up to 50 players. Unfollow someone first.");
  strictEqual(FOLLOW_LIMIT_MESSAGE, "You can follow up to 50 players. Unfollow someone first.");
  strictEqual(followMessage(true, "not_allowed"), FOLLOW_FAILED_MESSAGE);
  strictEqual(followMessage(true, "error"), "Couldn't update that just now.");
  strictEqual(followMessage(false, "error"), "Couldn't update that just now.");
});
check("follow outcomes: the churn limit (step 3 slice E) has its own message", () => {
  strictEqual(followErrorOutcome({ details: "rate_limited" }), "rate_limited");
  strictEqual(followErrorOutcome({ details: null }), "error");
  strictEqual(followErrorOutcome(null), "error");
  strictEqual(followSucceeded(true, "rate_limited"), false);
  strictEqual(followSucceeded(false, "rate_limited"), false);
  strictEqual(followMessage(true, "rate_limited"), FOLLOW_RATE_MESSAGE);
  strictEqual(followMessage(false, "rate_limited"), FOLLOW_RATE_MESSAGE);
  strictEqual(FOLLOW_RATE_MESSAGE, "You can follow or unfollow 30 times an hour. Please try again a little later.");
  const src = readFileSync("lib/follows.ts", "utf8");
  strictEqual(src.includes("if (error) return followErrorOutcome(error);"), true);
});
check("avatar file names (step 3 slice E): one fixed, lower-case name per type", () => {
  strictEqual(avatarPath("u1", { type: "image/png", name: "Me.PNG" }), "u1/avatar.png");
  strictEqual(avatarPath("u1", { type: "image/jpeg", name: "me.JPEG" }), "u1/avatar.jpg");
  strictEqual(avatarPath("u1", { type: "image/webp", name: "x" }), "u1/avatar.webp");
  strictEqual(avatarPath("u1", { type: "IMAGE/PNG", name: "a.gif" }), "u1/avatar.png", "the type decides");
  // No type: the extension, in any case.
  strictEqual(avatarPath("u1", { type: "", name: "photo.JPG" }), "u1/avatar.jpg");
  strictEqual(avatarPath("u1", { type: "", name: "photo.jpeg" }), "u1/avatar.jpg");
  strictEqual(avatarExtension({ type: "", name: "noext" }), null);
  // Anything the bucket won't take: no path.
  strictEqual(avatarPath("u1", { type: "image/gif", name: "a.gif" }), null);
  strictEqual(avatarPath("u1", { type: "image/heic", name: "a.png" }), null);
  strictEqual(avatarPath("u1", { type: "", name: "a.svg" }), null);
  // Every name produced is one of the four the storage policy allows.
  for (const ext of ["png", "jpg", "webp"]) strictEqual(["png", "jpg", "jpeg", "webp"].includes(ext), true);
  // The profile page uses it, and refuses with the message when it says no.
  const page = readFileSync("app/profile/page.tsx", "utf8");
  strictEqual(page.includes("const path = avatarPath(session.user.id, avatarFile);"), true);
  strictEqual(/if \(!path\) \{\s*setStatus\("error"\);\s*setMessage\(AVATAR_TYPE_MESSAGE\);\s*return;/.test(page), true);
  strictEqual(page.includes('avatarFile.name.split(".").pop()'), false, "no raw extension any more");
  strictEqual(AVATAR_TYPE_MESSAGE, "Please choose a PNG, JPEG or WebP picture.");
});

// ---- The Block List (moderation M1: lib/blocks.ts, docs/sql/moderation-m1-*.sql)
check("block list: the plain refusal has a kind of its own, word for word, from join and watch", () => {
  strictEqual(REFUSED_TEXT, "You can't join this table.");
  // As PostgREST hands it over: P0001, no details, no hint.
  deepStrictEqual(rpcRefusal({ message: REFUSED_TEXT, details: null, hint: null, code: "P0001" }), { kind: "refused", text: REFUSED_TEXT });
  deepStrictEqual(watchRefusal(REFUSED_TEXT), { kind: "refused", text: REFUSED_TEXT });
  // A quiet rewatch that meets it: a screen with the text (no redirect).
  deepStrictEqual(rewatchOutcome(REFUSED_TEXT), { kind: "screen", text: REFUSED_TEXT });
  // Only the exact text; every other message is mapped as before.
  deepStrictEqual(rpcRefusal({ message: "You can't join this table" }), { kind: "unknown", text: GENERIC_ERROR_TEXT });
  deepStrictEqual(watchRefusal("You can't join this table"), { kind: "other", text: GENERIC_ERROR_TEXT });
  deepStrictEqual(rpcRefusal({ message: "This table is full." }), { kind: "full", text: TABLE_FULL_TEXT });
  deepStrictEqual(watchRefusal("This table does not allow spectators."), { kind: "not_allowed", text: NOT_ALLOWED_TEXT });
  deepStrictEqual(watchRefusal("You were removed from watching this table."), { kind: "removed", text: REMOVED_TEXT });
  // The server raises exactly this text, in join and in watch (SQL doubles the quote).
  // (SQL comment lines left out: the header quotes the statement too.)
  const part2 = readFileSync("docs/sql/moderation-m1-part2.sql", "utf8")
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n");
  const raises = part2.match(/raise exception 'You can''t join this table\.';/g) ?? [];
  strictEqual(raises.length, 2);
  strictEqual("You can''t join this table.".replace("''", "'"), REFUSED_TEXT);
  // No detail or hint on it (nothing that could tell it apart from "This table is full.").
  strictEqual(/raise exception using[^;]*You can''t join/.test(part2), false);
});
check("block list: every join and watch screen shows the refusal (typed code, link, Open Tables row, preview, watch)", () => {
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  // The bare-code preview, the private by-id preview and takeSeat show why.text (refused included).
  strictEqual((view.match(/setError\(why\.text\);/g) ?? []).length >= 3, true);
  // A public table read by id asks the preview by id BEFORE Play-or-Watch and the nickname step.
  const entryAt = view.indexOf('if (entryError && rpcRefusal(entryError).kind === "refused") {');
  strictEqual(entryAt > 0, true);
  strictEqual(/if \(!previewed && !seatsError && !isMember && tableRow\.created_by !== session!\.user\.id\) \{\s*const \{ error: entryError \} = await playerRpc\("join_table_by_code", \{\s*p_code: tableRow\.code,\s*p_table_id: tableRow\.id,\s*p_preview: true,\s*\}\);\s*if \(cancelled\) return;\s*if \(entryError && rpcRefusal\(entryError\)\.kind === "refused"\) \{\s*setError\(REFUSED_TEXT\);\s*return;\s*\}\s*\}/.test(view), true);
  strictEqual(entryAt < view.indexOf("joinOrWatch({"), true, "before Play-or-Watch");
  strictEqual(entryAt < view.indexOf("THE NICKNAME GATE. A NEW seat needs a nickname first"), true, "before the nickname step");
  // The watch page: a by-id refusal through watchRefusal; the confirm's preview refusal shows its text.
  const watch = readFileSync("app/watch/[code]/page.tsx", "utf8");
  strictEqual(watch.includes("const refusal = watchRefusal(result.refused);"), true);
  strictEqual(watch.includes(': { kind: "refused", text: r.text, login: false }'), true);
  strictEqual(readFileSync("lib/spectatorData.ts", "utf8").includes("return { refused: error.message };"), true);
});
check("block list: Profile messages say only whether it worked", () => {
  strictEqual(BLOCK_LIMIT, 100);
  deepStrictEqual(blockMessage("blocked"), { ok: true, text: BLOCKED_TEXT });
  strictEqual(BLOCKED_TEXT, "Blocked.");
  deepStrictEqual(blockMessage("already_blocked"), { ok: false, text: ALREADY_BLOCKED_TEXT });
  deepStrictEqual(blockMessage("not_found"), { ok: false, text: BLOCK_NOT_FOUND_TEXT });
  deepStrictEqual(blockMessage("not_allowed"), { ok: false, text: BLOCK_NOT_ALLOWED_TEXT });
  deepStrictEqual(blockMessage("limit"), { ok: false, text: BLOCK_LIMIT_TEXT });
  strictEqual(BLOCK_LIMIT_TEXT, "Your Block List is full (100 players). Unblock someone first.");
  deepStrictEqual(blockMessage("rate_limited"), { ok: false, text: BLOCK_RATE_TEXT });
  strictEqual(BLOCK_RATE_TEXT, "You can block or unblock 30 times an hour. Please try again a little later.");
  deepStrictEqual(blockMessage("error"), { ok: false, text: BLOCK_FAILED_TEXT });
  deepStrictEqual(unblockMessage("unblocked"), { ok: true, text: UNBLOCKED_TEXT });
  deepStrictEqual(unblockMessage("not_blocked"), { ok: true, text: UNBLOCKED_TEXT });
  deepStrictEqual(unblockMessage("rate_limited"), { ok: false, text: BLOCK_RATE_TEXT });
  deepStrictEqual(unblockMessage("error"), { ok: false, text: BLOCK_FAILED_TEXT });
  strictEqual(blockErrorOutcome({ details: "rate_limited" }), "rate_limited");
  strictEqual(blockErrorOutcome({ details: null }), "error");
  strictEqual(blockErrorOutcome(null), "error");
  // The list: newest first as the server sends it; a blank name shown plainly; junk rows dropped.
  deepStrictEqual(
    blockedPlayersFromRows([
      { user_id: "u2", nickname: " Elsa ", avatar_url: "x", created_at: "2026-11-25T10:00:00Z" },
      { user_id: "u1", nickname: "", created_at: "2026-11-25T09:00:00Z" },
      { nickname: "no id" },
    ]),
    [
      { userId: "u2", nickname: "Elsa", createdAt: "2026-11-25T10:00:00Z" },
      { userId: "u1", nickname: UNNAMED_PLAYER, createdAt: "2026-11-25T09:00:00Z" },
    ]
  );
  strictEqual(blockedPlayersFromRows(null), null);
});
check("block list: the app reads and writes it only through the three RPCs, never the table", () => {
  const lib = readFileSync("lib/blocks.ts", "utf8");
  // (moderation M2 added block_player_by_id, the chat card's Block by account id.)
  deepStrictEqual([...lib.matchAll(/\.rpc\("([a-z_]+)"/g)].map((m) => m[1]), ["get_my_blocks", "block_player", "block_player_by_id", "unblock_player"]);
  strictEqual(lib.includes('{ p_nickname: nickname }') && lib.includes('{ p_target: userId }'), true);
  strictEqual(lib.includes("if (error) return blockErrorOutcome(error);"), true);
  const ui = readFileSync("components/brand/BlockedPlayers.tsx", "utf8");
  strictEqual(/supabase|\.rpc\(|\.from\(/.test(ui), false, "the component goes through lib/blocks.ts");
  strictEqual(ui.includes("<form onSubmit={handleBlock}"), true);
  strictEqual(ui.includes('type="button"\n                  onClick={() => handleUnblock(player)}'), true);
  // No direct read or write of the table anywhere in the app.
  for (const dir of ["app", "components", "lib"]) {
    const walk = (d: string): string[] =>
      readdirSync(d).flatMap((f) => {
        const p = `${d}/${f}`;
        return statSync(p).isDirectory() ? walk(p) : /\.(ts|tsx)$/.test(f) ? [p] : [];
      });
    for (const f of walk(dir)) strictEqual(/from\(\s*["']blocks["']/.test(readFileSync(f, "utf8")), false, f);
  }
  // The Profile page: under the stats, outside the profile form.
  const page = readFileSync("app/profile/page.tsx", "utf8");
  strictEqual(/after=\{\s*<>\s*<ProfileStats userId=\{session\.user\.id\} \/>\s*<BlockedPlayers \/>\s*<\/>\s*\}/.test(page), true);
  strictEqual(page.indexOf("<BlockedPlayers />") < page.indexOf("<form onSubmit={handleSubmit}"), true);
});
check("block list: the SQL keeps every client out of the table and the helper", () => {
  const part1 = readFileSync("docs/sql/moderation-m1-part1.sql", "utf8");
  for (const role of ["public", "anon", "authenticated", "service_role"]) {
    strictEqual(part1.includes(`revoke all on table public.blocks from ${role};`), true, role);
    strictEqual(part1.includes(`revoke all on function public._is_blocked_from_table(uuid, uuid) from ${role};`), true, role);
  }
  strictEqual(/grant [a-z, ]+ on table public\.blocks/i.test(part1), false, "no table grant");
  strictEqual(/grant execute on function public\._is_blocked_from_table/i.test(part1), false, "no helper grant");
  for (const fn of ["block_player(text)", "unblock_player(uuid)", "get_my_blocks()"]) {
    strictEqual(part1.includes(`revoke all on function public.${fn} from public;`), true, fn);
    strictEqual(part1.includes(`grant execute on function public.${fn} to authenticated;`), true, fn);
  }
  strictEqual(part1.includes("alter table public.blocks enable row level security;"), true);
  strictEqual(/create policy[^;]*public\.blocks/i.test(part1), false, "no policies");
  // The grants suite knows the table (no privileges) and the three RPCs.
  const grants = readFileSync("docs/sql/slice-e-grants-verification.sql", "utf8");
  strictEqual(grants.includes("select 'blocks', '', '' where v_m1"), true);
  strictEqual(grants.includes("array['block_player', 'get_my_blocks', 'unblock_player']"), true);
  // Every M1 SQL file is stored with CRLF line ends, like the rest of docs/sql.
  for (const f of ["precheck", "part1", "part2", "part1-rollback", "part2-rollback", "verification"]) {
    const raw = readFileSync(`docs/sql/moderation-m1-${f}.sql`);
    strictEqual(raw.includes(Buffer.from("\r\n")), true, f);
    strictEqual(/(?<!\r)\n/.test(raw.toString("latin1")), false, `${f}: a bare LF`);
  }
});

// ---- Mute and block in chat (moderation M2, redesigned in M2c) ------------
// A tiny in-memory localStorage for the storage helpers (restored after).
function withFakeStorage(store: Map<string, string> | "broken", fn: () => void) {
  const before = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  const fail = (): never => {
    throw new Error("blocked");
  };
  const fake =
    store === "broken"
      ? {
          getItem: fail,
          setItem: fail,
          removeItem: fail,
          key: fail,
          get length(): number {
            return fail();
          },
        }
      : {
          getItem: (k: string) => store.get(k) ?? null,
          setItem: (k: string, v: string) => void store.set(k, v),
          removeItem: (k: string) => void store.delete(k),
          key: (i: number) => [...store.keys()][i] ?? null,
          get length() {
            return store.size;
          },
        };
  Object.defineProperty(globalThis, "localStorage", { value: fake, configurable: true, writable: true });
  try {
    fn();
  } finally {
    if (before) Object.defineProperty(globalThis, "localStorage", before);
    else delete (globalThis as { localStorage?: unknown }).localStorage;
  }
}
check("chat mute: a per-player, per-table key; a stored value always reads as a clean entry", () => {
  strictEqual(chatMutedKey("u1", "t1"), "nobs:chat-muted:v1:u1:t1");
  for (const raw of [null, undefined, "", "x", "[]", "null", '{"ids":[1,2]}']) deepStrictEqual(parseMuted(raw).ids, [], String(raw));
  deepStrictEqual(parseMuted(JSON.stringify({ seenAt: 7, ids: ["a", "b", "a", "", 3] })), { seenAt: 7, ids: ["a", "b"] });
  strictEqual(parseMuted(JSON.stringify({ ids: ["a"] })).seenAt, 0, "no seenAt: pruned soon");
  const one = withMuted(withMuted({ seenAt: 0, ids: [] }, "a", 1), "a", 2);
  deepStrictEqual(one, { seenAt: 2, ids: ["a"] }, "muting twice keeps one");
  deepStrictEqual(withoutMuted(one, "a", 3), { seenAt: 3, ids: [] });
  let many = { seenAt: 0, ids: [] as string[] };
  for (let i = 0; i < CHAT_MUTE_LIMIT + 5; i++) many = withMuted(many, `u${i}`, i);
  strictEqual(many.ids.length, CHAT_MUTE_LIMIT);
});
check("chat mute: lasts the table on this browser, never carries to another table; broken storage is nobody muted", () => {
  const store = new Map<string, string>();
  withFakeStorage(store, () => {
    muteSender("me", "t1", "a", 1);
    muteSender("me", "t1", "b", 2);
    muteSender("me", "t1", "a", 3);
    muteSender("me", "t1", "me", 4); // never yourself
    muteSender("other", "t1", "c", 5); // another account on this browser
    deepStrictEqual(readMutedIds("me", "t1"), ["a", "b"]);
    deepStrictEqual(readMutedIds("me", "t2"), [], "another table starts clean");
    deepStrictEqual(readMutedIds("other", "t1"), ["c"]);
    strictEqual(mutedIdsText("me", "t1"), "a,b");
    unmuteSender("me", "t1", "a", 6);
    deepStrictEqual(readMutedIds("me", "t1"), ["b"]);
    unmuteSender("me", "t1", "b", 7);
    strictEqual(store.has("nobs:chat-muted:v1:me:t1"), false, "an empty list leaves no key");
    strictEqual(mutedIdsText("nobody", "t1"), "");
  });
  withFakeStorage("broken", () => {
    deepStrictEqual(readMutedIds("me", "t1"), []);
    strictEqual(mutedIdsText("me", "t1"), "");
    muteSender("me", "t1", "a"); // no throw
    unmuteSender("me", "t1", "a");
    touchMuted("me", "t1");
  });
});
check("chat mute: tables not seen in 24 hours are pruned, the seen table is kept, the old hide list is deleted", () => {
  strictEqual(CHAT_MUTE_KEEP_MS, 24 * 60 * 60 * 1000);
  const now = 10 * CHAT_MUTE_KEEP_MS;
  const entry = (seenAt: number) => JSON.stringify({ seenAt, ids: ["a"] });
  deepStrictEqual(
    staleMuteKeys(
      [
        { key: "nobs:chat-muted:v1:me:fresh", raw: entry(now - CHAT_MUTE_KEEP_MS) },
        { key: "nobs:chat-muted:v1:me:old", raw: entry(now - CHAT_MUTE_KEEP_MS - 1) },
        { key: "nobs:chat-muted:v1:me:empty", raw: JSON.stringify({ seenAt: now, ids: [] }) },
        { key: "nobs:chat-muted:v1:me:junk", raw: "x" },
        { key: "nobs:chat-hidden:v1:me", raw: "[]" },
        { key: "nobs:appearance", raw: "x" },
      ],
      now
    ),
    ["nobs:chat-muted:v1:me:old", "nobs:chat-muted:v1:me:empty", "nobs:chat-muted:v1:me:junk", "nobs:chat-hidden:v1:me"]
  );
  const store = new Map<string, string>([
    ["nobs:chat-muted:v1:me:t1", entry(1)],
    ["nobs:chat-muted:v1:me:t2", entry(1)],
    ["nobs:chat-muted:v1:other:t3", entry(now - 1000)],
    ["nobs:chat-hidden:v1:me", JSON.stringify([{ userId: "a", name: "Ann", hiddenAt: 1 }])],
    ["nobs:something-else", "keep"],
  ]);
  withFakeStorage(store, () => touchMuted("me", "t1", now));
  deepStrictEqual([...store.keys()].sort(), ["nobs:chat-muted:v1:me:t1", "nobs:chat-muted:v1:other:t3", "nobs:something-else"]);
  strictEqual(JSON.parse(store.get("nobs:chat-muted:v1:me:t1") ?? "{}").seenAt, now, "opening the table refreshes it");
  withFakeStorage(store, () => touchMuted("me", "t9", now));
  strictEqual(store.has("nobs:chat-muted:v1:me:t9"), false, "opening a table never creates an entry");
  // The page touches (and so prunes) whenever a table opens.
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("if (myUserId && chatTableId) touchMuted(myUserId, chatTableId);"), true);
});
check("old hide list: the Settings panel, its component, lib/chatHide.ts and every reader of its key are gone", () => {
  strictEqual(existsSync("components/brand/ChatHiddenList.tsx"), false);
  strictEqual(existsSync("lib/chatHide.ts"), false);
  const page = readFileSync("app/settings/page.tsx", "utf8");
  strictEqual(/ChatHiddenList|Hidden in chat|after=/.test(page), false);
  strictEqual(page.includes('<CardRoomFrame title="Settings">'), true);
  const walk = (d: string): string[] =>
    readdirSync(d).flatMap((f) => {
      const p = `${d}/${f}`;
      return statSync(p).isDirectory() ? walk(p) : /\.(ts|tsx)$/.test(f) ? [p] : [];
    });
  for (const dir of ["app", "components", "lib"]) {
    for (const f of walk(dir)) {
      const src = readFileSync(f, "utf8");
      if (f !== "lib/chatMute.ts") strictEqual(src.includes("chat-hidden"), false, f);
      strictEqual(/lib\/chatHide|hideSender|unhideSender|ChatHiddenList|HiddenHereLine|hiddenAtTable/.test(src), false, f);
    }
  }
  // The only mention left: lib/chatMute.ts, which deletes the old key.
  strictEqual(readFileSync("lib/chatMute.ts", "utf8").includes('export const OLD_CHAT_HIDDEN_PREFIX = "nobs:chat-hidden:v1:";'), true);
});
check("chat: muted senders (muted here + blocked) are filtered; nothing muted leaves the list as it is", () => {
  const msg = (id: string, senderId: string) => ({ id, senderId, name: senderId, avatarUrl: null, text: "hi", at: 0 });
  const list = [msg("1", "a"), msg("2", "b"), msg("3", "a")];
  const muted = mutedSenders(["a"], ["c"]);
  deepStrictEqual([...muted].sort(), ["a", "c"]);
  deepStrictEqual(withoutSenders(list, muted).map((m) => m.id), ["2"]);
  strictEqual(withoutSenders(list, new Set()), list);
  strictEqual(withoutSenders(list, new Set(["z"])), list);
  // The hook: dropped on arrival before anything is stored, filtered from
  // what shows, and forgotten for good by a Mute.
  const hook = readFileSync("components/table/useTableChat.ts", "utf8");
  const drop = hook.indexOf("if (mutedRef.current.has(senderId)) return;");
  strictEqual(drop > 0 && drop < hook.indexOf("addChatMessage(list, {"), true);
  strictEqual(hook.includes("const shown = useMemo(() => withoutSenders(messages, muted), [messages, muted]);"), true);
  strictEqual(hook.includes("return { messages: shown,"), true);
  strictEqual(hook.includes("const dropSender = useCallback("), true);
  // The page passes the muted set, from this table's mute list and the Block List.
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("const chatMuted = useMemo(() => mutedSenders(mutedIds, blockedIds), [mutedIds, blockedIds]);"), true);
  strictEqual(view.includes("    muted: chatMuted,\n  });"), true);
  strictEqual(view.includes('() => (myUserId && chatTableId ? mutedIdsText(myUserId, chatTableId) : ""),'), true);
  // The Block List is re-read on open (chat on), after a Block, and on tab focus.
  strictEqual(/useEffect\(\(\) => \{\s*if \(!chatOn\) return;[\s\S]{0,300}readMyBlocks\(\)[\s\S]{0,400}addEventListener\("focus", onVisible\);\s*document\.addEventListener\("visibilitychange", onVisible\);/.test(view), true);
});
check("chat card: a visible ... on other people's cards only, opening the person popup (no dropdown)", () => {
  const ui = readFileSync("components/table/TableChat.tsx", "utf8");
  const card = ui.slice(ui.indexOf("function ChatCard("), ui.indexOf("export function ChatAnnouncer"));
  strictEqual(card.includes("const showMore = own ? undefined : onMore;"), true, "never on my own card");
  strictEqual(card.includes("onClick={showMore}"), true);
  strictEqual(card.includes("aria-label={`More for ${m.name}`}"), true);
  strictEqual(card.includes('aria-haspopup="dialog"'), true);
  strictEqual(card.includes("h-11 w-9"), true, "as tall as the x: the card's height doesn't change");
  strictEqual(/role="menu"|PersonMenuItems|data-chat-menu=/.test(card), false, "no dropdown on the card");
  strictEqual(/Report/.test(card.replace(/\{\/\*[\s\S]*?\*\/\}/g, "")), false, "no Report yet");
  const stack = ui.slice(ui.indexOf("export function ChatStack"), ui.indexOf("function ChatCard("));
  const ownBlock = stack.slice(stack.indexOf("{own && ("), stack.indexOf("{candidates.map("));
  strictEqual(ownBlock.includes("onMore="), false);
  strictEqual(stack.includes("canOfferPersonMenu({ userId: m.senderId, myUserId: moderation.myUserId, enabled: moderation.enabled })"), true);
  strictEqual(stack.includes("? () => openPersonPopup(m.senderId, m.name)"), true);
  strictEqual(/menuFor|setMenuFor/.test(ui), false, "the dropdown's state is gone");
  // The host's eye on a spectator's card: now Kick (the same confirm as the list).
  strictEqual(card.includes('data-chat-eye="remove"'), true);
  strictEqual(card.includes("aria-label={`Kick ${m.name}`}") && card.includes('title="Kick"'), true);
  strictEqual(/Remove \$\{m\.name\}|Remove from watching/.test(card), false);
  strictEqual(card.includes('aria-label={own ? "Close your message" : `Close message from ${m.name}`}'), true);
  strictEqual(/lib\/blocks|lib\/chatMute|supabase/.test(ui), false);
});
// ---- The person popup at the table (moderation M2b, redesigned in M2c) ----
check("person popup: Mute or Unmute and Report for everyone, Kick for the host only; no Hide, Block or Unblock; the quiet mark", () => {
  deepStrictEqual(personPopupButtons({ muted: false, isHost: false }), [{ action: "mute", label: "Mute" }, { action: "report", label: "Report" }]);
  deepStrictEqual(personPopupButtons({ muted: true, isHost: false }), [{ action: "unmute", label: "Unmute" }, { action: "report", label: "Report" }]);
  deepStrictEqual(personPopupButtons({ muted: false, isHost: true }), [
    { action: "mute", label: "Mute" },
    { action: "report", label: "Report" },
    { action: "kick", label: "Kick" },
  ]);
  deepStrictEqual(personPopupButtons({ muted: true, isHost: true }).map((b) => b.label), ["Unmute", "Report", "Kick"]);
  strictEqual(mutedMark({ muted: false, blocked: false }), null);
  strictEqual(mutedMark({ muted: true, blocked: false }), "muted");
  strictEqual(mutedMark({ muted: true, blocked: true }), "blocked", "blocked wins");
  strictEqual(mutedMark({ muted: false, blocked: true }), "blocked", "a blocked person stays muted");
  strictEqual(mutedMarkText("muted"), " (muted in chat)");
  strictEqual(mutedMarkText("blocked"), " (blocked)");
  strictEqual(mutedMarkText(null), "");
  // No Hide / Block / Unblock button anywhere at the table (code only).
  const code = (f: string) =>
    readFileSync(f, "utf8")
      .replace(/\{\/\*[\s\S]*?\*\/\}/g, "")
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/(^|[^:])\/\/[^\n]*/g, "$1");
  for (const f of ["lib/personMenu.ts", "components/table/PersonMenu.tsx", "components/table/TableChat.tsx", "components/table/SpectatorsList.tsx"]) {
    strictEqual(/`(Hide|Unhide|Block|Unblock) \$\{|"(hide|unhide|block|unblock)"|Hidden:|>\s*(Block|Unblock|Remove)\s*</.test(code(f)), false, f);
  }
  // The popup: avatar and name, then the buttons, then Close -- in that order.
  const menu = readFileSync("components/table/PersonMenu.tsx", "utf8");
  const popup = menu.slice(menu.indexOf("export function PersonPopup"), menu.indexOf("export function MutedBadge"));
  const order = ['<Avatar name={person.name} url={avatarUrl} size="lg" />', '<h2 id="person-popup-name"', "personPopupButtons({ muted: mod.muted.has(person.userId), isHost: mod.isHost })", ">\n            Close\n"].map((s) => popup.indexOf(s));
  strictEqual(order.every((i, k) => i > 0 && (k === 0 || i > order[k - 1])), true, "avatar, name, buttons, Close");
  strictEqual(popup.includes('className="person-btn person-btn--large flex-1"'), true, "large gold-outlined buttons, side by side");
  strictEqual(popup.includes('className="about-dialog person-popup"'), true, "the spectator list's panel");
  strictEqual(popup.includes('className="join-choice__cancel"'), true, "Close is the list's text link");
  // Picking a button closes the popup first, then acts.
  strictEqual(/closePersonPopup\(\);\s*if \(b\.action === "mute"\) mod\.mute\(person\.userId, person\.name\);\s*else if \(b\.action === "unmute"\) mod\.unmute\(person\.userId\);\s*else if \(b\.action === "report"\) mod\.report\(person\.userId, person\.name\);\s*else mod\.kick\(person\.userId, person\.name\);/.test(popup), true);
  // Escape, Close and a tap outside close it; a native modal dialog (the top layer).
  strictEqual(popup.includes("d.showModal();"), true);
  strictEqual(/onCancel=\{\(e\) => \{[\s\S]{0,60}e\.preventDefault\(\);\s*closePersonPopup\(\);/.test(popup), true);
  strictEqual(popup.includes("if (e.target === ref.current) closePersonPopup();"), true);
  strictEqual(popup.includes("onClick={closePersonPopup}"), true);
  const css = readFileSync("app/globals.css", "utf8");
  strictEqual(/\.person-btn \{[^}]*min-height: 44px;[^}]*border: 2px solid var\(--brass\);[^}]*border-radius: 12px;/.test(css), true);
  strictEqual(css.includes(".person-badge--muted {") && css.includes(".person-badge--blocked {"), true);
  strictEqual(/\.person-badge--hidden|\.spectators-remove/.test(css), false);
});
check("person popup: the dropdown is gone -- no placement helpers, no menu items, no inline row menu", () => {
  const lib = readFileSync("lib/personMenu.ts", "utf8");
  strictEqual(/personMenuPlace|PERSON_MENU_WIDTH|personMenuItems|menuHeight/.test(lib), false);
  const menu = readFileSync("components/table/PersonMenu.tsx", "utf8");
  strictEqual(/PersonMenuButton|PersonMenuItems|OpenMenu|toggleMenu|zIndex: 66|role="menu"|document\.addEventListener/.test(menu), false);
  for (const f of ["components/table/TableChat.tsx", "components/table/SpectatorsList.tsx", "components/table/TableView.tsx"]) {
    strictEqual(/PersonMenuButton|PersonMenuItems|personMenuPlace/.test(readFileSync(f, "utf8")), false, f);
  }
});
check("person popup: never for my own seat, row or card, at a computer table, or without a person", () => {
  strictEqual(canOfferPersonMenu({ userId: "a", myUserId: "me", enabled: true }), true);
  strictEqual(canOfferPersonMenu({ userId: "me", myUserId: "me", enabled: true }), false, "my own plate / row / card");
  strictEqual(canOfferPersonMenu({ userId: "a", myUserId: "me", enabled: false }), false, "a computer table (and so a computer opponent)");
  strictEqual(canOfferPersonMenu({ userId: "", myUserId: "me", enabled: true }), false, "a Teams plate's shared name line");
  strictEqual(canOfferPersonMenu({ userId: "a", myUserId: null, enabled: true }), false, "signed out");
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("enabled: !!myUserId && !!table && !table.computer_level,"), true);
  strictEqual(view.includes("publishPersonModeration(personModeration);"), true);
  strictEqual(view.includes("useEffect(() => () => publishPersonModeration(null), []);"), true);
  // Kick: the host only, never a spectator, never anyone else.
  strictEqual(view.includes("const popupIsHost = !spectating && !!myUserId && hostId === myUserId;"), true);
  strictEqual(view.includes("isHost: popupIsHost,"), true);
  strictEqual(view.indexOf("const hostId =") < view.indexOf("const popupIsHost"), true);
  const menu = readFileSync("components/table/PersonMenu.tsx", "utf8");
  // Every opener draws its children unchanged (or nothing) when it can't offer the popup.
  strictEqual((menu.match(/if \(!mod \|\| !canOfferPersonMenu\(\{ userId, myUserId: mod\.myUserId, enabled: mod\.enabled \}\)\)/g) ?? []).length, 4, "the avatar, the name, the list's Mute and Report");
  strictEqual(menu.includes("return <>{children}</>;"), true);
  strictEqual(menu.includes("if (!moderation || !canOfferPersonMenu({ userId, myUserId: moderation.myUserId, enabled: moderation.enabled })) return;"), true, "openPersonPopup refuses too");
});
check("person popup: every seat's avatar and name opens it -- plates, top and side seats, square header and tags", () => {
  const band = readFileSync("components/table/OpponentBand.tsx", "utf8");
  strictEqual(band.includes('<PersonTap userId={seat.userId} name={seat.name} surface="seat">'), true);
  strictEqual(band.includes('<PersonName userId={seat.userId} name={seat.name} surface="seat" className="truncate">'), true);
  strictEqual(band.includes('<PersonTap userId={seat.userId} name={seat.name} surface="side">'), true);
  strictEqual(band.includes('as="p" className="side-seat__name"'), true, "the side seat's name stays a block <p>");
  const plates = readFileSync("components/table/ScoreStrip.tsx", "utf8");
  strictEqual(plates.includes('<PersonTap key={m.userId} userId={m.userId} name={m.name} surface="plate">'), true);
  strictEqual(plates.includes('userId={plate.members.length === 1 ? plate.members[0].userId : ""}'), true);
  const ring = readFileSync("components/table/SquareRing.tsx", "utf8");
  strictEqual(ring.includes('<PersonTap userId={seat.userId} name={seat.name} surface="tag">'), true);
  strictEqual(ring.includes('<PersonName userId={seat.userId} name={seat.name} surface="tag"'), true);
  const square = readFileSync("components/table/SquareTable.tsx", "utf8");
  strictEqual(square.includes('<PersonTap userId={opponent.userId ?? ""} name={opponent.name} surface="header">'), true);
  strictEqual(square.includes('sq="opp-name"'), true, "the name keeps its data-sq");
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual((view.match(/userId: squareOpponent\.user_id,\n\s*name: oppName,/g) ?? []).length, 2);
  strictEqual(view.includes("header: {\n            userId: top.userId,"), true);
  const css = readFileSync("app/globals.css", "utf8");
  strictEqual(/\.person-tap \{\s*position: relative;\s*display: inline-flex;\s*flex-shrink: 0;\s*\}/.test(css), true);
  strictEqual(/\.person-tap__hit \{\s*position: absolute;[\s\S]{0,80}width: 44px;\s*height: 44px;/.test(css), true);
  strictEqual(/\.person-badge \{\s*position: absolute;[\s\S]*?pointer-events: none;/.test(css), true);
  const menu = readFileSync("components/table/PersonMenu.tsx", "utf8");
  strictEqual((menu.match(/onClick=\{\(\) => openPersonPopup\(userId, name\)\}/g) ?? []).length, 2, "the avatar and the name");
  strictEqual(menu.includes('aria-haspopup="dialog"'), true);
  // The one popup is drawn by TableView, beside the spectator list.
  strictEqual((view.match(/<PersonPopup \/>/g) ?? []).length, 1);
  strictEqual(view.indexOf("<SpectatorsList") < view.indexOf("<PersonPopup />") && view.indexOf("<PersonPopup />") < view.indexOf("<AskDialog"), true);
});
check("eye list: each other person's row has [Mute/Unmute]; the host's also [Kick], replacing Remove", () => {
  const list = readFileSync("components/table/SpectatorsList.tsx", "utf8");
  const row = list.slice(list.indexOf("{spectators.map((s) => ("), list.indexOf("</ul>"));
  strictEqual(row.includes("<PersonMuteButton userId={s.userId} name={nameOf(s)} />"), true);
  strictEqual(row.indexOf("<PersonMuteButton") > row.indexOf("{nameOf(s)}</span>"), true, "after the name");
  strictEqual(row.indexOf("<PersonMuteButton") < row.indexOf("{canKick && ("), true, "Mute, then the host's Kick");
  strictEqual(/\{canKick && \(\s*<button[\s\S]*?onClick=\{\(\) => onAskKick\(s\.userId, nameOf\(s\)\)\}[\s\S]*?className="person-btn"[\s\S]*?aria-label=\{`Kick \$\{nameOf\(s\)\}`\}\s*>\s*Kick\s*<\/button>/.test(row), true);
  strictEqual(/>\s*Remove\s*<|`Remove |"Remove"/.test(row), false, "no Remove button left");
  strictEqual(row.includes("<PersonMark userId={s.userId}>"), true);
  // The confirm is TableView's one kick confirm (moderation M3), not the list's own.
  strictEqual(/Remove \{mode\.name\}|Removing\.\.\.|Kick \{mode\.name\}/.test(list), false);
  // The inline Mute: only for another person at a human table; Mute or Unmute by what I did.
  const menu = readFileSync("components/table/PersonMenu.tsx", "utf8");
  const mute = menu.slice(menu.indexOf("export function PersonMuteButton"), menu.indexOf("export function PersonMark"));
  strictEqual(mute.includes("if (!mod || !canOfferPersonMenu({ userId, myUserId: mod.myUserId, enabled: mod.enabled })) return null;"), true);
  strictEqual(mute.includes("onClick={() => (muted ? mod.unmute(userId) : mod.mute(userId, name))}"), true);
  strictEqual(mute.includes('{muted ? "Unmute" : "Mute"}'), true);
  strictEqual(/kick|Kick/.test(mute), false, "the list's Kick is the host's own button, never here");
  // A non-host sees no Kick: the button needs canKick, which is the host's only.
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("canKick={hostMayRemove}"), true);
});
check("person popup: the composer lists only the people at THIS table I muted, each with Unmute", () => {
  const roster = [
    { user_id: "me", nickname: "Me" },
    { user_id: "a", nickname: "Tester 1" },
    { user_id: "b", nickname: "  " },
    { user_id: "c", nickname: "Carl" },
    { user_id: "a", nickname: "Tester 1" },
  ];
  deepStrictEqual(mutedAtTable(roster, new Set(["a", "b", "me", "elsewhere"]), "me"), [
    { userId: "a", name: "Tester 1" },
    { userId: "b", name: "Unnamed player" },
  ]);
  deepStrictEqual(mutedAtTable(roster, new Set(["elsewhere"]), "me"), []);
  const menu = readFileSync("components/table/PersonMenu.tsx", "utf8");
  const line = menu.slice(menu.indexOf("export function MutedHereLine"));
  strictEqual(line.includes("if (here.length === 0) return null;"), true, "nothing when nobody here is muted");
  strictEqual(line.includes('<span className="text-zinc-600 dark:text-zinc-400">Muted:</span>'), true);
  strictEqual(line.includes("onClick={() => mod.unmute(p.userId)}"), true);
  strictEqual(line.includes("aria-label={`Unmute ${p.name}`}"), true);
  strictEqual(/>\s*Unmute\s*</.test(line), true);
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("below={<MutedHereLine roster={chatRoster} />}"), true);
  const chat = readFileSync("components/table/TableChat.tsx", "utf8");
  strictEqual(/<\/div>\s*\{below\}\s*<\/form>,/.test(chat), true);
  // Unmute: the stored list changes, so the muted set (and so NEW messages) follow at once.
  strictEqual(view.includes("if (myUserId && chatTableId) unmuteSender(myUserId, chatTableId, userId);"), true);
  strictEqual(view.includes('const mutedIds = useMemo(() => (mutedRaw ? mutedRaw.split(",") : []), [mutedRaw]);'), true);
});
// ---- Kick (moderation M3: lib/kicks.ts, docs/sql/moderation-m3-*.sql) ------
// Code only: comments may name the RPCs.
const m3CodeOnly = (src: string) => src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/[^\n]*/g, "$1");
check("kick: the confirm, the notice, the topic, and what a notice does on my screen", () => {
  deepStrictEqual(kickConfirm("Bo", { playerInLiveGame: true }), {
    title: "Kick Bo?",
    body: "This ends the current game for everyone.",
    yesLabel: "Kick",
    noLabel: "Cancel",
  });
  deepStrictEqual(kickConfirm("Bo", { playerInLiveGame: false }), { title: "Kick Bo?", body: "", yesLabel: "Kick", noLabel: "Cancel" });
  strictEqual(KICK_GAME_LINE, "This ends the current game for everyone.");
  const n = kickedNotice("Bo");
  strictEqual(`${n.title} ${n.body}`, "Bo was kicked from the table. Would you like to add them to your Block list?");
  strictEqual(n.yesLabel, "Yes, block");
  strictEqual(n.noLabel, "No, thanks");
  strictEqual(kickTopic("AAAAAAAA-1111-2222-3333-444444444444"), "kicks:aaaaaaaa-1111-2222-3333-444444444444");
  strictEqual(KICK_EVENT, "kick");
  const id = "aaaaaaaa-1111-2222-3333-444444444444";
  deepStrictEqual(parseKickNotice({ kicked_id: id, nickname: "  Bo ", at: 5, host_id: "x" }), { kickedId: id, nickname: "Bo", at: 5 });
  deepStrictEqual(parseKickNotice({ kicked_id: id, nickname: "" }), { kickedId: id, nickname: "A player", at: 0 });
  for (const bad of [null, "x", {}, { kicked_id: "nope" }, { kicked_id: id.toUpperCase() }]) strictEqual(parseKickNotice(bad), null);
  const notice = { kickedId: id, nickname: "Bo", at: 1_000_000_000 };
  const base = { notice, myUserId: "me", iAmHost: false, blocked: false, alreadyShown: false, openedAt: 1_000_000_000 };
  strictEqual(kickNoticeAction(base), "ask");
  strictEqual(kickNoticeAction({ ...base, myUserId: id }), "self", "I was kicked");
  strictEqual(kickNoticeAction({ ...base, myUserId: id, iAmHost: true }), "self");
  strictEqual(kickNoticeAction({ ...base, iAmHost: true }), "ignore", "the host gets their own question");
  strictEqual(kickNoticeAction({ ...base, blocked: true }), "ignore", "already blocked");
  strictEqual(kickNoticeAction({ ...base, alreadyShown: true }), "ignore", "once each");
  strictEqual(kickNoticeAction({ ...base, myUserId: null }), "ignore");
  strictEqual(kickNoticeAction({ ...base, openedAt: notice.at + 5 * 60 * 1000 + 1 }), "ignore", "older than this screen");
  strictEqual(kickNoticeAction({ ...base, openedAt: notice.at + 60 * 1000 }), "ask", "a little clock difference is fine");
  strictEqual(isKickRefusal({ message: "You can't join this table." }), true);
  strictEqual(isKickRefusal({ message: "This table has ended." }), false);
  strictEqual(isKickRefusal(null), false);
  for (const m of ["Only the host can kick.", "You can't kick yourself.", "You have kicked 20 people in the last hour. Please try again a little later."]) {
    strictEqual(kickFailureText({ message: m }), m);
  }
  strictEqual(kickFailureText({ message: "permission denied for function kick_player" }), KICK_FAILED_TEXT);
  const rows = recentKicksFromRows([
    { kicked_at: "2026-11-25T10:00:00Z", table_id: "t", table_code: "0412", host_nickname: "Ann", kicked_nickname: "Bo", kicked_role: "player", game_live: true },
    { kicked_at: "2026-11-25T09:00:00Z", table_id: "t", table_code: "0412", host_nickname: null, kicked_nickname: null, kicked_role: "absent", game_live: false },
    { nope: 1 },
  ]);
  deepStrictEqual(rows.map(recentKickLine), [
    "Table 0412: Ann kicked Bo (player, game ended)",
    "Table 0412: A deleted account kicked Unnamed player (had just left)",
  ]);
  deepStrictEqual(recentKicksFromRows(null), []);
});
check("kick: the placeholder is gone; every Kick asks the one confirm, then only writeKick (kick_player)", () => {
  for (const f of ["lib/personMenu.ts", "components/table/TableView.tsx", "components/table/PersonMenu.tsx"]) {
    strictEqual(/PLAYER_KICK_UNAVAILABLE|isn't available yet/.test(readFileSync(f, "utf8")), false, f);
  }
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  // The three openers all reach askKick.
  strictEqual(view.includes("kick: askKick,"), true, "the person popup");
  strictEqual(view.includes("onAskKick={askKick}"), true, "the spectator list");
  strictEqual(view.includes("onRemoveSpectator={hostMayRemove ? askKick : undefined}"), true, "a spectator's chat-card eye");
  const ask = view.slice(view.indexOf("const askKick = useCallback("), view.indexOf("const kickBusyRef"));
  strictEqual(ask.includes("if (!popupIsHost) return;"), true, "the host only");
  strictEqual(ask.includes("setKickAsk({ userId, name, playerInLiveGame: isPlayer && gameLive });"), true, "the game line for a player in a live game only");
  strictEqual(view.includes("const popupIsHost = !spectating && !!myUserId && hostId === myUserId;"), true, "never a spectator");
  // Yes: writeKick only; a failure shows its line and asks nothing; a real kick asks "Also block?".
  const yes = view.slice(view.indexOf("const confirmKick = useCallback("), view.indexOf("const declineKick"));
  strictEqual(yes.includes("const result = await writeKick(table.id, ask.userId);"), true);
  strictEqual(/playerRpc|supabase|\.rpc\(/.test(yes), false, "nothing but writeKick");
  strictEqual(/if \(!result\.ok\) \{\s*if \(spectatorsOpen\) setRemoveError\(result\.text\);\s*else setChatBlockNote\(result\.text\);\s*return;\s*\}/.test(yes), true);
  strictEqual(yes.indexOf("return;\n") < yes.indexOf("setBlockAsk"), true, "a failed kick never asks");
  strictEqual(yes.includes('if (result.outcome === "kicked" && shouldAskToBlock({ blocked: blockedIds.includes(ask.userId) })) {'), true);
  strictEqual(view.includes("onYes={() => void confirmKick()}") && view.includes("onNo={declineKick}"), true);
  // The old remove path is gone from the app; only lib/kicks.ts calls kick_player.
  const walk = (d: string): string[] =>
    readdirSync(d).flatMap((f) => {
      const p = `${d}/${f}`;
      return statSync(p).isDirectory() ? walk(p) : /\.(ts|tsx)$/.test(f) ? [p] : [];
    });
  for (const dir of ["app", "components", "lib"]) {
    for (const f of walk(dir)) {
      const src = m3CodeOnly(readFileSync(f, "utf8"));
      strictEqual(src.includes("remove_spectator"), false, `${f}: remove_spectator`);
      strictEqual(/table_kicks/.test(src), false, `${f}: nobody reads table_kicks`);
      if (f !== "lib/kicks.ts") strictEqual(/kick_player|admin_recent_kicks/.test(src), false, `${f}: only lib/kicks.ts calls the kick RPCs`);
    }
  }
  const lib = readFileSync("lib/kicks.ts", "utf8");
  strictEqual(lib.includes('supabase.rpc("kick_player", { p_table_id: tableId, p_target: userId })'), true);
  strictEqual(lib.includes('supabase.rpc("admin_recent_kicks", { p_limit: limit })'), true);
  // The spectator list no longer confirms by itself.
  const list = readFileSync("components/table/SpectatorsList.tsx", "utf8");
  strictEqual(/kind: "confirm"|onConfirmRemove|Kicking\.\.\.|SPECTATOR_REMOVE_CONFIRM/.test(list), false);
  strictEqual(list.includes('export type SpectatorsListMode = { kind: "list" };'), true);
  // AskDialog: an empty body draws no paragraph.
  strictEqual(readFileSync("components/brand/AskDialog.tsx", "utf8").includes('{body && <p id={bodyId} className="whitespace-pre-line">{body}</p>}'), true);
});
check("kick notice: one private channel, asked of everyone else once, queued, never for the host, the kicked or the blocking", () => {
  const hook = readFileSync("components/table/useTableKicks.ts", "utf8");
  strictEqual(hook.includes("const CHANNEL_CONFIG = { config: { private: true } };"), true);
  strictEqual(hook.includes("const topic = kickTopic(tableId);"), true);
  strictEqual(hook.includes('channel.on("broadcast", { event: KICK_EVENT }, ({ payload }) => {'), true);
  strictEqual(hook.includes("const notice = parseKickNotice(payload);"), true);
  strictEqual(/\.send\(|\.rpc\(/.test(m3CodeOnly(hook)), false, "it only listens");
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("useTableKicks({ enabled: chatOn, tableId: table?.id ?? null, onKick: handleKickNotice });"), true);
  const handle = view.slice(view.indexOf("const handleKickNotice = useCallback("), view.indexOf("useTableKicks({"));
  strictEqual(handle.includes("iAmHost: popupIsHost,"), true);
  strictEqual(handle.includes("blocked: blockedIds.includes(notice.kickedId),"), true);
  strictEqual(handle.includes("alreadyShown: shownKicksRef.current.has(notice.kickedId),"), true);
  strictEqual(handle.includes("openedAt: openedAtRef.current,"), true);
  strictEqual(view.includes("const kickNoticeShown = kickNotice && !blockAsk && !kickAsk && !popupOpen && !reportAsk && !reportSent ? kickNotice : null;"), true, "queued behind other questions, the popup and a report (M6)");
  strictEqual(view.includes("onYes={() => closeKickNotice(true)}") && view.includes("onNo={() => closeKickNotice(false)}"), true);
  strictEqual(/if \(block\) void blockFromQuestion\(first\.userId\);/.test(view), true, "Yes blocks through the same path");
  strictEqual(readFileSync("components/table/PersonMenu.tsx", "utf8").includes("export function usePersonPopupOpen(): boolean {"), true);
});
check("kicked person: \"The host removed you from this table.\" and home -- players too", () => {
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  const leave = view.slice(view.indexOf("const leaveAsKicked = useCallback("), view.indexOf("const checkTableEndedRef"));
  strictEqual(leave.includes("setLobbyNotice(REMOVED_TEXT);"), true);
  strictEqual(leave.includes('router.replace("/");'), true);
  strictEqual(leave.includes("if (kickedExitRef.current || leavingRef.current) return;"), true, "once, and never on my own Leave");
  const check = view.slice(view.indexOf("checkTableEndedRef.current = (tableId: string) => {"), view.indexOf("}, [spectating, code, playerRpc, leaveAsKicked]);"));
  strictEqual(/if \(data\.status === "open"\) \{\s*const \{ error: previewError \} = await previewById\(\);\s*if \(!leavingRef\.current && isKickRefusal\(previewError\)\) leaveAsKicked\(\);/.test(check), true, "seat gone, table open");
  strictEqual(/if \(isKickRefusal\(previewError\)\) \{\s*leaveAsKicked\(\);/.test(check), true, "seat gone, private table unreadable");
  strictEqual(view.includes("if (spectating) void spectateRef.current?.heartbeat();"), true, "a spectator: the heartbeat answers removed");
  strictEqual(view.includes("else if (table) checkTableEndedRef.current(table.id);"), true);
  strictEqual(REMOVED_TEXT, "The host removed you from this table.");
});
check("admin: Recent kicks, through admin_recent_kicks only", () => {
  const page = readFileSync("app/admin/page.tsx", "utf8");
  strictEqual(page.includes("<AdminRecentKicks />"), true);
  const ui = readFileSync("components/brand/AdminRecentKicks.tsx", "utf8");
  strictEqual(ui.includes("readRecentKicks(50).then((read) => {"), true);
  strictEqual(ui.includes("Recent kicks"), true);
  strictEqual(/supabase|\.rpc\(|\.from\(/.test(m3CodeOnly(ui)), false);
});
check("M3 SQL: kick_player's notice can't undo a kick; the files' md5s match their text; join/watch are M1's plus one (M3) block", () => {
  const p1 = readFileSync("docs/sql/moderation-m3-part1.sql", "utf8");
  const p2 = readFileSync("docs/sql/moderation-m3-part2.sql", "utf8");
  const m1p2 = readFileSync("docs/sql/moderation-m1-part2.sql", "utf8");
  const body = (src: string, name: string) => {
    const at = src.indexOf(`create or replace function public.${name}(`);
    const start = src.indexOf("as $$", at) + "as $$".length;
    return src.slice(start, src.indexOf("$$;", start));
  };
  const md5 = (s: string) => createHash("md5").update(s, "utf8").digest("hex");
  for (const [name, src] of [
    ["_is_kicked_from_table", p1], ["_send_kick_notice", p1], ["kick_player", p1], ["kick_topic_allows", p1], ["admin_recent_kicks", p1],
    ["join_table_by_code", p2], ["watch_table", p2],
  ] as const) {
    const lf = md5(body(src, name));
    const crlf = md5(body(src, name).replace(/\n/g, "\r\n"));
    strictEqual(new RegExp(`--   ${name}\\s+${lf} / ${crlf}`).test(src), true, `${name}: header md5`);
  }
  const kp = body(p1, "kick_player");
  strictEqual(/\n  begin\n    perform public\._send_kick_notice\(p_table_id, [^;]*\);\n  exception when others then\n    null;\n  end;\n\n  return 'kicked';\nend;\n$/.test(kp), true, "the send in its own subtransaction, last");
  strictEqual(kp.indexOf("perform public._send_kick_notice(") > kp.indexOf("insert into public.table_kicks"), true);
  strictEqual(kp.includes("perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('one_table:' || p_target::text, 0));"), true, "the target's person lock");
  strictEqual(kp.indexOf("from public.games g") < kp.indexOf("from public.tables t"), true, "games then tables, leave_table's order");
  strictEqual(kp.includes("if public.table_host(p_table_id) is distinct from v_actor then"), true);
  strictEqual(kp.includes("perform public._attempts_guard(v_actor, 'kick', 20, interval '1 hour',"), true);
  strictEqual(kp.indexOf("return 'already_kicked';") < kp.indexOf("_attempts_guard"), true, "a no-op counts nothing");
  strictEqual(body(p1, "_send_kick_notice").includes("perform realtime.send(p_payload, 'kick', 'kicks:' || p_table_id::text, true);"), true);
  // Grants and the table: least privilege.
  for (const role of ["public", "anon", "authenticated", "service_role"]) strictEqual(p1.includes(`revoke all on table public.table_kicks from ${role};`), true, role);
  strictEqual(/grant [a-z, ]+ on table public\.table_kicks/.test(p1), false, "no table grants");
  strictEqual(p1.includes("alter table public.table_kicks enable row level security;"), true);
  for (const fn of ["kick_player(uuid, uuid)", "kick_topic_allows(text)", "admin_recent_kicks(integer)"]) {
    strictEqual(p1.includes(`grant execute on function public.${fn} to authenticated;`), true, fn);
  }
  for (const fn of ["_is_kicked_from_table(uuid, uuid)", "_send_kick_notice(uuid, jsonb)"]) {
    strictEqual(p1.includes(`grant execute on function public.${fn}`), false, `${fn}: internal`);
  }
  strictEqual(p1.includes("'game_start', 'follow_change', 'block_change', 'kick'));"), true, "nine actions");
  strictEqual(p1.includes('create policy "table kicks: people at the table receive"'), true);
  strictEqual(/create policy[^\n]*\n\s*on realtime\.messages\n\s*for insert/.test(p1), false, "no insert policy");
  strictEqual(/chat/i.test(p1.match(/create policy "[^"]*"/g)?.join() ?? ""), false, "no \"chat\" in the policy's name");
  // join/watch: M1 part 2's bodies plus exactly the (M3) block.
  const strip = (s: string) => s.replace(/  -- ===== \(M3\)[\s\S]*?\(M3\) CHANGED FOR MODERATION M3, KICK \(end\) =====\n(\n)?/, "");
  strictEqual(strip(body(p2, "join_table_by_code")), body(m1p2, "join_table_by_code"));
  strictEqual(strip(body(p2, "watch_table")).replace(/\n\n  -- ===== \(M1\)/, "\n  -- ===== (M1)"), body(m1p2, "watch_table").replace(/\n\n  -- ===== \(M1\)/, "\n  -- ===== (M1)"));
  strictEqual((body(p2, "join_table_by_code").match(/raise exception 'You can''t join this table\.';/g) ?? []).length, 2, "M1's and M3's refusal");
  // The verification's verdicts and the state-aware suites.
  const v = readFileSync("docs/sql/moderation-m3-verification.sql", "utf8");
  strictEqual(v.includes("v_expect := 17 + (case when v_live then 2 else 0 end) + (case when v_p2 then 7 else 0 end);"), true);
  strictEqual((v.match(/v_checks := v_checks \+ 1;/g) ?? []).length, 26);
  strictEqual(v.includes("raise exception 'm3 verification: the notice fails on purpose';"), true, "C12 makes the send fail");
  // (Moderation M6 put a ten-action branch in front of M3's nine.)
  strictEqual(readFileSync("docs/sql/slice-e-attempt-log-cleanup-verification.sql", "utf8").includes("v_want := (case when to_regclass('public.player_reports') is not null then 10\n                  when to_regclass('public.table_kicks') is not null then 9"), true);
  strictEqual(readFileSync("docs/sql/slice-e-grants-verification.sql", "utf8").includes("v_expected_fns := v_expected_fns || array['admin_recent_kicks', 'kick_player', 'kick_topic_allows'];"), true);
  for (const f of ["spectator-chat-verification", "table-chat-verification", "spectator-chat-precheck", "moderation-catalog"]) {
    strictEqual(readFileSync(`docs/sql/${f}.sql`, "utf8").includes("table kicks: people at the table receive"), true, f);
  }
  for (const f of ["precheck", "part1", "part1-rollback", "part2", "part2-rollback", "verification"]) {
    const raw = readFileSync(`docs/sql/moderation-m3-${f}.sql`).toString("latin1");
    strictEqual(/(?<!\r)\n/.test(raw), false, `${f}: a bare LF`);
  }
});
check("block question: Walt's words after a Mute, skipped when already blocked, closing is No, only writeBlockById", () => {
  deepStrictEqual(blockQuestion("Elsa"), {
    title: "Also block Elsa?",
    body: 'Blocked players can\'t join or watch tables you start, and you won\'t see their chat anywhere. You can review or remove anyone later on your Profile page under "Blocked players."',
    yesLabel: "Yes, block",
    noLabel: "No, thanks",
  });
  strictEqual(shouldAskToBlock({ blocked: false }), true);
  strictEqual(shouldAskToBlock({ blocked: true }), false, "already blocked: no question");
  strictEqual(readFileSync("components/brand/BlockedPlayers.tsx", "utf8").includes("Blocked players"), true, "the Profile heading the body names");
  strictEqual(chatBlockFailureText("blocked"), null);
  strictEqual(chatBlockFailureText("already_blocked"), null);
  strictEqual(chatBlockFailureText("limit"), BLOCK_LIMIT_TEXT);
  strictEqual(chatBlockFailureText("rate_limited"), BLOCK_RATE_TEXT);
  strictEqual(chatBlockFailureText("not_allowed"), BLOCK_NOT_ALLOWED_TEXT);
  strictEqual(chatBlockFailureText("not_found"), BLOCK_FAILED_TEXT);
  strictEqual(chatBlockFailureText("error"), BLOCK_FAILED_TEXT);
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  // Mute applies first (stored, then their messages dropped), then the question -- unless blocked.
  const mute = view.slice(view.indexOf("const muteInChat = useCallback("), view.indexOf("const unmuteInChat = useCallback("));
  const order = [
    "muteSender(myUserId, chatTableId, userId);",
    "dropChatSender(userId);",
    "if (shouldAskToBlock({ blocked: blockedIds.includes(userId) })) setBlockAsk({ userId, name });",
  ].map((s) => mute.indexOf(s));
  strictEqual(order.every((i, k) => i > 0 && (k === 0 || i > order[k - 1])), true, "mute, drop, then ask");
  const unmute = view.slice(view.indexOf("const unmuteInChat = useCallback("), view.indexOf("const blockFromQuestion = useCallback("));
  strictEqual(unmute.includes("setBlockAsk"), false, "never after Unmute");
  // Yes: only writeBlockById (through lib/blocks.ts), a refusal in the error line, then the list re-read.
  const yes = view.slice(view.indexOf("const blockFromQuestion = useCallback("), view.indexOf("const declineBlockAsk = useCallback("));
  strictEqual(yes.includes("const outcome = await writeBlockById(userId);"), true);
  strictEqual(yes.includes("if (ask) void blockFromQuestion(ask.userId);"), true);
  strictEqual(yes.includes("setChatBlockNote(failure);"), true);
  strictEqual(yes.includes("void reloadBlocks();"), true);
  strictEqual(yes.includes("unmuteSender"), false, "the Mute stays");
  strictEqual(view.includes("const declineBlockAsk = useCallback(() => setBlockAsk(null), []);"), true, "No: just closes, the Mute stays");
  strictEqual((view.match(/\bwriteBlockById\(/g) ?? []).length, 1);
  strictEqual(/\bwriteBlock\(|writeUnblock|unblockMessage|window\.confirm\(chat|chatBlockConfirmText/.test(view), false, "no other block path at the table");
  strictEqual(/\.rpc\(\s*["'](block_player|block_player_by_id|unblock_player|get_my_blocks)/.test(view), false);
  strictEqual(view.includes("onYes={() => void confirmBlockAsk()}") && view.includes("onNo={declineBlockAsk}"), true);
  strictEqual(view.indexOf("<AskDialog") > view.indexOf("<SpectatorsList"), true);
  // The dialog: reusable, native, modal (above the eye list's dialog), closing is No.
  const dialog = readFileSync("components/brand/AskDialog.tsx", "utf8");
  strictEqual(dialog.includes("if (open && !d.open) {\n      d.showModal();"), true);
  strictEqual(/onCancel=\{\(e\) => \{[\s\S]{0,60}e\.preventDefault\(\);\s*onNo\(\);/.test(dialog), true, "Escape is No");
  strictEqual(dialog.includes("if (e.target === ref.current) onNo();"), true, "a tap outside is No");
  strictEqual(dialog.includes("if (openRef.current) onNo();"), true);
  strictEqual(dialog.includes("onClick={onYes}"), true);
  strictEqual((dialog.replace(/\/\/[^\n]*/g, "").match(/onYes/g) ?? []).length, 3, "only the yes button says yes");
  strictEqual(dialog.includes("createPortal("), true);
  strictEqual(/window\.confirm|supabase|lib\/blocks/.test(dialog.replace(/\/\/[^\n]*/g, "")), false);
  // Nothing else at the table calls the server for blocks.
  for (const f of [
    "components/table/PersonMenu.tsx",
    "components/table/TableChat.tsx",
    "components/table/SpectatorsList.tsx",
    "components/table/OpponentBand.tsx",
    "components/table/ScoreStrip.tsx",
    "components/table/SquareRing.tsx",
    "components/table/SquareTable.tsx",
    "components/brand/AskDialog.tsx",
    "lib/personMenu.ts",
    "lib/chatMute.ts",
  ]) {
    const src = readFileSync(f, "utf8").replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/[^\n]*/g, "$1");
    strictEqual(/supabase|\.rpc\(|lib\/blocks|writeBlock|writeUnblock|block_player|unblock_player/.test(src), false, f);
  }
  // The Profile page keeps Block by exact nickname, and Unblock.
  const profile = readFileSync("components/brand/BlockedPlayers.tsx", "utf8");
  strictEqual(profile.includes("writeBlock(typed)"), true);
  strictEqual(profile.includes("writeBlockById"), false);
  const lib = readFileSync("lib/blocks.ts", "utf8");
  strictEqual(lib.includes('supabase.rpc("block_player_by_id", { p_target: userId })'), true);
  strictEqual(lib.includes("chatBlockConfirmText"), false);
});
check("M2 SQL: block_player_by_id is add-only and authenticated-only; the suites expect 53", () => {
  const part1 = readFileSync("docs/sql/moderation-m2-part1.sql", "utf8");
  const code = part1.split("\n").filter((l) => !l.trim().startsWith("--")).join("\n");
  strictEqual((code.match(/create or replace function public\.([a-z_]+)/g) ?? []).join(), "create or replace function public.block_player_by_id");
  for (const role of ["public", "anon", "service_role", "authenticated"]) {
    strictEqual(code.includes(`revoke all on function public.block_player_by_id(uuid) from ${role};`), true, role);
  }
  strictEqual(code.includes("grant execute on function public.block_player_by_id(uuid) to authenticated;"), true);
  strictEqual(code.includes("pg_catalog.hashtextextended('blocks:' || v_actor::text, 0)"), true, "block_player's lock key");
  strictEqual(code.includes("perform public._attempts_guard(v_actor, 'block_change', 30, interval '1 hour',"), true);
  strictEqual(/\b(alter|drop) (table|function)\b/.test(code), false, "add-only");
  const verification = readFileSync("docs/sql/moderation-m2-verification.sql", "utf8");
  strictEqual((verification.match(/v_checks := v_checks \+ 1;/g) ?? []).length, 17);
  strictEqual(verification.includes("if v_checks <> 17 then"), true);
  const grants = readFileSync("docs/sql/slice-e-grants-verification.sql", "utf8");
  strictEqual(grants.includes("v_expected_fns := v_expected_fns || array['block_player_by_id'];"), true);
  for (const f of ["precheck", "part1", "part1-rollback", "verification"]) {
    const raw = readFileSync(`docs/sql/moderation-m2-${f}.sql`).toString("latin1");
    strictEqual(/(?<!\r)\n/.test(raw), false, `${f}: a bare LF`);
  }
});

// ---- Hand calculator (lib/handBreakdown.ts) --------------------------------
const H = (cards: string, starter: string, crib = false) => handBreakdown(cards.split(" "), starter, crib);
const lineOf = (b: HandBreakdown, category: string) => b.lines.find((l) => l.category === category);
const sym = (b: HandBreakdown, category: string) =>
  (lineOf(b, category)?.combos ?? []).map((c) => comboText(c, suitSymbol));
check("calculator: the 29 -- three fives and the right jack, the fourth five cut", () => {
  const b = H("5H 5D 5C JS", "5S");
  strictEqual(b.total, 29);
  deepStrictEqual(b.lines.map((l) => [l.label, l.points]), [["Fifteens", 16], ["Pairs", 12], ["Nobs", 1]]);
  strictEqual(lineOf(b, "fifteens")!.combos.length, 8);
  strictEqual(lineOf(b, "pairs")!.combos.length, 6);
  deepStrictEqual(sym(b, "nobs"), ["J♠+5♠"]);
});
check("calculator: a 0 hand has no lines", () => {
  const b = H("2C 4D 6S 8H", "TC");
  strictEqual(b.total, 0);
  deepStrictEqual(b.lines, []);
});
check("calculator: 28 -- four of a kind (six pairs) and the fifteens", () => {
  const b = H("5H 5D 5C 5S", "JD");
  strictEqual(b.total, 28);
  deepStrictEqual(b.lines.map((l) => [l.label, l.points, l.combos.length]), [["Fifteens", 16, 8], ["Pairs", 12, 6]]);
});
check("calculator: runs are one category -- each run listed with its own cards, pairs on their own line", () => {
  const show = (b: HandBreakdown) => b.lines.filter((l) => l.category === "runs" || l.category === "pairs").map((l) => [l.label, l.points, l.combos.length]);
  // 3-4-4-5: two runs of 3 (one with each 4) = Runs 6, and the pair of 4s = Pairs 2. Never "double run".
  let b = H("3H 4D 4S 5C", "KD");
  deepStrictEqual(show(b), [["Pairs", 2, 1], ["Runs", 6, 2]]);
  deepStrictEqual(sym(b, "runs"), ["3♥+4♦+5♣", "3♥+4♠+5♣"]);
  // 3-4-4-4-5: three runs of 3 = Runs 9; three of a kind = 3 pairs = Pairs 6.
  b = H("3H 4D 4C 4S", "5D");
  deepStrictEqual(show(b), [["Pairs", 6, 3], ["Runs", 9, 3]]);
  // 3-3-4-4-5: four runs of 3 = Runs 12; two pairs = Pairs 4.
  b = H("3H 3D 4C 4S", "5D");
  deepStrictEqual(show(b), [["Pairs", 4, 2], ["Runs", 12, 4]]);
  // A run of 4 and a run of 5: one run each, worth its length.
  b = H("3H 4D 5C 6S", "KD");
  deepStrictEqual(show(b), [["Runs", 4, 1]]);
  deepStrictEqual(sym(b, "runs"), ["3♥+4♦+5♣+6♠"]);
  b = H("AH 2D 3C 4S", "5D");
  deepStrictEqual(show(b), [["Runs", 5, 1]]);
  deepStrictEqual(sym(b, "runs"), ["A♥+2♦+3♣+4♠+5♦"]);
  // 3-4-5-6-6: two runs of 4 = Runs 8, Pairs 2.
  b = H("3H 4D 5C 6S", "6D");
  deepStrictEqual(show(b), [["Pairs", 2, 1], ["Runs", 8, 2]]);
  // A run ending at the king.
  deepStrictEqual(show(H("JH QD KC 2S", "4D")), [["Runs", 3, 1]]);
  // Only the five category names, ever.
  strictEqual(
    [b, H("5H 5D 5C JS", "5S"), H("2H 4H 6H 8H", "TH")].every((x) =>
      x.lines.every((l) => ["Fifteens", "Pairs", "Runs", "Flush", "Nobs"].includes(l.label))
    ),
    true
  );
});
check("calculator: 4-card vs 5-card flush, and a crib's 4-card flush scores 0", () => {
  deepStrictEqual(lineOf(H("2H 4H 6H 8H", "TC"), "flush"), {
    category: "flush", label: "Flush", points: 4, combos: [["2H", "4H", "6H", "8H"]],
  });
  strictEqual(lineOf(H("2H 4H 6H 8H", "TH"), "flush")!.points, 5);
  strictEqual(lineOf(H("2H 4H 6H 8H", "TH"), "flush")!.combos[0].length, 5);
  strictEqual(lineOf(H("2H 4H 6H 8H", "TC", true), "flush"), undefined);
  strictEqual(H("2H 4H 6H 8H", "TC", true).total, 0);
  strictEqual(lineOf(H("2H 4H 6H 8H", "TH", true), "flush")!.points, 5);
});
check("calculator: nobs is the hand's jack of the starter's suit; a jack starter is not nobs", () => {
  const b = H("JH 2C 4D 6S", "8H");
  deepStrictEqual(lineOf(b, "nobs"), { category: "nobs", label: "Nobs", points: 1, combos: [["JH", "8H"]] });
  strictEqual(lineOf(H("2C 4D 6S 8H", "JH"), "nobs"), undefined);
});
check("calculator: card names for screen readers", () => {
  strictEqual(cardName("AC"), "Ace of clubs");
  strictEqual(cardName("TD"), "Ten of diamonds");
  strictEqual(cardName("QH"), "Queen of hearts");
  strictEqual(cardName("7S"), "Seven of spades");
});
check("calculator: 40,000 random deals -- the pieces add up to scoreHand, as a hand and as a crib", () => {
  let seed = 20261112;
  const rand = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
  const deck = ["S", "H", "D", "C"].flatMap((s) => ["A", "2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K"].map((r) => r + s));
  for (let n = 0; n < 20000; n++) {
    const pick: string[] = [];
    while (pick.length < 5) {
      const card = deck[Math.floor(rand() * 52)];
      if (!pick.includes(card)) pick.push(card);
    }
    for (const crib of [false, true]) {
      const hand = pick.slice(0, 4);
      const want = scoreHand(hand, pick[4], crib);
      const got = handBreakdown(hand, pick[4], crib);
      strictEqual(got.total, want.points, pick.join(" "));
      strictEqual(got.lines.reduce((sum, l) => sum + l.points, 0), want.points, pick.join(" "));
      const pts = (c: string) => lineOf(got, c)?.points ?? 0;
      const count = (c: string) => lineOf(got, c)?.combos.length ?? 0;
      strictEqual(count("fifteens") * 2, want.fifteens, `fifteens ${pick.join(" ")}`);
      strictEqual(count("pairs") * 2, want.pairs, `pairs ${pick.join(" ")}`);
      const runs = lineOf(got, "runs");
      strictEqual(runs ? runs.combos.length * runs.combos[0].length : 0, want.runs, `runs ${pick.join(" ")}`);
      strictEqual(lineOf(got, "flush")?.combos[0].length ?? 0, want.flush, `flush ${pick.join(" ")}`);
      strictEqual(pts("nobs"), want.nobs);
      strictEqual(got.lines.every((l) => l.points > 0), true);
      strictEqual(got.lines.every((l) => ["Fifteens", "Pairs", "Runs", "Flush", "Nobs"].includes(l.label)), true);
    }
  }
});

// TABLE CHAT (PRD item 39): lib/tableChat.ts, and the hook and UI around it.
check("chat: the topic is chat:<table>:<sender>, both ids lowercased", () => {
  const t = "1B4E28BA-2FA1-11D2-883F-0016D3CCA427";
  const u = "6ec0bd7f-11c0-43da-975e-2a8ad9ebae0b";
  strictEqual(chatTopic(t, u), "chat:1b4e28ba-2fa1-11d2-883f-0016d3cca427:6ec0bd7f-11c0-43da-975e-2a8ad9ebae0b");
  strictEqual(chatSenderId(chatTopic(t, u), t), u);
  strictEqual(chatSenderId("realtime:" + chatTopic(t, u), t), u);
  strictEqual(chatSenderId(chatTopic(t, u), u), null); // another table
  strictEqual(chatSenderId(chatTopic(t, u) + "x", t), null);
  strictEqual(chatSenderId("chat:not-a-uuid:" + u, t), null);
});
check("chat: cleanChatText trims, folds line breaks, strips controls, cuts to 140", () => {
  const nl = String.fromCharCode(10);
  const cr = String.fromCharCode(13);
  const ls = String.fromCharCode(0x2028);
  const rlo = String.fromCharCode(0x202e);
  strictEqual(cleanChatText("  hello  "), "hello");
  strictEqual(cleanChatText(`one${cr}${nl}${nl}  two${ls}three`), "one two three");
  strictEqual(cleanChatText(`a${String.fromCharCode(0)}b${String.fromCharCode(7)}c${String.fromCharCode(9)}d${String.fromCharCode(0x7f)}e`), "abcde");
  strictEqual(cleanChatText(`gg ${rlo}wp`), "gg wp");
  strictEqual(cleanChatText("x".repeat(200))?.length, 140);
  strictEqual(CHAT_MAX_LENGTH, 140);
  // Emoji count as one character each, and are never cut in half.
  const emoji = String.fromCodePoint(0x1f0cf);
  strictEqual(Array.from(cleanChatText(emoji.repeat(150)) ?? "").length, 140);
  strictEqual(cleanChatText(`${"y".repeat(139)} z`), "y".repeat(139)); // cut, then trimmed
  for (const bad of [null, undefined, 42, {}, ["hi"], "", "   ", `${nl}${nl}`, String.fromCharCode(0)]) {
    strictEqual(cleanChatText(bad), null, JSON.stringify(bad));
  }
  // Markup stays plain text (React draws it as text, never as HTML).
  strictEqual(cleanChatText("<b>hi</b> https://x.y"), "<b>hi</b> https://x.y");
});
check("chat: the throttle allows 1 per 2 s and 3 per 10 s", () => {
  const t = createChatThrottle();
  strictEqual(t.take(0), true);
  strictEqual(t.take(1999), false); // inside 2 s
  strictEqual(t.take(2000), true);
  strictEqual(t.take(4000), true);
  strictEqual(t.take(6000), false); // a 4th inside 10 s
  strictEqual(t.take(9999), false);
  strictEqual(t.take(10000), true); // the first has aged out
  strictEqual(chatThrottleAllows([], 0), true);
  strictEqual(chatThrottleAllows([0, 2500, 5000], 7600), false);
  strictEqual(chatThrottleAllows([0, 2500, 5000], 10001), true);
});
check("chat: the receiving throttle counts each sender apart and drops extras", () => {
  const r = createPerSenderThrottle();
  strictEqual(r.take("a", 0), true);
  strictEqual(r.take("b", 0), true);
  strictEqual(r.take("a", 500), false);
  strictEqual(r.take("b", 2000), true);
  strictEqual(r.take("a", 2000), true);
});
check("chat: newest first, memory capped, at most CHAT_MAX_CARDS cards and +N more", () => {
  let list: ChatMessage[] = [];
  for (let i = 0; i < CHAT_MEMORY + 5; i++) {
    list = addChatMessage(list, { id: `m${i}`, senderId: "s", name: "N", avatarUrl: null, text: `t${i}`, at: i });
  }
  strictEqual(list.length, CHAT_MEMORY);
  strictEqual(list[0].id, `m${CHAT_MEMORY + 4}`);
  const v = visibleChatCards(list);
  strictEqual(v.shown.length, CHAT_MAX_CARDS);
  strictEqual(v.more, CHAT_MEMORY - CHAT_MAX_CARDS);
  deepStrictEqual(visibleChatCards(list.slice(0, 2)), { shown: list.slice(0, 2), more: 0 });
});
check("chat: up to 5 of the others' cards stack; the room still wins; +N more beyond", () => {
  strictEqual(CHAT_MAX_CARDS, 5);
  const msgs = (n: number) => Array.from({ length: n }, (_, i) => ({ id: `m${i}`, senderId: "s", name: "Elsa", avatarUrl: null, text: "x", at: i }));
  // Room for everything: 5 show, the 6th and 7th are "+2 more".
  deepStrictEqual(visibleChatCards(msgs(5)), { shown: msgs(5), more: 0 });
  deepStrictEqual(chatStackCounts(msgs(7), 99), { shown: 5, folded: false, more: 2 });
  deepStrictEqual(chatStackCounts(msgs(5), 5), { shown: 5, folded: false, more: 0 });
  // The room holds fewer: those show, the rest are "+N more"; a fold only at 0.
  deepStrictEqual(chatStackCounts(msgs(5), 3), { shown: 3, folded: false, more: 2 });
  deepStrictEqual(chatStackCounts(msgs(5), 1), { shown: 1, folded: false, more: 4 });
  deepStrictEqual(chatStackCounts(msgs(5), 0), { shown: 0, folded: true, more: 5 });
  // The stack starts by trying them all and measures down from there.
  const ui = readFileSync("components/table/TableChat.tsx", "utf8");
  strictEqual(ui.includes("useState(CHAT_MAX_CARDS)"), true);
  strictEqual(ui.includes("const candidates = visibleChatCards(messages).shown;"), true);
  // "Close all" still from 2 of the others' messages.
  strictEqual(ui.includes("{messages.length >= 2 && ("), true);
});
check("chat: nothing reads a sender name or id from the message payload", () => {
  const sources = ["components/table/useTableChat.ts", "components/table/TableChat.tsx", "lib/tableChat.ts"].map((f) =>
    readFileSync(f, "utf8")
  );
  const hook = sources[0];
  for (const src of sources) {
    for (const bad of [/payload\??\.(name|nickname|sender|senderId|sender_id|user|userId|user_id|avatar|avatarUrl|avatar_url|id)\b/, /payload\s*as\s*\{[^}]*(name|sender|user|avatar)/]) {
      strictEqual(bad.test(src), false, `${bad} in chat code`);
    }
  }
  // The only field read from a payload is text, and the sender is the
  // channel's own player, looked up in the roster.
  strictEqual(hook.includes("(payload as { text?: unknown }).text"), true);
  strictEqual(hook.includes("rosterRef.current.find((m) => m.user_id === senderId)"), true);
  strictEqual(hook.includes("payload: { text }"), true); // what is sent
  strictEqual(hook.includes("private: true, broadcast: { self: false, ack: true }"), true);
  strictEqual(hook.includes("supabase.realtime.setAuth()"), true);
  // The table page never passes a computer table or an unseated player.
  const page = readFileSync("components/table/TableView.tsx", "utf8");
  for (const needle of ['table.status === "open"', "!table.computer_level", "members.some((m) => m.user_id === session.user.id)", "messages={chat.messages}"]) {
    strictEqual(page.includes(needle), true, needle);
  }
  // Text is drawn as text: no HTML injection anywhere in the chat UI.
  strictEqual(sources[1].includes("dangerouslySetInnerHTML"), false);
});

// The fold bug (3-player test, Nov 14): after a player left, the amber
// "game was ended" banner's Dismiss counted as a control at the very top
// of the middle, so the room came out as 0 and every message folded -- on
// both screens -- with the fold line in the banner's row.
check("chat: the banner never folds the stack; the cards go below it; the waiting room has the whole middle", () => {
  const middle = { top: 100, bottom: 700 }; // 600 tall
  const banner = { top: 100, bottom: 140 };
  const dismiss = { top: 104, bottom: 136 };
  const seat = { top: 150, bottom: 190 }; // a waiting-room seat button
  // The waiting room: below the banner, all the rest, controls or not.
  let room = chatStackRoom({ middle, notices: [banner], controls: [dismiss, seat], mode: "full", expanded: false });
  deepStrictEqual(room, { top: 144, budget: 552, limit: 552 });
  // No banner: from the middle's top.
  room = chatStackRoom({ middle, notices: [], controls: [seat], mode: "full", expanded: false });
  strictEqual(room.top, 100);
  strictEqual(room.budget, 596);
  strictEqual(room.limit, 596);
  // In a game, the banner's own Dismiss (above the cards' top) is never in
  // the way: half the middle, the newest card down to the middle's bottom.
  room = chatStackRoom({ middle, notices: [banner], controls: [dismiss], mode: "game", expanded: false });
  deepStrictEqual(room, { top: 144, budget: 300, limit: 552 });
  // A real control lower down limits the room (Next Hand at 260).
  room = chatStackRoom({ middle, notices: [], controls: [{ top: 260, bottom: 300 }], mode: "game", expanded: false });
  deepStrictEqual(room, { top: 100, budget: 156, limit: 156 });
  // Only a control right at the cards' top leaves truly no room: that folds.
  room = chatStackRoom({ middle, notices: [], controls: [{ top: 102, bottom: 140 }], mode: "game", expanded: false });
  strictEqual(room.budget, 0);
  strictEqual(room.limit, 0);
  // A control below the half still stops the newest card (it once ran on
  // over Confirm Count at 320 px).
  room = chatStackRoom({ middle, notices: [], controls: [{ top: 420, bottom: 460 }], mode: "game", expanded: false });
  deepStrictEqual(room, { top: 100, budget: 300, limit: 316 });
  // The banner never pushes the cards past the middle's bottom.
  room = chatStackRoom({ middle: { top: 100, bottom: 300 }, notices: [{ top: 100, bottom: 240 }], controls: [], mode: "game", expanded: false });
  deepStrictEqual(room, { top: 244, budget: 52, limit: 52 });
  // Show tapped: the half, controls or not.
  room = chatStackRoom({ middle, notices: [], controls: [{ top: 102, bottom: 140 }], mode: "game", expanded: true });
  strictEqual(room.budget, 300);
  strictEqual(room.limit, 596);
  // The table page marks the banner and gives the waiting room the whole
  // middle; the stack skips a notice's controls.
  const page = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(/<div data-table-notice="" [^>]*>\s*<span>\{gameEndedNotice\}/.test(page), true, "banner marked");
  strictEqual(page.includes('const chatRoom: "game" | "full" = inWaitingRoom || (!activeGame && !finishedGame) ? "full" : "game";'), true);
  strictEqual(page.includes("room={chatRoom}"), true);
  const ui = readFileSync("components/table/TableChat.tsx", "utf8");
  strictEqual(ui.includes('middle.querySelectorAll("[data-table-notice]")'), true);
  strictEqual(ui.includes("if (notices.some((n) => n.contains(control))) continue;"), true);
});

// Stacking (same test): the cards were drawn behind the crib and the starter
// that hang over the top of the middle (.sq-opponent-row, z 5, over the
// middle's z 4). Now they are a layer on <body>, above every table z-index.
check("chat: the cards are a layer above every table element, below the deal and the composer", () => {
  const ui = readFileSync("components/table/TableChat.tsx", "utf8");
  const stack = ui.slice(ui.indexOf("export function ChatStack"), ui.indexOf("export function ChatAnnouncer"));
  strictEqual(/createPortal\(\s*<div\s+ref=\{stackRef\}/.test(stack), true, "the stack is a portal");
  strictEqual(stack.includes("document.body"), true);
  strictEqual(stack.includes("chat-stack pointer-events-none fixed"), true);
  strictEqual(stack.includes("style={{ zIndex: CHAT_LAYER_Z }}"), true);
  // Every z-index the table draws with, in the CSS and the table's
  // components: all below the chat layer, except the few meant to be above
  // it -- the deal overlay, the header buttons over it, the counts menu, the
  // composer.
  const above = new Map([
    [".deal-overlay", 60],
    [".sound-toggle", 61],
    ["CountsToggle menu", 62],
    ["composer", 70],
  ]);
  const sources = [
    readFileSync("app/globals.css", "utf8"),
    readFileSync("components/table/TableView.tsx", "utf8"),
    ...readdirSync("components/table")
      .filter((f) => f.endsWith(".tsx") && f !== "TableChat.tsx")
      .map((f) => readFileSync(`components/table/${f}`, "utf8")),
  ];
  const allowed = new Set(above.values());
  for (const src of sources) {
    for (const m of src.matchAll(/z-index:\s*(\d+)|\bz-\[(\d+)\]|\bz-(\d+)\b/g)) {
      const z = Number(m[1] ?? m[2] ?? m[3]);
      if (allowed.has(z)) continue;
      strictEqual(z < CHAT_LAYER_Z, true, `z ${z} (${m[0]}) is not below the chat layer`);
    }
  }
  const css = readFileSync("app/globals.css", "utf8");
  strictEqual(/\.deal-overlay \{[^}]*z-index: 60;/.test(css), true);
  strictEqual(CHAT_LAYER_Z > 40 && CHAT_LAYER_Z < 60, true); // over the splash, under the deal
  strictEqual(ui.includes("z-[70]"), true); // the composer
  // The deal still hides the cards (they no longer sit inside .sq-dealing).
  strictEqual(/body:has\(\.sq-dealing\) \.chat-stack \{\s*visibility: hidden;/.test(css), true);
  // Rounded: cards like the app's panels (12px), pills fully round.
  strictEqual(stack.includes("chat-card pointer-events-auto flex items-start gap-2 rounded-xl"), true);
  strictEqual(stack.includes("rounded-full"), true);
  strictEqual(stack.includes("h-11 w-11"), true); // the x: 44px
});

// MY OWN MESSAGE, ECHOED (Walt: "you see what you sent").
check("chat: my own message becomes a card only after an OK ack", () => {
  const me = { nickname: "Walt", avatar_url: "https://x/walt.png" };
  const card = ownChatCard({ result: "ok", text: "gg", me, myUserId: "u1", now: 5000, id: "own-1" });
  deepStrictEqual(card, { id: "own-1", senderId: "u1", name: "Walt", avatarUrl: "https://x/walt.png", text: "gg", at: 5000, spectator: false });
  // A failed or throttled send: "Couldn't send" / "Slow down", and no card.
  strictEqual(ownChatCard({ result: "failed", text: "gg", me, myUserId: "u1", now: 5000, id: "x" }), null);
  strictEqual(ownChatCard({ result: "throttled", text: "gg", me, myUserId: "u1", now: 5000, id: "x" }), null);
  strictEqual(ownChatCard({ result: "ok", text: null, me, myUserId: "u1", now: 5000, id: "x" }), null);
  strictEqual(ownChatCard({ result: "ok", text: "hi", me: undefined, myUserId: "u1", now: 0, id: "x" })?.name, "Unnamed player");
  // The hook makes the card from the ack's result, after the send.
  const hook = readFileSync("components/table/useTableChat.ts", "utf8").replace(/\r\n/g, "\n");
  const send = hook.slice(hook.indexOf("const send = useCallback"), hook.indexOf("const dismiss = useCallback"));
  strictEqual(send.includes('const result: ChatSendResult = ack === "ok" ? "ok" : "failed";'), true);
  strictEqual(send.indexOf("await channel.send(") < send.indexOf("ownChatCard({"), true);
  strictEqual(send.includes("if (card) setOwn(card);"), true);
  strictEqual(send.includes("setMessages"), false); // never one of the others' messages
  const ui = readFileSync("components/table/TableChat.tsx", "utf8");
  strictEqual(ui.includes(`{note === "throttled" ? "Slow down" : "Couldn't send"}`), true);
});
check("chat: my own card goes by itself at 2 s, fading over the last 0.3 s", () => {
  strictEqual(OWN_CARD_MS, 2000);
  strictEqual(OWN_CARD_FADE_MS, 300);
  const own = { id: "o", senderId: "u1", name: "Walt", avatarUrl: null, text: "gg", at: 1000 };
  strictEqual(ownCardShowing(own, 1000), true);
  strictEqual(ownCardShowing(own, 2999), true);
  strictEqual(ownCardShowing(own, 3000), false);
  strictEqual(ownCardShowing(null, 0), false);
  const hook = readFileSync("components/table/useTableChat.ts", "utf8");
  strictEqual(hook.includes("setOwn((cur) => (cur?.id === own.id ? null : cur)), OWN_CARD_MS);"), true);
  const ui = readFileSync("components/table/TableChat.tsx", "utf8");
  strictEqual(ui.includes('"--own-fade-delay": `${OWN_CARD_MS - OWN_CARD_FADE_MS}ms`'), true);
  const css = readFileSync("app/globals.css", "utf8");
  strictEqual(/chat-own-out var\(--own-fade\) ease-in var\(--own-fade-delay\) forwards/.test(css), true);
  // It fades only with motion allowed (inside the no-preference block).
  const block = css.slice(css.lastIndexOf("@media (prefers-reduced-motion: no-preference)", css.indexOf(".chat-card--own {")), css.indexOf(".chat-card--own {"));
  strictEqual(block.length > 0 && block.length < 80, true);
});
check("chat: my own card is never counted in the fold or +N more, and never pushes a card out", () => {
  const msgs = Array.from({ length: 5 }, (_, i) => ({ id: `m${i}`, senderId: "s", name: "Elsa", avatarUrl: null, text: "x", at: i }));
  deepStrictEqual(chatStackCounts([], 3), { shown: 0, folded: false, more: 0 }); // only my own card: no fold
  deepStrictEqual(chatStackCounts(msgs, 2), { shown: 2, folded: false, more: 3 });
  deepStrictEqual(chatStackCounts(msgs, 0), { shown: 0, folded: true, more: 5 });
  deepStrictEqual(chatStackCounts(msgs.slice(0, 1), 3), { shown: 1, folded: false, more: 0 });
  const ui = readFileSync("components/table/TableChat.tsx", "utf8");
  const stack = ui.slice(ui.indexOf("export function ChatStack"), ui.indexOf("export function ChatAnnouncer"));
  strictEqual(stack.includes("const { shown, folded, more } = chatStackCounts(messages, fit);"), true);
  // The others' fit is measured without my card; mine shows only if it
  // fits below the limit with them, else not at all (no fold, no push).
  strictEqual(stack.includes('stack.querySelectorAll<HTMLElement>("[data-chat-card]:not([data-chat-own])")'), true);
  strictEqual(stack.includes("setOwnFits(!ownCard || used + ownCard.offsetHeight + STACK_GAP <= place.limit);"), true);
  strictEqual(stack.includes("hidden={!ownFits}"), true);
  // One at a time: the hook holds a single own message, replaced by the next.
  const hook = readFileSync("components/table/useTableChat.ts", "utf8");
  strictEqual(hook.includes("useState<ChatMessage | null>(null)"), true);
});
check("chat: my own message is never announced to the screen reader", () => {
  const page = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(page.includes("<ChatAnnouncer newest={chat.messages[0]} />"), true);
  strictEqual(page.includes("own={chat.own}"), true);
  strictEqual((page.match(/chat\.own\b/g) ?? []).length, 1); // only to the stack
  const ui = readFileSync("components/table/TableChat.tsx", "utf8");
  const announcer = ui.slice(ui.indexOf("export function ChatAnnouncer"));
  strictEqual(announcer.includes("own"), false);
});

// ---- Reports (moderation M6, docs/sql/moderation-m6-part1.sql) ----
check("reports: the popup's buttons are Mute/Unmute, Report, then the host's Kick; Report opens the dialog", () => {
  deepStrictEqual(personPopupButtons({ muted: false, isHost: false }).map((b) => b.label), ["Mute", "Report"]);
  deepStrictEqual(personPopupButtons({ muted: true, isHost: false }).map((b) => b.label), ["Unmute", "Report"]);
  deepStrictEqual(personPopupButtons({ muted: false, isHost: true }).map((b) => b.action), ["mute", "report", "kick"]);
  deepStrictEqual(personPopupButtons({ muted: true, isHost: true }).map((b) => b.label), ["Unmute", "Report", "Kick"]);
  // Shown only where the popup is: another real person at a human table.
  strictEqual(canOfferPersonMenu({ userId: "a", myUserId: "a", enabled: true }), false, "never my own");
  strictEqual(canOfferPersonMenu({ userId: "a", myUserId: "b", enabled: false }), false, "never at a computer table");
  strictEqual(canOfferPersonMenu({ userId: "a", myUserId: "b", enabled: true }), true);
  const menu = readFileSync("components/table/PersonMenu.tsx", "utf8");
  const popup = menu.slice(menu.indexOf("export function PersonPopup"), menu.indexOf("export function MutedBadge"));
  strictEqual(/closePersonPopup\(\);\s*if \(b\.action === "mute"\)[^\n]*\n\s*else if \(b\.action === "unmute"\)[^\n]*\n\s*else if \(b\.action === "report"\) mod\.report\(person\.userId, person\.name\);\s*else mod\.kick\(person\.userId, person\.name\);/.test(popup), true, "close first, then Report");
  strictEqual(popup.includes('className="flex w-full flex-wrap gap-2"'), true, "three buttons wrap on a narrow phone instead of overlapping");
  // A chat sender who has left has no roster entry: the avatar falls back
  // to the initial (null url) and Report needs only the id.
  strictEqual(popup.includes("mod?.people.find((p) => p.user_id === person.userId)?.avatar_url ?? null"), true);
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("report: askReport,"), true);
  strictEqual(/const askReport = useCallback\(\(userId: string, name: string\) => \{\s*setReportAsk\(\{ userId, name \}\);\s*\}, \[\]\);/.test(view), true, "Report only opens the dialog");
  // Computer tables: the store is off there, so no Report at all.
  strictEqual(view.includes("enabled: !!myUserId && !!table && !table.computer_level,"), true);
});
check("reports: the eye list's row buttons are Mute/Unmute, Report, then the host's Kick, wrapping on a narrow phone", () => {
  deepStrictEqual(spectatorRowButtons({ muted: false, isHost: false }), ["mute", "report"]);
  deepStrictEqual(spectatorRowButtons({ muted: true, isHost: true }), ["unmute", "report", "kick"]);
  const list = readFileSync("components/table/SpectatorsList.tsx", "utf8");
  const row = list.slice(list.indexOf("{spectators.map((s) => ("), list.indexOf("</ul>"));
  const at = ["{nameOf(s)}</span>", "<PersonMuteButton", "<PersonReportButton userId={s.userId} name={nameOf(s)} />", "{canKick && ("].map((s) => row.indexOf(s));
  strictEqual(at.every((i, k) => i > 0 && (k === 0 || i > at[k - 1])), true, "name, Mute, Report, Kick");
  strictEqual(row.includes('className="flex min-h-11 flex-wrap items-center gap-x-2 gap-y-1"'), true);
  strictEqual(row.includes('className="min-w-20 flex-1 truncate font-semibold"'), true, "the name keeps 5rem; the buttons wrap below");
  strictEqual(row.includes('<span className="ml-auto flex shrink-0 gap-1">'), true);
  const menu = readFileSync("components/table/PersonMenu.tsx", "utf8");
  const btn = menu.slice(menu.indexOf("export function PersonReportButton"), menu.indexOf("export function PersonMark"));
  strictEqual(btn.includes("if (!mod || !canOfferPersonMenu({ userId, myUserId: mod.myUserId, enabled: mod.enabled })) return null;"), true, "never my own row, never a computer table");
  strictEqual(btn.includes('className="person-btn"'), true, "the same 44px button as Mute and Kick");
  strictEqual(btn.includes("onClick={() => mod.report(userId, name)}"), true);
  strictEqual(/supabase|\.rpc\(/.test(m3CodeOnly(btn)), false);
});
check("reports: the dialog's words, the outcome lines, and the block question after a report", () => {
  deepStrictEqual(REPORT_REASONS.map((r) => `${r.reason}:${r.label}`), ["nickname:Offensive nickname", "picture:Offensive picture", "behavior:Behavior at this table"]);
  strictEqual(reportTitle("Bo"), "Report Bo");
  strictEqual(REPORT_QUESTION, "What's the problem?");
  strictEqual(REPORT_NOTE_PLACEHOLDER, "Add details (optional, 200 characters)");
  strictEqual(REPORT_CHOOSE_TEXT, "Choose what's wrong.");
  strictEqual(REPORT_NOTE_MAX, 200);
  strictEqual(showNoteCounter(149), false);
  strictEqual(showNoteCounter(150), true);
  // The outcomes.
  strictEqual(reportOutcomeText("reported", "Bo"), null);
  strictEqual(reportOutcomeText("already_reported", "Bo"), "You already reported Bo today.");
  strictEqual(reportOutcomeText("limit", "Bo"), "You've sent a lot of reports. Try again a little later.");
  strictEqual(reportOutcomeText("not_found", "Bo"), "That player isn't there anymore.");
  strictEqual(reportOutcomeText("not_allowed", "Bo"), "You can't report this player.");
  strictEqual(reportFailureText({ message: "Unknown report reason." }), "Unknown report reason.");
  strictEqual(reportFailureText({ message: "You must be logged in to report a player." }), "You must be logged in to report a player.");
  strictEqual(reportFailureText({ message: 'relation "player_reports" does not exist' }), "Couldn't send your report. Try again.", "never raw database text");
  strictEqual(reportFailureText(null), "Couldn't send your report. Try again.");
  // The note as sent.
  strictEqual(reportNote("   "), null);
  strictEqual(reportNote("  hi  "), "hi");
  strictEqual(reportNote("x".repeat(250))?.length, 200);
  // After "reported": the block question unless already blocked.
  strictEqual(afterReportStep({ blocked: false }), "ask_block");
  strictEqual(afterReportStep({ blocked: true }), "sent_notice");
  const q = reportedBlockQuestion("Bo");
  const b = blockQuestion("Bo");
  strictEqual(q.title, "Report sent");
  strictEqual(q.body.startsWith("We'll take a look.\n\n"), true, "first line");
  strictEqual(q.body.includes(b.title) && q.body.endsWith(b.body), true, "the same question and Block List explanation");
  strictEqual(q.yesLabel, "Yes, block");
  strictEqual(q.noLabel, "No, thanks");
  deepStrictEqual(reportSentNotice(), { title: "Report sent", body: "We'll take a look.", yesLabel: "", noLabel: "OK" });
  // AskDialog: an empty yes label draws only the OK button; blank lines are paragraphs.
  const dialog = readFileSync("components/brand/AskDialog.tsx", "utf8");
  strictEqual(/\{yesLabel && \(\s*<button type="button" onClick=\{onYes\} className="peg-btn peg-btn--brass">/.test(dialog), true);
  strictEqual(dialog.includes('{body && <p id={bodyId} className="whitespace-pre-line">{body}</p>}'), true);
});
check("reports: the dialog -- choose first, Sending... once, 200 characters, Cancel sends nothing, never calls the server", () => {
  const ui = readFileSync("components/table/ReportDialog.tsx", "utf8");
  const order = ["<h2", "{reportTitle(name)}", "{REPORT_QUESTION}", "REPORT_REASONS.map", "<textarea", "{message && (", 'type="submit" className="peg-btn peg-btn--brass"', 'className="join-choice__cancel"'].map((s) => ui.indexOf(s));
  strictEqual(order.every((i, k) => i > 0 && (k === 0 || i > order[k - 1])), true, "heading, question, choices, note, line, Send, Cancel");
  strictEqual(ui.includes("maxLength={REPORT_NOTE_MAX}"), true);
  strictEqual(ui.includes("placeholder={REPORT_NOTE_PLACEHOLDER}"), true);
  strictEqual(ui.includes('type="radio"'), true);
  strictEqual(/if \(sendingRef\.current\) return;\s*if \(!reason\) \{\s*setMessage\(REPORT_CHOOSE_TEXT\);\s*return;\s*\}/.test(ui), true, "no reason: the message, the dialog stays");
  strictEqual(/\sdisabled[=\s>]/.test(ui), false, "Send is never disabled or hidden (aria-disabled only while sending)");
  strictEqual(ui.includes("{sending ? REPORT_SENDING_LABEL : REPORT_SEND_LABEL}"), true);
  strictEqual(ui.includes("if (line) setMessage(line);"), true, "a refusal stays in the dialog with the form");
  strictEqual(ui.includes("d.showModal();"), true);
  strictEqual(/onCancel=\{\(e\) => \{[\s\S]{0,60}e\.preventDefault\(\);\s*onClose\(\);/.test(ui), true, "Escape is Cancel");
  strictEqual(ui.includes("if (e.target === ref.current) onClose();"), true);
  strictEqual(ui.includes('className="about-dialog report-dialog"'), true);
  strictEqual(ui.includes("createPortal("), true);
  strictEqual(/supabase|\.rpc\(|writeReport|dangerouslySetInnerHTML/.test(m3CodeOnly(ui)), false);
});
check("reports: report_player only through lib/reports.ts with the table's id; nobody touches player_reports; nothing broadcast", () => {
  const lib = readFileSync("lib/reports.ts", "utf8");
  strictEqual(/supabase\.rpc\("report_player", \{\s*p_target: input\.targetId,\s*p_reason: input\.reason,\s*p_note: reportNote\(input\.note\),\s*p_table_id: input\.tableId,\s*\}\)/.test(lib), true);
  strictEqual(lib.includes('supabase.rpc("admin_list_reports", { p_limit: limit })'), true);
  strictEqual(lib.includes('supabase.rpc("admin_delete_report", { p_id: id })'), true);
  strictEqual(/\.from\(|\.channel\(|\.send\(|realtime/.test(m3CodeOnly(lib)), false, "RPCs only; no table, no channel");
  const walk = (d: string): string[] =>
    readdirSync(d).flatMap((f) => {
      const p = `${d}/${f}`;
      return statSync(p).isDirectory() ? walk(p) : /\.(ts|tsx)$/.test(f) ? [p] : [];
    });
  for (const dir of ["app", "components", "lib"]) {
    for (const f of walk(dir)) {
      const src = m3CodeOnly(readFileSync(f, "utf8"));
      strictEqual(/player_reports/.test(src), false, `${f}: nobody touches player_reports`);
      if (f !== "lib/reports.ts") strictEqual(/report_player|admin_list_reports|admin_delete_report|purge_old_reports/.test(src), false, `${f}: only lib/reports.ts calls the report RPCs`);
    }
  }
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  const send = view.slice(view.indexOf("const sendReport = useCallback("), view.indexOf("const closeReport = useCallback("));
  strictEqual(send.includes("const result = await writeReport({ targetId: ask.userId, reason, note, tableId: tableIdForReport });"), true);
  strictEqual(view.includes("const tableIdForReport = table?.id ?? null;"), true);
  strictEqual(/if \(!result\.ok\) return result\.text;\s*const line = reportOutcomeText\(result\.outcome, ask\.name\);\s*if \(line\) return line;\s*setReportAsk\(null\);/.test(send), true, "only reported closes the dialog");
  strictEqual(send.includes('if (afterReportStep({ blocked: blockedIds.includes(ask.userId) }) === "ask_block") {'), true);
  strictEqual(send.includes("setBlockAsk({ userId: ask.userId, name: ask.name, afterReport: true });"), true);
  strictEqual(send.includes("setReportSent(true);"), true);
  strictEqual(/muteSender|dropChatSender|writeBlock|kick|\.send\(|channel/i.test(send), false, "nothing automatic: no mute, block, kick or broadcast");
  // Yes, block after a report is the same block-by-id path as after a Mute or a Kick.
  strictEqual(view.includes("const blockAskText = blockAsk ? (blockAsk.afterReport ? reportedBlockQuestion(blockAsk.name) : blockQuestion(blockAsk.name)) : null;"), true);
  strictEqual((view.match(/\bwriteBlockById\(/g) ?? []).length, 1);
  strictEqual(view.includes("<ReportDialog target={reportAsk} onSend={sendReport} onClose={closeReport} />"), true);
  strictEqual(/yesLabel=""\s*noLabel=\{reportSentText\?\.noLabel \?\? ""\}/.test(view), true, "Report sent with OK only");
  // The kick notice waits while the report dialog or its answer is open.
  strictEqual(view.includes("!popupOpen && !reportAsk && !reportSent ? kickNotice : null"), true);
  // The header's "..." menu is untouched: no report there.
  strictEqual(/Report/.test(readFileSync("components/table/CountsToggle.tsx", "utf8").replace(/\/\/[^\n]*/g, "")), false);
});
check("reports: the admin list -- plain-text note, counts, picture flag, Delete asks first, the 90-day line", () => {
  const rows = adminReportsFromRows([
    {
      id: "r1", created_at: "2026-11-25T10:00:00Z", reason: "picture", note: "line one\n\n  line two", table_code: "0412",
      reporter_nickname: "Ann", reporter_nickname_now: "Ann", reported_nickname: "Bo", reported_nickname_now: "Bobby",
      reported_avatar_url: "https://x/a.png", picture_changed: true, reporter_report_count: 1, reported_report_count: 3,
    },
    { id: 5 },
  ]);
  strictEqual(rows.length, 1);
  strictEqual(rows[0].pictureChanged, true);
  strictEqual(reportReasonWords("nickname"), "Offensive nickname");
  strictEqual(reportReasonWords("picture"), "Offensive picture");
  strictEqual(reportReasonWords("behavior"), "Behavior");
  deepStrictEqual(nicknameThenNow("Bo", "Bobby"), { name: "Bo", now: "Bobby" });
  deepStrictEqual(nicknameThenNow("Ann", "Ann"), { name: "Ann", now: null });
  deepStrictEqual(nicknameThenNow("Cy", null), { name: "Cy", now: null }, "a deleted account");
  strictEqual(noteOneLine("line one\n\n  line two"), "line one line two");
  strictEqual(countLine(1, "filed"), "1 report filed by this person");
  strictEqual(countLine(3, "against"), "3 reports against this person");
  strictEqual(REPORTS_AUTO_DELETE_TEXT, "Reports are deleted automatically after 90 days.");
  strictEqual(REPORTS_EMPTY_TEXT, "No reports.");
  deepStrictEqual(REPORT_DELETE_QUESTION, { title: "Delete this report?", body: "", yesLabel: "Delete", noLabel: "Cancel" });
  const ui = readFileSync("components/brand/AdminReports.tsx", "utf8");
  strictEqual(/dangerouslySetInnerHTML|innerHTML/.test(ui), false, "never HTML");
  strictEqual(ui.includes("&ldquo;{note}&rdquo;"), true, "the note as a text node");
  strictEqual(ui.includes("const note = noteOneLine(r.note);"), true);
  strictEqual(ui.includes("readReports(100)"), true);
  strictEqual(ui.includes("{REPORTS_AUTO_DELETE_TEXT}"), true);
  strictEqual(ui.includes("picture changed since report"), true);
  strictEqual(/onDelete=\{\(\) => setDeleteAsk\(r\.id\)\}/.test(ui), true, "Delete asks first");
  strictEqual(/const result = await deleteReport\(id\);[\s\S]{0,160}setReports\(\(list\) => \(list \? list\.filter\(\(r\) => r\.id !== id\) : list\)\);/.test(ui), true);
  strictEqual(/supabase|\.rpc\(/.test(m3CodeOnly(ui)), false);
  for (const f of ["lib/reports.ts", "components/table/ReportDialog.tsx", "components/brand/AdminReports.tsx"]) {
    strictEqual(readFileSync(f, "utf8").includes("dangerouslySetInnerHTML"), false, f);
  }
  const page = readFileSync("app/admin/page.tsx", "utf8");
  strictEqual(page.indexOf("<AdminRecentKicks />") > 0 && page.indexOf("<AdminReports />") > page.indexOf("<AdminRecentKicks />"), true, "after Recent kicks");
});
// ---- Table events (moderation M5a, docs/sql/moderation-m5a-part1.sql) ----
check("table events: the topic, the payload, and the version rule (> for members/spectators, >= for table)", () => {
  const T = "6f1c2d3e-4a5b-4c6d-8e7f-90a1b2c3d4e5";
  strictEqual(tableEventTopic(T.toUpperCase()), `table:${T}`);
  deepStrictEqual(parseTableEvent({ event: "members", table_id: T, roster_version: 4 }, T), { kind: "members", tableId: T, rosterVersion: 4 });
  deepStrictEqual(parseTableEvent({ event: "table", table_id: T, roster_version: 7, id: "x" }, T), { kind: "table", tableId: T, rosterVersion: 7 }, "Realtime's own id is ignored");
  strictEqual(parseTableEvent({ event: "members", table_id: T, roster_version: 4 }, "00000000-0000-4000-8000-000000000000"), null, "another table");
  strictEqual(parseTableEvent({ event: "chat", table_id: T, roster_version: 4 }, T), null, "an unknown kind");
  strictEqual(parseTableEvent({ event: "members", table_id: T, roster_version: -1 }, T), null);
  strictEqual(parseTableEvent({ event: "members", table_id: T, roster_version: 1.5 }, T), null);
  strictEqual(parseTableEvent({ event: "members", table_id: T }, T), null);
  strictEqual(parseTableEvent(null, T), null);
  const ev = (kind: TableEvent["kind"], v: number): TableEvent => ({ kind, tableId: T, rosterVersion: v });
  // The first event is always taken.
  deepStrictEqual(acceptTableEvent(null, ev("members", 3)), { accept: true, lastSeen: 3 });
  deepStrictEqual(acceptTableEvent(null, ev("table", 3)), { accept: true, lastSeen: 3 });
  // members / spectators: strictly newer only (each bumps the version).
  deepStrictEqual(acceptTableEvent(3, ev("members", 4)), { accept: true, lastSeen: 4 });
  deepStrictEqual(acceptTableEvent(4, ev("members", 4)), { accept: false, lastSeen: 4 }, "a duplicate");
  deepStrictEqual(acceptTableEvent(4, ev("spectators", 2)), { accept: false, lastSeen: 4 }, "out of order");
  // table: carries the current version without bumping, so the same number counts.
  deepStrictEqual(acceptTableEvent(4, ev("table", 4)), { accept: true, lastSeen: 4 });
  deepStrictEqual(acceptTableEvent(4, ev("table", 3)), { accept: false, lastSeen: 4 }, "an older table event");
  deepStrictEqual(acceptTableEvent(4, ev("table", 6)), { accept: true, lastSeen: 6 });
  // A sequence: a seat, a table end at that version, a duplicate, a spectator.
  let seen: number | null = null;
  const taken: string[] = [];
  for (const e of [ev("members", 5), ev("table", 5), ev("members", 5), ev("spectators", 6), ev("members", 4)]) {
    const step = acceptTableEvent(seen, e);
    seen = step.lastSeen;
    if (step.accept) taken.push(`${e.kind}:${e.rosterVersion}`);
  }
  deepStrictEqual(taken, ["members:5", "table:5", "spectators:6"]);
});
check("table events: joined only once my place is confirmed, again when it changes; quiet on refusal; the poll and old listeners unchanged", () => {
  strictEqual(tableEventRole({ available: false, spectating: false }), null);
  strictEqual(tableEventRole({ available: false, spectating: true }), null);
  strictEqual(tableEventRole({ available: true, spectating: false }), "player");
  strictEqual(tableEventRole({ available: true, spectating: true }), "spectator");
  const hook = readFileSync("components/table/useTableEvents.ts", "utf8");
  const code = m3CodeOnly(hook);
  strictEqual(code.includes("const CHANNEL_CONFIG = { config: { private: true } };"), true, "private");
  strictEqual(/await supabase\.realtime\.setAuth\(\);\s*const \{ data \} = await supabase\.auth\.getSession\(\);\s*if \(cancelled \|\| !data\.session\) return;/.test(code), true, "the kick channel's token handling");
  strictEqual(code.includes("if (!role || !tableId) return;"), true, "no place, no channel");
  strictEqual(code.includes("}, [role, tableId]);"), true, "a new place joins again");
  strictEqual(code.includes("if (channel) void supabase.removeChannel(channel).catch(() => null);"), true, "removed on leave / unmount");
  strictEqual(/\.send\(|\.rpc\(|\.from\(/.test(code), false, "it only listens");
  strictEqual(/catch \{\s*\}/.test(code) || code.includes("} catch {"), true, "a refused join stays quiet");
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  strictEqual(view.includes("role: tableEventRole({ available: tableEventsOn, spectating }),"), true, "chat's rule: the seat or spectator row is confirmed (computer tables too, M5b1)");
  const handler = m3CodeOnly(view.slice(view.indexOf("const handleTableEvent = useCallback("), view.indexOf("useTableEvents({")));
  strictEqual(handler.includes("void loadMembers(tableId);"), true);
  strictEqual(handler.includes("await loadSpectators(tableId);"), true);
  strictEqual(handler.includes("checkTableEndedRef.current(tableId);"), true);
  strictEqual(/supabase|\.from\(|\.rpc\(/.test(handler), false, "no second data path: only the poll's own reads");
  // The old listeners and the safety poll are untouched.
  strictEqual((view.match(/"postgres_changes"/g) ?? []).length, 7);
  strictEqual(view.includes("const delay = nextPollDelayMs({ connected: realtimeConnected, disconnectedPolls, random: Math.random() });"), true);
  // Chat is untouched.
  strictEqual(/table:|tableEvent/.test(readFileSync("components/table/useTableChat.ts", "utf8")), false);
});
check("table events: overlapping spectator reads -- an older read that finishes last never overwrites a newer one", () => {
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  const load = view.slice(view.indexOf("const loadSpectators = useCallback("), view.indexOf("// A full refresh, counted while in flight"));
  strictEqual(load.includes("const ticket = ++spectatorsReadSeqRef.current;"), true, "each read takes a ticket before it is sent");
  strictEqual(/const list = await readTableSpectators\(tableId\);\s*if \(!list \|\| ticket < spectatorsAppliedSeqRef\.current\) return;\s*spectatorsAppliedSeqRef\.current = ticket;\s*setSpectatorList\(list\);/.test(load), true);
  // The rule itself, on the fast Watch -> Leave order: the Leave read (2,
  // empty, one round trip) lands first; the Watch read (1, with a person,
  // two round trips) lands last and is dropped.
  let applied = 0;
  let shown: string[] = ["(before)"];
  const land = (ticket: number, list: string[] | null) => {
    if (!list || ticket < applied) return;
    applied = ticket;
    shown = list;
  };
  land(2, []);
  land(1, ["Tester 1"]);
  deepStrictEqual(shown, []);
  // In order, both apply; a failed newer read keeps the older result.
  applied = 0;
  land(1, ["Tester 1"]);
  land(2, null);
  deepStrictEqual(shown, ["Tester 1"]);
});
check("watching: Leave (or the page going away) stops for good -- no heartbeat or rewatch after it, and a watch in flight is waited for", () => {
  // Which table to stop: a late "in" from a watch in flight wins; else the ticket's.
  strictEqual(tableToStopWatching("t1", null), "t1");
  strictEqual(tableToStopWatching(null, { ok: { tableId: "t2" } }), "t2", "the place the late watch just made");
  strictEqual(tableToStopWatching("t1", { ok: { tableId: "t1" } }), "t1");
  strictEqual(tableToStopWatching(null, { refused: "no" }), null);
  strictEqual(tableToStopWatching(null, { closed: true }), null);
  strictEqual(tableToStopWatching(null, null), null, "never watched: nothing to stop");
  const page = m3CodeOnly(readFileSync("app/watch/[code]/page.tsx", "utf8"));
  // Every watch_table goes through trackedWatch, so a stop can wait for it.
  strictEqual((page.match(/\bcallWatchTable\(/g) ?? []).length, 1, "only inside trackedWatch");
  strictEqual(/const call = callWatchTable\(watchCode, tableId\);\s*watchInFlightRef\.current = call;/.test(page), true);
  // The stop: wait for a watch in flight, then stop_watching for its table (or the ticket's).
  strictEqual(/const pending = watchInFlightRef\.current;\s*const late = pending \? await pending\.catch\(\(\) => null\) : null;\s*const tableId = tableToStopWatching\(ticketRef\.current\?\.tableId \?\? null, late\);\s*if \(tableId\) await callStopWatching\(tableId\)\.catch\(\(\) => \{\}\);/.test(page), true);
  // Leave: the flag FIRST, then the stop, then home -- in that order.
  const stop = page.slice(page.indexOf("onStop: () => {"), page.indexOf("[heartbeat, onLiveGame, leave, watchingTableId, stopWatchingAfterPending]"));
  const order = ["if (exitedRef.current || stopRequestedRef.current) return;", "stopRequestedRef.current = true;", "void stopWatchingAfterPending().then(() => leave({ kind: \"home\", text: null }));"].map((x) => stop.indexOf(x));
  strictEqual(order.every((i, k) => i >= 0 && (k === 0 || i > order[k - 1])), true, "flag, stop, then home");
  // After the flag nothing watches again: the first watch and its retries,
  // the quiet rewatch, the heartbeat (and its answer), following a new game.
  strictEqual(/if \(stopRequestedRef\.current\) return;\s*const result = await trackedWatch\(code, held\);\s*if \(cancelled \|\| stopRequestedRef\.current\) return;/.test(page), true);
  strictEqual(/const rewatch = useCallback\(async \(\) => \{\s*if \(stopRequestedRef\.current \|\| exitedRef\.current\) return;/.test(page), true);
  strictEqual(/const again = await trackedWatch\([^;]*\);\s*if \(stopRequestedRef\.current\) return;/.test(page), true, "a late rewatch answer changes nothing");
  strictEqual(page.includes('if (stopRequestedRef.current || step.kind === "continue") return;'), true, "a not_watching after the stop never rewatches");
  strictEqual(page.includes("if (!ticket || exitedRef.current || stopRequestedRef.current || !followGame(ticket.gameId, gameId)) return;"), true);
  // The page going away (Back, a link): the same stop, once; the dev double mount resets the flag.
  strictEqual(/useEffect\(\(\) => \{\s*stopRequestedRef\.current = false;\s*return \(\) => \{\s*if \(stopRequestedRef\.current\) return;\s*stopRequestedRef\.current = true;\s*void stopWatchingAfterPending\(\);\s*\};\s*\}, \[stopWatchingAfterPending\]\);/.test(page), true);
  // stop_watching only through the stop.
  strictEqual((page.match(/\bcallStopWatching\(/g) ?? []).length, 1);
});
// ---- Game events and the stale-plays fix (moderation M5b1) ----
check("game events: the payload, exactly; anything else is dropped", () => {
  const G = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d";
  deepStrictEqual(parseGameEvent({ event: "game", game_id: G, hand_no: 2, state_version: 17, last_play_seq: 5 }), { gameId: G, handNo: 2, stateVersion: 17, lastPlaySeq: 5 });
  deepStrictEqual(parseGameEvent({ event: "game", game_id: G, hand_no: 1, state_version: 3, last_play_seq: 0, id: "realtime's own" }), { gameId: G, handNo: 1, stateVersion: 3, lastPlaySeq: 0 }, "Realtime's id is ignored");
  deepStrictEqual(parseGameEvent({ event: "game", game_id: G, hand_no: null, state_version: 0, last_play_seq: 0 }), { gameId: G, handNo: 0, stateVersion: 0, lastPlaySeq: 0 });
  strictEqual(parseGameEvent({ event: "members", game_id: G, hand_no: 1, state_version: 3, last_play_seq: 0 }), null);
  strictEqual(parseGameEvent({ event: "game", game_id: "not-a-uuid", hand_no: 1, state_version: 3, last_play_seq: 0 }), null);
  strictEqual(parseGameEvent({ event: "game", game_id: G, hand_no: 1, state_version: -1, last_play_seq: 0 }), null);
  strictEqual(parseGameEvent({ event: "game", game_id: G, hand_no: 1, state_version: 2.5, last_play_seq: 0 }), null);
  strictEqual(parseGameEvent({ event: "game", game_id: G, hand_no: 1, state_version: 3 }), null, "last_play_seq missing");
  strictEqual(parseGameEvent({ event: "game", game_id: G, hand_no: "1", state_version: 3, last_play_seq: 0 }), null);
  strictEqual(parseGameEvent(null), null);
});
check("game events: the version rule per game -- newer (hand, state_version) only; a new game id; out of order and duplicates dropped", () => {
  const A = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d";
  const B = "1b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d";
  const ev = (gameId: string, handNo: number, stateVersion: number, lastPlaySeq = 0): GameEvent => ({ gameId, handNo, stateVersion, lastPlaySeq });
  // The first event for a game id: taken, and flagged as a first sight.
  deepStrictEqual(acceptGameEvent(undefined, ev(A, 1, 10)), { accept: true, firstForGame: true, last: { handNo: 1, stateVersion: 10 } });
  // Same hand: only a higher state_version (it climbs by several per action: compared, never counted).
  deepStrictEqual(acceptGameEvent({ handNo: 1, stateVersion: 10 }, ev(A, 1, 13)).accept, true);
  deepStrictEqual(acceptGameEvent({ handNo: 1, stateVersion: 10 }, ev(A, 1, 10)), { accept: false, firstForGame: false, last: { handNo: 1, stateVersion: 10 } }, "a duplicate");
  deepStrictEqual(acceptGameEvent({ handNo: 1, stateVersion: 10 }, ev(A, 1, 8)).accept, false, "out of order");
  // A later hand wins even with any state_version; an earlier hand never does.
  deepStrictEqual(acceptGameEvent({ handNo: 1, stateVersion: 40 }, ev(A, 2, 41)).accept, true);
  deepStrictEqual(acceptGameEvent({ handNo: 2, stateVersion: 41 }, ev(A, 1, 99)).accept, false, "the previous hand's late event");
  // Per game id: a sequence over two games, as the hook keeps it.
  const seen = new Map<string, GameSeen>();
  const taken: string[] = [];
  for (const e of [ev(A, 1, 5), ev(A, 1, 9), ev(A, 1, 7), ev(B, 1, 2), ev(A, 1, 9), ev(B, 1, 3), ev(A, 2, 12)]) {
    const step = acceptGameEvent(seen.get(e.gameId), e);
    seen.set(e.gameId, step.last);
    if (step.accept) taken.push(`${e.gameId === A ? "A" : "B"}${e.handNo}.${e.stateVersion}${step.firstForGame ? "*" : ""}`);
  }
  deepStrictEqual(taken, ["A1.5*", "A1.9", "B1.2*", "B1.3", "A2.12"]);
  // What an accepted event asks of the screen.
  deepStrictEqual(gameEventStep({ event: ev(B, 1, 2), shownGameId: A, shownHandKey: `${A}:1`, shownMaxSeq: 0 }), { kind: "refresh" }, "another game: the poll's full refresh");
  deepStrictEqual(gameEventStep({ event: ev(A, 1, 9, 4), shownGameId: A, shownHandKey: `${A}:1`, shownMaxSeq: 3 }), { kind: "reconcile", readPlays: true }, "plays ahead of the screen");
  deepStrictEqual(gameEventStep({ event: ev(A, 1, 9, 3), shownGameId: A, shownHandKey: `${A}:1`, shownMaxSeq: 3 }), { kind: "reconcile", readPlays: false });
  deepStrictEqual(gameEventStep({ event: ev(A, 2, 12, 0), shownGameId: A, shownHandKey: `${A}:1`, shownMaxSeq: 8 }), { kind: "reconcile", readPlays: false }, "a new hand: the reconcile resets it, no plays read");
});
check("stale plays: a late read from hand N after Next Hand, and a late insert from hand N with a clashing seq, never reach hand N+1", () => {
  const G = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d";
  // The read: issued in hand 1, answered after the screen moved to hand 2 -> dropped.
  strictEqual(playsReadApplies({ gameId: G, issuedHandKey: `${G}:1`, nowHandKey: `${G}:2`, ticket: 7, appliedTicket: 6 }), false);
  // Same hand, the latest read -> applied; an older read after a newer one -> dropped.
  strictEqual(playsReadApplies({ gameId: G, issuedHandKey: `${G}:2`, nowHandKey: `${G}:2`, ticket: 7, appliedTicket: 6 }), true);
  strictEqual(playsReadApplies({ gameId: G, issuedHandKey: `${G}:2`, nowHandKey: `${G}:2`, ticket: 5, appliedTicket: 6 }), false);
  strictEqual(playsReadApplies({ gameId: G, issuedHandKey: null, nowHandKey: `${G}:2`, ticket: 9, appliedTicket: 0 }), false, "no hand set up yet");
  strictEqual(playsReadApplies({ gameId: G, issuedHandKey: `other:2`, nowHandKey: `other:2`, ticket: 9, appliedTicket: 0 }), false, "another game's hand");
  // The insert event, in the exact order of the bug: hand 1 ended with seq 8 at
  // 12:00:10; Next Hand; the screen is in hand 2's discard; hand 1's seq-8
  // insert arrives late -> dropped (it would have taken seq 8 in hand 2).
  const hand1 = [
    { seq: 7, created_at: "2026-11-26T12:00:05.000Z" },
    { seq: 8, created_at: "2026-11-26T12:00:10.000Z" },
  ];
  const floor = newestPlayTime(hand1);
  strictEqual(floor, Date.parse("2026-11-26T12:00:10.000Z"));
  const late = { eventGameId: G, eventCreatedAt: "2026-11-26T12:00:10.000Z", screenGameId: G, screenStatus: "active", handFloor: floor };
  strictEqual(playEventApplies({ ...late, screenPhase: "discard" }), false, "during the discard: never a play");
  strictEqual(playEventApplies({ ...late, screenPhase: "play" }), false, "even in hand 2's play: at or before the floor");
  // Hand 2's own plays come after the floor -> applied (counting too: the last play's insert can land after the phase moves on).
  strictEqual(playEventApplies({ ...late, eventCreatedAt: "2026-11-26T12:00:41.000Z", screenPhase: "play" }), true);
  strictEqual(playEventApplies({ ...late, eventCreatedAt: "2026-11-26T12:00:41.000Z", screenPhase: "counting" }), true);
  // Another game, or no live game on screen -> dropped.
  strictEqual(playEventApplies({ ...late, eventGameId: "x", eventCreatedAt: "2026-11-26T12:00:41.000Z", screenPhase: "play" }), false);
  strictEqual(playEventApplies({ ...late, screenStatus: "cutting", eventCreatedAt: "2026-11-26T12:00:41.000Z", screenPhase: null }), false);
  // No floor yet (the first hand on this screen): the phase rule alone.
  strictEqual(playEventApplies({ ...late, handFloor: null, screenPhase: "play" }), true);
  // The seq merge is kept for what does apply.
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  const fetch = view.slice(view.indexOf("const fetchPlays = useCallback("), view.indexOf("// THE PLAYS CATCH-UP READ"));
  strictEqual(/const ticket = \+\+playsReadSeqRef\.current;\s*const issuedHandKey = handKeyRef\.current;/.test(fetch), true, "the hand and ticket taken BEFORE the read");
  strictEqual(/if \(\s*!playsReadApplies\(\{[\s\S]*?nowHandKey: handKeyRef\.current,[\s\S]*?\}\)\s*\) \{\s*return;\s*\}\s*playsAppliedSeqRef\.current = ticket;\s*setPlays\(/.test(fetch), true);
  strictEqual(fetch.includes('.select("seq, segment, user_id, kind, card, count_after, created_at")'), true);
  const reset = view.slice(view.indexOf("const resetHandState = useCallback("), view.indexOf("// What follows from the game row on screen changing"));
  strictEqual(reset.indexOf("newestPlayTime(playsRef.current)") < reset.indexOf("setPlays([]);"), true, "the floor is taken from the hand being left, before it is cleared");
  const listener = view.slice(view.indexOf('.channel(`table-plays-${table.id}-${gameId}`)'), view.indexOf("// TABLE SYNC: CATCH UP when the tab"));
  strictEqual(listener.indexOf("playEventApplies({") > 0 && listener.indexOf("playEventApplies({") < listener.indexOf("tableSound.card(playKey("), true, "checked before its sound");
  strictEqual(listener.indexOf("playEventApplies({") < listener.indexOf("showGo("), true, "and before its Go splash");
  strictEqual(listener.includes("setPlays((current) => mergePlays(current, [event]));"), true, "the seq merge kept");
});
check("game events: the same channel, computer tables too; only the poll's own reads -- never a sound, splash, banner or computer move", () => {
  const hook = m3CodeOnly(readFileSync("components/table/useTableEvents.ts", "utf8"));
  strictEqual((hook.match(/supabase\.channel\(/g) ?? []).length, 1, "one channel");
  strictEqual(/channel\.on\("broadcast", \{ event: "game" \}, \(\{ payload \}\) => \{/.test(hook), true);
  strictEqual(/const step = acceptGameEvent\(games\.get\(event\.gameId\), event\);\s*games\.set\(event\.gameId, step\.last\);\s*if \(step\.accept\) onGameEventRef\.current\(event\);/.test(hook), true);
  const view = readFileSync("components/table/TableView.tsx", "utf8");
  // Computer tables: the role no longer needs chat (which is off there).
  const on = view.slice(view.indexOf("const tableEventsOn ="), view.indexOf("useTableEvents({"));
  strictEqual(on.includes("computer_level"), false, "no computer-table exclusion");
  strictEqual(on.includes("members.some((m) => m.user_id === session.user.id)"), true, "still only once my seat is confirmed");
  strictEqual(view.includes("onGameEvent: handleGameEvent,"), true);
  // The handler: the poll's reads only.
  const handler = m3CodeOnly(view.slice(view.indexOf("const handleGameEvent = useCallback("), view.indexOf("const handleTableEvent = useCallback(")));
  strictEqual(handler.includes("void refreshTableState(tableId);"), true);
  strictEqual(handler.includes("await reconcileGame(event.gameId);"), true);
  strictEqual(handler.includes("await catchUpPlays(event.gameId);"), true, "a MERGING plays read (never a replace)");
  strictEqual(/tableSound|showGo|showZero|showWings|showGodLoss|setTossLanding|soundCatchUpRef|trackAction|supabase|\.rpc\(|\.from\(|fetchPlays|setFinishedGame|setActiveGame/.test(handler), false,
    "no sound, splash, banner, computer action or read of its own");
  // The reads it calls never play a sound or splash: sounds come from the
  // old listeners and keyed effects only (the file's rule), and a read never
  // sets the sound catch-up (so it can't silence or replay one).
  const reconcile = m3CodeOnly(view.slice(view.indexOf("const reconcileGame = useCallback("), view.indexOf("// MEMBERS READ (with the guard above)")));
  strictEqual(/tableSound\.|show[A-Z]\w*\(|soundCatchUpRef/.test(reconcile), false);
  const after = m3CodeOnly(view.slice(view.indexOf("const afterGameChange = useCallback("), view.indexOf("// RECONCILE: re-read the current game's row")));
  strictEqual(/tableSound\.|show[A-Z]\w*\(|soundCatchUpRef/.test(after), false);
  const catchUp = m3CodeOnly(view.slice(view.indexOf("const catchUpPlays = useCallback("), view.indexOf("// Fetches every hand and the crib this player")));
  strictEqual(/tableSound\.|show[A-Z]\w*\(|soundCatchUpRef/.test(catchUp), false);
  const refresh = m3CodeOnly(view.slice(view.indexOf("const refreshTableState = useCallback("), view.indexOf("const refreshTableState = useCallback(") + 900));
  strictEqual(refresh.includes("soundCatchUpRef"), false, "the refresh (like the poll's) never sets the catch-up");
  // The old listeners, the poll and the computer driver are as they were.
  strictEqual((view.match(/"postgres_changes"/g) ?? []).length, 7);
  strictEqual(view.includes("const delay = nextPollDelayMs({ connected: realtimeConnected, disconnectedPolls, random: Math.random() });"), true);
  strictEqual(/useTableEvents|tableEvents|handleGameEvent/.test(readFileSync("components/table/useComputerDriver.ts", "utf8")), false);
  // A computer move is keyed (one per key), so an earlier re-read can't make it move twice.
  strictEqual(readFileSync("components/table/useComputerDriver.ts", "utf8").includes("a key is sent at most once at a time"), true);
});
check("test harness: every text read is CRLF-normalized, binary reads are not", () => {
  strictEqual(normalizeEol("a\r\nb\r\n"), "a\nb\n");
  strictEqual(normalizeEol("a\nb"), "a\nb");
  // Real files, whatever their line endings on disk: no CR survives a text read.
  for (const f of ["lib/openTables.ts", "components/table/TableView.tsx", "docs/sql/spectators.sql", "scripts/test-phase3.ts"]) {
    strictEqual(readFileSync(f, "utf8").includes("\r"), false, f);
  }
  // A file stored with CRLF still has them in its raw text: the helper is what removes them.
  const raw = readFileSyncRaw("docs/sql/spectators.sql", "utf8");
  if (raw.includes("\r\n")) strictEqual(readFileSync("docs/sql/spectators.sql", "utf8"), raw.replace(/\r\n/g, "\n"));
  // Binary reads come back as bytes, untouched.
  strictEqual(Buffer.isBuffer(readFileSync("public/boards/derby.webp")), true);
  // No read in this file bypasses the helper: the helper's two raw reads and this check's two.
  const self = readFileSyncRaw("scripts/test-phase3.ts", "utf8");
  strictEqual((self.match(/readFileSyncRaw\(/g) ?? []).length, 4);
});

console.log(`All ${passed} Phase 3 helper checks passed.`);
