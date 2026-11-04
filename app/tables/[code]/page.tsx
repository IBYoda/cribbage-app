"use client";

import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";
import { useParams, useRouter } from "next/navigation";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { supabase } from "@/lib/supabase";
import { nicknameStepHref } from "@/lib/nickname";
import { fetchNeedsNickname } from "@/lib/profileNickname";
import { cardPlayValue, sortHand } from "@/lib/cards";
import { FaceDownCard, PlayingCard } from "@/components/PlayingCard";
import { CutForDealView } from "@/components/CutForDealView";
import { TableHeader, TableShell } from "@/components/table/TableShell";
import { OpponentBand, SideSeat, type OpponentSeat } from "@/components/table/OpponentBand";
import { PileRow } from "@/components/table/PileRow";
import { HandRow } from "@/components/table/HandRow";
import { WaitingForPlayer } from "@/components/table/WaitingForPlayer";
import { WaitingRoom } from "@/components/table/WaitingRoom";
import { buildPlates, cardsLeft, cribCountDuringDiscard, handSizes, nextSeat, seatOrderFrom, seatPlaces, winHeadline } from "@/lib/phase3";
import { useAppearance } from "@/components/AppearanceProvider";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { MugginsNotice } from "@/components/brand/MugginsNotice";
import { CountsToggle } from "@/components/table/CountsToggle";
import { MugginsWinBar } from "@/components/table/MugginsWinBar";
import { MugginsPlates } from "@/components/table/MugginsPlates";
import { mugginsPlateStates } from "@/lib/mugginsPlates";
import { hideRejoinedScores, scoreFromThisGame } from "@/lib/resultScores";
import { pollIntervalMs, profilesToFetch, wonBoardReusable } from "@/lib/tableSync";
import { isCountReason } from "@/components/table/countingView";
import { ScoreFlash, ScoreStrip, type ScorePlate } from "@/components/table/ScoreStrip";
import { HAND_CARD } from "@/components/table/sizes";
import { countingView, type CardSlot, type CountingView } from "@/components/table/countingView";
import { countingViewN } from "@/lib/countingN";
import { CountStage, SlotCards } from "@/components/table/CountStage";
import { PlayArea, displayedRun, goSayers, type PlayEvent } from "@/components/PlayArea";
import { useComputerDriver } from "@/components/table/useComputerDriver";
import { Splash, useSplash } from "@/components/table/Splash";
import { SquareOpponentHand, SquareTableHeader, SquareTableShell } from "@/components/table/SquareTable";
import { SeatPlayedCards } from "@/components/table/SeatPlayedCards";
import { CenterCount } from "@/components/table/CenterCount";
import { SeatStatus, SquareRingMiddle, type RingSeat } from "@/components/table/SquareRing";
import {
  chooseTableLayout,
  countingReveals,
  countingStarterPlace,
  isSquareTable,
  laneForPlayer,
  boardLanesFor,
  ringLayout,
  playedBySeat,
  seatGeometry,
  seatPositionOf,
  seatsOnScreen,
  type SeatPosition,
  type TableScreen,
} from "@/lib/tableLayout";
import { CribbageBoard, SelfScoringBanner, useBoardPattern, useBoardSkin } from "@/components/table/CribbageBoard";
import { laneRingColor } from "@/lib/boardSkins";
import {
  ComputerDiscardClock,
  CountingStarter,
  DealAnimation,
  DealStandby,
  DiscardToss,
  type TossSeat,
  useDealAnimationOn,
  usePrefersReducedMotion,
} from "@/components/table/DealAnimation";
import {
  STARTER_SLIDE_MS,
  dealPlan,
  discardShown,
  fireDiscardShow,
  liveDealStep,
  liveDiscardStep,
  liveStarterStep,
  markDiscardSeen,
  shownCribIds,
  writeDiscardShown,
  type DiscardSeen,
  type DiscardShow,
} from "@/lib/dealAnimation";

// THE LAYOUT PARAM (PRD item 31): the square layout is the default for a
// 2-, 3- or 4-player table (Teams or Solo), self-scoring (Muggins)
// included (chooseTableLayout, lib/tableLayout.ts);
// ?layout=classic on the page's URL
// forces the classic table -- except on a 3- or 4-player self-scoring
// table, which is always square. Read through
// useSyncExternalStore with no param on the server and in the hydrating
// render. That render is always the "Loading..." screen (the session is read
// in an effect, so `loading` starts true on both sides), so the param can
// never make hydration differ; by the time a table draws, the client value
// is in. See also the square table's wait for the first full read (THE
// FIRST READ, below), so no classic shell shows before the square one.
const subscribeToLocation = (onChange: () => void) => {
  window.addEventListener("popstate", onChange);
  return () => window.removeEventListener("popstate", onChange);
};
const layoutParamFromUrl = () => new URLSearchParams(window.location.search).get("layout");
const layoutParamOnServer = () => null;

type TableRow = {
  id: string;
  code: string;
  status: string;
  // MUGGINS (chosen at creation, never changed): the app keeps no visible
  // score -- no score strip, no score flash, no count numbers, no score in
  // the result -- and the players keep their own.
  is_muggins: boolean;
  // Who created it: the creator never sees the joiner's Muggins notice (they
  // saw it when creating).
  created_by: string;
  // TABLE SIZE (Phase 3, chosen at creation): 2, 3 or 4 seats, and for 4
  // whether partners play as teams. Every table before Phase 3 is 2 / teams.
  max_players: number;
  team_mode: string;
  // A COMPUTER TABLE: the computer opponent's level ('easy' / 'medium' /
  // 'hard'), null at every other table. Set by create_computer_table; the
  // computer's moves come from the creator's browser (useComputerDriver).
  computer_level: string | null;
};

type Member = {
  user_id: string;
  nickname: string | null;
  // For the score plate. Optional on the profile; plates fall back to an initial.
  avatar_url: string | null;
  joined_at: string;
  // Seat 1 to max_players (Phase 3, E1): clockwise order, given on joining
  // and moved only by the host before a game (set_seat). Null only for a
  // row the server hasn't seated (never, after E1).
  seat: number | null;
  // The running score, and the last award that moved it. Lives on
  // table_members because that table is already keyed (table_id, user_id) --
  // exactly the grain a per-player running total needs.
  score: number;
  last_points: number | null;
  last_reason: string | null;
  last_awarded_at: string | null;
};

const MEMBER_COLUMNS =
  "user_id, joined_at, seat, score, last_points, last_reason, last_awarded_at";

// Cards cut for the deal. deal_cut is the full history -- an array of rounds,
// filled progressively as players tap the deck. The round in progress is always
// the LAST element, so there is no separate pointer to drift out of sync.
// Null on games where the deal simply alternated (no cut happened).
type DealCutEntry = { user_id: string; card: string };
type DealCutRound = DealCutEntry[];

type Game = {
  id: string;
  created_at: string;
  // 'cutting' -> cutting for deal, NOTHING dealt yet. 'active' -> cards are out.
  status: string;
  // Roster snapshot taken when the game was created. Dealing happens later than
  // creation now, so the server deals to this rather than to whoever happens to
  // be at the table at deal time.
  players: string[] | null;
  // Null for the whole 'cutting' phase -- nothing about the dealer is known
  // until a round completes with a unique lowest card.
  dealer_id: string | null;
  // Who has discarded -- never WHAT they discarded. The crib's contents live in
  // game_cribs, which nobody can read yet.
  discarded_by: string[];
  deal_cut: DealCutRound[] | null;
  // Who has acknowledged the completed round. Gates both the tie redraw and the
  // deal itself.
  deal_cut_ack_by: string[];
  // Public, unlike every other card in the game -- which is exactly why it can
  // live on games rather than needing its own locked-down table.
  starter_card: string | null;
  // Where within a LIVE game we are. Separate from status, which means "is
  // this game live at all" and is load-bearing in seven other places.
  phase: string;
  // Whose turn it is during play. Explicit rather than derived from "last
  // player's opponent", because a go lets one player play several times in a row.
  current_player: string | null;
  play_count: number;
  play_segment: number;
  // Which count is up: 0 = the pone's hand, 1 = the dealer's hand, 2 = the
  // crib. Stays at 2 once phase reaches 'done'. current_player always names
  // who acts at this step, so the UI never derives turn order itself.
  count_step: number;
  // Whose hands are shown. The ONLY record of visibility: the game_hands read
  // policy checks it, and it arrives on this broadcast, so a change here is
  // the signal to refetch whatever hands we're now allowed to read.
  revealed_by: string[];
  crib_revealed: boolean;
  // Set in the same statement that ends the game with ended_reason 'won'.
  winner_id: string | null;
  // Which hand of the match this is (one games row is one match). next_hand
  // bumps it in the same statement that resets the hand, so a change here is
  // THE signal that a new hand was dealt -- on both screens.
  hand_no: number;
  // Who has tapped Next Hand for this hand. The hand is dealt only once every
  // player is in it, and next_hand clears it in the same UPDATE that bumps
  // hand_no -- so it is only ever non-empty during 'done'. The button's
  // "ready / waiting" state is derived from this, never from local state, so
  // a refresh shows exactly what the server knows.
  ready_by: string[];
  // MUGGINS: who has claimed the win of this live match, waiting for the
  // other player(s) to confirm it (claim_win / confirm_win). Always null on
  // a normal table.
  win_claim_by: string | null;
  // MUGGINS, 3 and 4 players: who has confirmed that claim so far; the last
  // confirmation ends the match (confirm_win). Optional: a row from before
  // the column existed has none -- read it as nobody (`?? []`).
  win_confirmed_by?: string[] | null;
};

// Must stay a single string LITERAL, not a concatenation: supabase-js infers
// the returned row shape from this exact literal type, and "a" + "b" widens to
// plain `string`, which silently collapses the result type to an error type.
const GAME_COLUMNS =
  "id, created_at, status, players, dealer_id, discarded_by, deal_cut, deal_cut_ack_by, starter_card, phase, current_player, play_count, play_segment, count_step, revealed_by, crib_revealed, winner_id, hand_no, ready_by, win_claim_by, win_confirmed_by";

// The last game to end in a win, kept after the live game is gone so the
// result stays on screen (and survives a reload) until the next game starts.
// players and ready_by are the New Game ready gate's: who played the match,
// and who has tapped New Game since (stored on the WON game's own row).
// starter_card, dealer_id and board are THE FINAL BOARD: the table as the
// match ended -- the starter, whose hand it was, and (board) the last run, both
// hands and the crib. created_at is when the game began: a seat joined
// after it (a player who left and came back) can't hold this game's score
// (scoreFromThisGame, lib/resultScores.ts). Null if it wasn't read.
type FinishedGame = {
  id: string;
  created_at: string | null;
  winner_id: string | null;
  players: string[];
  ready_by: string[];
  starter_card: string | null;
  dealer_id: string | null;
  board: WonBoard;
};

// The cards on the final board.
//   finalRun: the hand's last run -- the newest run with any cards (the
//     current one, or the one before it if the last card made 31). Empty
//     only on his heels: next_hand deleted the previous hand's plays, and
//     nothing has been played yet.
//   hands: every hand this player may READ, by owner. game_hands.cards is the
//     four kept cards for the whole hand -- play_card never removes a card
//     from it (played cards only go to game_plays) -- so no rebuilding is
//     needed. Until the won-game read policies are applied, an opponent's
//     hand that was never shown isn't readable: it's simply missing here, and
//     the board shows it face-down.
//   crib: the four crib cards, or null while unreadable (face-down). Always
//     complete by the time of any win: the starter is cut, and his heels
//     scored, only once every player has discarded.
//   complete: set only by readWonBoard when all three reads succeeded, so a
//     later full refresh of the same won game can keep this board instead of
//     reading it again (wonBoardReusable, lib/tableSync.ts). Unset on a board
//     built from what was on screen when the game ended.
type WonBoard = {
  finalRun: PlayEvent[];
  hands: Record<string, string[]>;
  crib: string[] | null;
  complete?: boolean;
};

function finalRunOf(plays: PlayEvent[], playSegment: number) {
  return displayedRun(plays, playSegment, true).events;
}

// Reads the final board of a won game. game_plays is readable by any logged-in
// user; game_hands and game_cribs by RLS (see WonBoard above). Rows stay until
// next_hand, which an ended game never reaches.
async function readWonBoard(gameId: string, playSegment: number): Promise<WonBoard> {
  const [
    { data: playRows, error: playsError },
    { data: handRows, error: handsError },
    { data: cribRow, error: cribError },
  ] = await Promise.all([
    supabase
      .from("game_plays")
      .select("seq, segment, user_id, kind, card, count_after")
      .eq("game_id", gameId)
      .order("seq", { ascending: true }),
    supabase.from("game_hands").select("user_id, cards").eq("game_id", gameId),
    supabase.from("game_cribs").select("cards").eq("game_id", gameId).maybeSingle(),
  ]);
  return {
    finalRun: finalRunOf((playRows as PlayEvent[]) ?? [], playSegment),
    hands: Object.fromEntries((handRows ?? []).map((r) => [r.user_id, r.cards as string[]])),
    crib: cribRow?.cards ?? null,
    complete: !playsError && !handsError && !cribError,
  };
}

// Both lists, without repeats. The won game's ready_by only ever grows (the
// gate appends to it; nothing else writes it once the game has ended), so the
// union of two reads is never older than either -- which is what lets a REST
// read and a realtime event land in any order without rolling the other back.
function unionIds(a: string[], b: string[]) {
  return [...a, ...b.filter((id) => !a.includes(id))];
}

// THE CRIB'S STEP in the count: after every hand, so step N for N players
// (phase3-e4-counting.sql) -- 2 for every 2-player table.
const cribStepFor = (players: string[] | null | undefined) => players?.length ?? 2;

// The key for "has visibility changed?" -- compared on every games UPDATE so
// hands and the crib are refetched only when what's readable can have
// changed, not on every unrelated broadcast: a reveal (revealed_by,
// crib_revealed), or the count reaching a point where the read policies open
// up (phase2-open-hands-in-count.sql) -- counting starts (every hand), and
// the crib's step or 'done' (the crib).
function revealKey(row: {
  revealed_by: string[] | null | undefined;
  crib_revealed: boolean | null | undefined;
  phase: string | null | undefined;
  count_step: number | null | undefined;
  players?: string[] | null;
}) {
  const cribUp = row.phase === "done" || (row.count_step ?? 0) >= cribStepFor(row.players);
  return `${(row.revealed_by ?? []).join(",")}|${row.crib_revealed ? 1 : 0}|${row.phase}|${cribUp ? 1 : 0}`;
}

// A game is "live" while it is either cutting for deal or actually being
// played. Both block a second game at the table, and both must be found by the
// client, the admin view, leave-table and the timeout sweep.
const LIVE_GAME_STATUSES = ["cutting", "active"];

// HAND SIZES come from handSizes() in lib/phase3.ts, by the number of
// players: 6 dealt, 2 discarded and 4 kept with 2 players (as always); 5, 1
// and 4 with 3 or 4.
const sizesFor = (players: string[] | null | undefined) => handSizes(players?.length ?? 2);

// TABLE SYNC: what the safety poll (see the poll effect) compares, to say
// exactly what a missed realtime event had left wrong on screen.
const GAME_SYNC_FIELDS = [
  "status", "players", "dealer_id", "discarded_by", "deal_cut", "deal_cut_ack_by",
  "starter_card", "phase", "current_player", "play_count", "play_segment",
  "count_step", "revealed_by", "crib_revealed", "winner_id", "hand_no", "ready_by",
  "win_claim_by", "win_confirmed_by",
] as const;

function gameDiff(shown: Game, fresh: Game) {
  return GAME_SYNC_FIELDS.filter((k) => JSON.stringify(shown[k]) !== JSON.stringify(fresh[k]));
}

// Award times compared as times: a REST read and a realtime payload can
// format the same timestamp differently.
const sameTime = (a: string | null, b: string | null) =>
  (a ? Date.parse(a) : 0) === (b ? Date.parse(b) : 0);

function membersDiff(shown: Member[], fresh: Member[]) {
  const out: string[] = [];
  for (const m of fresh) {
    const s = shown.find((x) => x.user_id === m.user_id);
    if (!s) out.push(`joined ${m.user_id}`);
    else if (
      s.score !== m.score ||
      s.last_points !== m.last_points ||
      s.last_reason !== m.last_reason ||
      !sameTime(s.last_awarded_at, m.last_awarded_at)
    )
      out.push(`score ${m.user_id}`);
    // A missed seat move (set_seat) -- the waiting room's order.
    if (s && s.seat !== m.seat) out.push(`seat ${m.user_id}`);
  }
  for (const s of shown) if (!fresh.some((m) => m.user_id === s.user_id)) out.push(`left ${s.user_id}`);
  return out;
}

// A closed computer table (leave_computer_table) has no ended_reason: it was
// closed by its player, not an admin.
function tableEndedMessage(endedReason: string | null | undefined, computerLevel?: string | null) {
  if (computerLevel && endedReason == null) return "This computer table has been closed.";
  return endedReason === "timeout"
    ? "This table was automatically ended after being open for 12 hours."
    : "This table has been ended by an admin.";
}

function displayName(member: Member | undefined) {
  return member?.nickname || "Unnamed player";
}

export default function TablePage() {
  const params = useParams<{ code: string }>();
  const router = useRouter();
  // MY card back and table surface (my screen only). The table isn't drawn
  // until they're known, so it never appears in the wrong look first.
  const appearance = useAppearance();
  const code = params.code;

  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [table, setTable] = useState<TableRow | null>(null);
  // THE JOINER'S MUGGINS NOTICE: a Muggins table this player is not yet
  // seated at, waiting for "Join Self-Scoring (Muggins) table". Nothing about the table is
  // loaded or shown, and no seat exists, until they agree.
  const [pendingJoin, setPendingJoin] = useState<TableRow | null>(null);
  // THE NICKNAME GATE: a player without a nickname, about to take a NEW
  // seat, is on their way to the nickname step (and back here after). The
  // page stays "Loading..." meanwhile.
  const [toNickname, setToNickname] = useState(false);
  // MUGGINS: no visible scoring on this table, for everyone (see TableRow).
  const isMuggins = table?.is_muggins === true;
  // HIDE COUNT NUMBERS: the ONE value everything below reads to hide the
  // hand and crib count numbers on this screen (the recap, count flashes, a
  // count win's breakdown): this player's Hide counts setting, or a Muggins
  // table, whatever the setting. The score strip is never affected by the
  // setting (a Muggins table has none at all).
  const hideCountNumbers = appearance.hideCounts || isMuggins;
  const [members, setMembers] = useState<Member[]>([]);
  const [error, setError] = useState<string | null>(null);
  // The error on screen is a CLOSED COMPUTER TABLE: the error screen offers
  // just "Back to home" (Retry and another code make no sense there). Set
  // with the error where a table is found closed; cleared by a fresh setup.
  const [closedComputerTable, setClosedComputerTable] = useState(false);
  const [activeGame, setActiveGame] = useState<Game | null>(null);
  const [gameStatus, setGameStatus] = useState<"idle" | "creating" | "error">("idle");
  const [gameMessage, setGameMessage] = useState<string | null>(null);
  // THE WAITING ROOM's move control (3 and 4 players, host only): the player
  // picked to move, and the last set_seat call's outcome (its error is
  // shown word for word in the error overlay).
  const [seatPick, setSeatPick] = useState<string | null>(null);
  const [seatStatus, setSeatStatus] = useState<"idle" | "sending" | "error">("idle");
  const [seatMessage, setSeatMessage] = useState<string | null>(null);
  const [retryKey, setRetryKey] = useState(0);
  const [realtimeStatus, setRealtimeStatus] = useState<"connecting" | "connected" | "disconnected">(
    "connecting"
  );
  const [myHand, setMyHand] = useState<string[]>([]);
  const [handSorted, setHandSorted] = useState(false);
  // Tracked as card codes, not indices, so hitting Sort mid-selection doesn't
  // scramble which cards are selected.
  const [selectedCards, setSelectedCards] = useState<string[]>([]);
  const [discardStatus, setDiscardStatus] = useState<"idle" | "sending" | "error">("idle");
  const [discardMessage, setDiscardMessage] = useState<string | null>(null);
  // The public play log for this game. Cards on the table are public the
  // instant they're played, so unlike hands this needs no per-user filtering.
  const [plays, setPlays] = useState<PlayEvent[]>([]);
  // The plays and my hand as last rendered, for the realtime handler: when a
  // match is won, the final run and my hand are shown from these at once
  // (then confirmed by a re-read -- see the games UPDATE handler).
  const playsRef = useRef<PlayEvent[]>([]);
  useEffect(() => {
    playsRef.current = plays;
  }, [plays]);
  const myHandRef = useRef<{ userId: string; cards: string[] } | null>(null);
  useEffect(() => {
    myHandRef.current = session ? { userId: session.user.id, cards: myHand } : null;
  }, [session, myHand]);
  const [playStatus, setPlayStatus] = useState<"idle" | "sending" | "error">("idle");
  const [playMessage, setPlayMessage] = useState<string | null>(null);
  // Two-step confirm, but only when a game is live -- leaving then destroys a
  // game for BOTH players, which is too much to hang off one stray tap.
  const [leaveConfirming, setLeaveConfirming] = useState(false);
  const [leaveStatus, setLeaveStatus] = useState<"idle" | "leaving" | "error">("idle");
  const [leaveMessage, setLeaveMessage] = useState<string | null>(null);
  // MY OWN LEAVE in progress, for the realtime "table closed" handler (a
  // long-lived closure): leaving a computer table closes it, and that event
  // must not flash the closed message before we navigate away.
  const leavingRef = useRef(false);
  useEffect(() => {
    leavingRef.current = leaveStatus === "leaving";
  }, [leaveStatus]);
  // Explains why the remaining player's cards just vanished. Without it, a
  // game silently evaporating is exactly the kind of mystery the PRD's UX
  // section objects to.
  const [gameEndedNotice, setGameEndedNotice] = useState<string | null>(null);
  // Every hand this player may currently read, keyed by owner: always their
  // own, plus any shown at the table. RLS does the filtering; whatever comes
  // back is by definition allowed.
  const [revealedHands, setRevealedHands] = useState<Record<string, string[]>>({});
  // Null until the dealer shows it -- before that, RLS returns no row at all.
  const [cribCards, setCribCards] = useState<string[] | null>(null);
  const [countStatus, setCountStatus] = useState<"idle" | "sending" | "error">("idle");
  // MUGGINS: the win bar's call (claim_win / clear_win_claim / confirm_win)
  // in flight, and a refused call's message -- kept with the game it was
  // for, so it never shows on another game.
  const [winSending, setWinSending] = useState(false);
  const [winError, setWinError] = useState<{ gameId: string; message: string } | null>(null);
  const [countMessage, setCountMessage] = useState<string | null>(null);
  const [finishedGame, setFinishedGame] = useState<FinishedGame | null>(null);
  // True once the roster (and so every score and last award) has been read.
  // The score flash isn't mounted before then -- see ScoreFlash.
  const [membersLoaded, setMembersLoaded] = useState(false);
  // THE PEGGING HOLD -- client-only, per screen, never stored. When this
  // screen sees the hand go from play to counting, it keeps showing the
  // pegging view (the final run, the final count, the last-card/go flash)
  // until THIS player taps "Count hands". Holds the "<game id>:<hand_no>" it
  // applies to, so a new hand or a new game can never inherit it.
  const [pegHoldKey, setPegHoldKey] = useState<string | null>(null);
  // The "<game id>:<hand_no>:<phase>" this screen last rendered -- how the
  // play -> counting step is spotted (see below).
  const [seenPhaseKey, setSeenPhaseKey] = useState<string | null>(null);
  // THE DEALING ANIMATION (square table): see "A LIVE DEAL" below. tableRead:
  // the first full read of the table is in. dealSeenKey: the dealt hand
  // ("<game id>:<hand_no>") last seen (undefined until the first read).
  // dealLiveKey: the hand this screen saw dealt live; dealDoneKey: the hand
  // whose deal has finished or been skipped.
  const [tableRead, setTableRead] = useState(false);
  const [dealSeenKey, setDealSeenKey] = useState<string | null | undefined>(undefined);
  const [dealLiveKey, setDealLiveKey] = useState<string | null>(null);
  const [dealDoneKey, setDealDoneKey] = useState<string | null>(null);
  // THE DISCARD TOSS (square table): see "A LIVE DISCARD" below.
  // discardSeen: who this screen has seen discard, per hand; tosses: the
  // throws to the crib in flight; myTossKey: the hand I threw my discard in.
  const [discardSeen, setDiscardSeen] = useState<DiscardSeen | undefined>(undefined);
  const [tosses, setTosses] = useState<{ id: string; handKey: string; seats: TossSeat[] }[]>([]);
  const [myTossKey, setMyTossKey] = useState<string | null>(null);
  // THE STARTER'S SLIDE (square table): see "THE STARTER IN COUNTING" below.
  // starterSeenKey: "<hand>:count" or "<hand>:other" last seen;
  // starterLiveKey: the hand whose starter is sliding now.
  const [starterSeenKey, setStarterSeenKey] = useState<string | null | undefined>(undefined);
  const [starterLiveKey, setStarterLiveKey] = useState<string | null>(null);
  // THE COMPUTER'S DISCARD, SHOWN ON TIME (2-player square table with a
  // computer opponent): see below.
  const [discardShow, setDiscardShow] = useState<DiscardShow>(null);
  // The revealKey last fetched for. A ref for the same reason as
  // lastGameStatusRef: it's read inside the realtime handler.
  const revealKeyRef = useRef<string | null>(null);
  // The last game status this client processed. Used to spot the exact
  // cutting -> active moment (when cards come into existence) from inside the
  // realtime handler. A ref rather than state because reading it from a state
  // updater would make that updater impure, and React re-invokes updaters in
  // development -- which would fire the fetch twice.
  const lastGameStatusRef = useRef<string | null>(null);
  // The realtime channel is subscribed per TABLE and never re-subscribes when
  // the active game changes, so reading activeGame inside its handlers would
  // capture a stale closure. A ref always reads current.
  const activeGameIdRef = useRef<string | null>(null);
  // The won game whose result is on screen -- set synchronously, like
  // activeGameIdRef, so realtime events are matched against it at once. Its
  // UPDATEs carry New Game taps (ready_by), and nothing else is taken from them.
  const finishedGameIdRef = useRef<string | null>(null);
  // The won game on screen, board included, for readTableState to keep its
  // fully read board (wonBoardReusable) -- in step through the effect below.
  const finishedGameRef = useRef<FinishedGame | null>(null);
  // Every write of finishedGame goes through here: it keeps the ref in step,
  // and a second read of the SAME won game merges ready_by rather than
  // replacing it (see unionIds), so an older read can't drop a tap.
  const showFinishedGame = useCallback((next: FinishedGame | null) => {
    finishedGameIdRef.current = next?.id ?? null;
    setFinishedGame((current) =>
      next && current && current.id === next.id
        ? {
            ...next,
            ready_by: unionIds(current.ready_by, next.ready_by),
          }
        : next
    );
  }, []);
  // "<game id>:<hand_no>" of the hand this client last set up. A change in
  // either half means different cards are on the table -- a new hand within
  // the match (next_hand) or a new game altogether (New Game) -- and
  // everything tied to the old hand must go. A ref because the realtime
  // handler reads it.
  const handKeyRef = useRef<string | null>(null);
  // ORDERING GUARD for reads of the games row. Every read takes a ticket when
  // it is ISSUED; a result is applied only if no later-issued read has been
  // applied already. Without this, a slow read issued before a change can
  // land after a newer state and roll the screen back.
  const gameReadSeqRef = useRef(0);
  const gameAppliedSeqRef = useRef(0);
  // reconcileGame's single-flight state: one read at a time, and if more
  // events arrive meanwhile, exactly one more read afterwards -- for whatever
  // game is current by then.
  const reconcileInFlightRef = useRef(false);
  const reconcileAgainRef = useRef(false);
  const reconcileTargetRef = useRef<string | null>(null);
  // TABLE SYNC (fix/table-sync).
  // HAND READ ORDERING: every read of my hand takes a ticket when issued, and
  // is applied only if no later-issued read (or a clear) has been applied --
  // so an older hand can never overwrite a newer one.
  const handReadSeqRef = useRef(0);
  const handAppliedSeqRef = useRef(0);
  // MEMBERS READ GUARD: the same tickets for the roster read, plus a count of
  // roster realtime events. A read during which an event arrived may be older
  // than the screen, so it is read again, and if still racing, MERGED by
  // user_id -- it can never remove a player an INSERT just added.
  const membersReadSeqRef = useRef(0);
  const membersAppliedSeqRef = useRef(0);
  const membersEventSeqRef = useRef(0);
  // games INSERT/UPDATE events seen; a poll read during which one arrived is
  // not compared (realtime is clearly alive, and the screen may be newer).
  const gameEventSeqRef = useRef(0);
  // My own actions (RPCs) and full refreshes in flight: the poll waits.
  const actionsInFlightRef = useRef(0);
  const refreshesInFlightRef = useRef(0);
  // The roster, game and error as last rendered, for the poll.
  const membersRef = useRef<Member[]>([]);
  const activeGameRef = useRef<Game | null>(null);
  const errorRef = useRef<string | null>(null);
  // THE SPLASHES ("19" and GO), fired from the realtime handlers only -- see
  // components/table/Splash.tsx.
  const { splash, showZero, showGo, dismiss: dismissSplash } = useSplash({ noZero: hideCountNumbers });
  // ?layout= (see THE LAYOUT PARAM above). Drawing only.
  const layoutParam = useSyncExternalStore(subscribeToLocation, layoutParamFromUrl, layoutParamOnServer);
  // The dealing animation's off switches: the Profile setting (this device)
  // and the system's reduced motion.
  const dealAnimationOn = useDealAnimationOn();
  const reducedMotion = usePrefersReducedMotion();
  // The board THIS player picked in Profile (this device only): the square
  // table's board strip, lane rings and self-scoring banner.
  const boardSkin = useBoardSkin();
  // ...and its pattern (Straight or S), likewise this device only.
  const boardPattern = useBoardPattern();
  useEffect(() => {
    membersRef.current = members;
    activeGameRef.current = activeGame;
    errorRef.current = error;
  }, [members, activeGame, error]);
  // Marks one of my RPCs as in flight for its duration (the poll waits).
  const trackAction = useCallback(async <T,>(call: PromiseLike<T>): Promise<T> => {
    actionsInFlightRef.current++;
    try {
      return await call;
    } finally {
      actionsInFlightRef.current--;
    }
  }, []);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });
  }, []);

  // Fetches this player's own hand.
  //
  // Filtered by user_id as well as game_id. Until Batch 2a, RLS meant a
  // game_id filter alone could only ever return our own row. Now a SHOWN hand
  // is readable too, so without the user_id filter this would get two rows
  // during counting and maybeSingle() would fail.
  const fetchMyHand = useCallback(async (gameId: string) => {
    const { data: auth } = await supabase.auth.getSession();
    const myId = auth.session?.user.id;
    if (!myId) return;

    const ticket = ++handReadSeqRef.current;
    const { data } = await supabase
      .from("game_hands")
      .select("cards")
      .eq("game_id", gameId)
      .eq("user_id", myId)
      .maybeSingle();

    // A later-issued read (or a clear) has already been applied: this one is
    // older, so it must not replace it.
    if (ticket < handAppliedSeqRef.current) return;
    handAppliedSeqRef.current = ticket;

    // NOTE: from the discard onwards this array is IMMUTABLE -- it is the four
    // cards that get counted after play. Cards you've played are tracked
    // separately in game_plays, and "what I still hold" is the difference.
    setMyHand(data?.cards ?? []);
    // Any selection referred to the pre-discard hand, so it's stale now.
    // handSorted is deliberately NOT reset here: sorting is a display-only
    // preference, and clearing it on every refetch would silently un-sort the
    // remaining 4 cards the moment you discarded. It's reset when a genuinely
    // new hand is dealt instead.
    setSelectedCards([]);
  }, []);

  const fetchPlays = useCallback(async (gameId: string) => {
    const { data } = await supabase
      .from("game_plays")
      .select("seq, segment, user_id, kind, card, count_after")
      .eq("game_id", gameId)
      .order("seq", { ascending: true });

    setPlays((data as PlayEvent[]) ?? []);
  }, []);

  // Fetches every hand and the crib this player is allowed to see. No
  // filtering by owner here: the read policies return our own hand plus any
  // shown at this table, and the crib only once it's been shown. Neither
  // table is in the Realtime publication -- the games broadcast (revealed_by,
  // crib_revealed) is what says when to call this.
  const fetchRevealed = useCallback(async (gameId: string) => {
    const [{ data: handRows }, { data: cribRow }] = await Promise.all([
      supabase.from("game_hands").select("user_id, cards").eq("game_id", gameId),
      supabase.from("game_cribs").select("cards").eq("game_id", gameId).maybeSingle(),
    ]);

    setRevealedHands(Object.fromEntries((handRows ?? []).map((r) => [r.user_id, r.cards])));
    setCribCards(cribRow?.cards ?? null);
  }, []);

  const clearRevealed = useCallback(() => {
    setRevealedHands({});
    setCribCards(null);
    revealKeyRef.current = null;
  }, []);

  // Drops everything that belongs to the hand just finished: the play log,
  // any selection, the sort preference, shown hands and the crib (and with
  // them the breakdowns, which are derived from those), and the counting
  // status line. The old hand is cleared too, so its cards can't sit on
  // screen while the new ones load. Scores are NOT touched -- they live on
  // table_members, and next_hand doesn't change them.
  const resetHandState = useCallback(() => {
    setPlays([]);
    handAppliedSeqRef.current = ++handReadSeqRef.current; // outdates hand reads in flight
    setMyHand([]);
    setSelectedCards([]);
    setHandSorted(false);
    clearRevealed();
    setCountStatus("idle");
    setCountMessage(null);
  }, [clearRevealed]);

  // What follows from the game row on screen changing, however the new row
  // arrived -- a realtime payload or a fresh read. Driven by refs, so running
  // it twice for the same row does nothing the second time.
  const afterGameChange = useCallback(
    (
      row: {
        id: string;
        status: string;
        phase: string | null;
        hand_no: number | null;
        revealed_by: string[] | null;
        crib_revealed: boolean | null;
        count_step: number | null;
        discarded_by: string[] | null;
        players?: string[] | null;
      },
      previousStatus: string | null
    ) => {
      // A NEW HAND (next_hand bumped hand_no): drop everything from the
      // finished hand and fetch our new six cards. Scores don't move.
      if (row.hand_no != null && `${row.id}:${row.hand_no}` !== handKeyRef.current) {
        resetHandState();
        handKeyRef.current = `${row.id}:${row.hand_no}`;
        fetchMyHand(row.id);
        return;
      }

      // Counting just started, the crib's count came up, or something was
      // shown -- refetch what the read policies now allow. Only from counting
      // on, the only time any of it is readable.
      const key = revealKey(row);
      if ((row.phase === "counting" || row.phase === "done") && key !== revealKeyRef.current) {
        revealKeyRef.current = key;
        fetchRevealed(row.id);
      }

      // The cut resolved and the cards were dealt (acknowledge_deal_cut flips
      // cutting -> active in the same statement that deals).
      if (previousStatus === "cutting" && row.status === "active") {
        setHandSorted(false); // freshly dealt -- show it as dealt
        fetchMyHand(row.id);
        return;
      }

      // TABLE SYNC: the row says I have discarded, but the screen still holds
      // the six dealt cards -- the post-discard read was lost (see
      // handleDiscard). Fetch the four kept cards. Ticketed, so harmless if a
      // read is already on its way.
      const mine = myHandRef.current;
      if (
        row.status === "active" &&
        mine &&
        (row.discarded_by ?? []).includes(mine.userId) &&
        mine.cards.length === sizesFor(row.players).dealt
      ) {
        fetchMyHand(row.id);
      }
    },
    [resetHandState, fetchMyHand, fetchRevealed]
  );

  // RECONCILE: re-read the current game's row from the database and show
  // exactly that.
  //
  // Why it exists: a realtime UPDATE payload is a snapshot of the row after
  // ONE statement, and several functions write the games row more than once
  // per transaction -- discard_to_crib writes it three times (discarded_by,
  // then the starter, then phase 'play' + current_player). Applying payloads
  // as "the latest row" is only right if every one arrives, in order, and
  // nothing older lands after them. When that fails the screen freezes on an
  // intermediate snapshot with nothing to correct it until the next action
  // -- the "starter and crib showing, pegging never starts" bug after a New
  // Game. A read issued AFTER an event arrives is at least as new as that
  // event's transaction, so ending every burst with one read makes the
  // screen converge on the database.
  const reconcileGame = useCallback(
    async (gameId: string) => {
      reconcileTargetRef.current = gameId;
      if (reconcileInFlightRef.current) {
        reconcileAgainRef.current = true;
        return;
      }
      reconcileInFlightRef.current = true;
      try {
        do {
          reconcileAgainRef.current = false;
          const target = reconcileTargetRef.current;
          if (!target) break;

          const ticket = ++gameReadSeqRef.current;
          const { data } = await supabase
            .from("games")
            .select(GAME_COLUMNS)
            .eq("id", target)
            .maybeSingle();

          // Skip if: gone, no longer the game on screen, or a later-issued
          // read already applied. Endings are left to the realtime ended
          // branch, which also sets the win banner.
          if (
            !data ||
            data.id !== activeGameIdRef.current ||
            ticket < gameAppliedSeqRef.current ||
            !LIVE_GAME_STATUSES.includes(data.status)
          ) {
            continue;
          }

          gameAppliedSeqRef.current = ticket;
          const previousStatus = lastGameStatusRef.current;
          lastGameStatusRef.current = data.status;
          setActiveGame(data);
          afterGameChange(data, previousStatus);
        } while (reconcileAgainRef.current);
      } finally {
        reconcileInFlightRef.current = false;
      }
    },
    [afterGameChange]
  );

  // MEMBERS READ (with the guard above): reads the roster and its profiles
  // and applies them -- replacing the roster, or merging by user_id if a
  // roster event arrived during the read. Returns an error message, or null.
  // poll: compare with the screen first, apply only a difference, and log it;
  // profiles are read only for players not already on screen. Otherwise
  // (a full refresh), also for a changed seat or a name never loaded.
  const loadMembers = useCallback(async (tableId: string, poll = false): Promise<string | null> => {
    for (let attempt = 0; ; attempt++) {
      const ticket = ++membersReadSeqRef.current;
      const eventsAtIssue = membersEventSeqRef.current;
      const { data: memberRows, error: membersError } = await supabase
        .from("table_members")
        .select(MEMBER_COLUMNS)
        .eq("table_id", tableId)
        // Seat order (clockwise); join order breaks a tie, as before.
        .order("seat", { ascending: true, nullsFirst: false })
        .order("joined_at", { ascending: true });
      if (membersError) return membersError.message;

      const rows = memberRows ?? [];
      const shownById = new Map(membersRef.current.map((m) => [m.user_id, m]));
      // Players already shown with their name, in the same seat, keep it
      // (profile edits arrive through realtime); a new seat, a rejoin or a
      // missing name is read (profilesToFetch, lib/tableSync.ts).
      const profileIds = profilesToFetch(
        rows.map((m) => ({ user_id: m.user_id, seat: m.seat ?? null })),
        membersRef.current,
        poll
      );
      const { data: profileRows } = profileIds.length
        ? await supabase.from("profiles").select("id, nickname, avatar_url").in("id", profileIds)
        : { data: [] as { id: string; nickname: string | null; avatar_url: string | null }[] };
      const profileById = new Map((profileRows ?? []).map((p) => [p.id, p]));

      // A later-issued read has already been applied: this one is older.
      if (ticket < membersAppliedSeqRef.current) return null;
      // A roster event arrived during this read: read again (twice at most),
      // then fall back to a merge that can't remove anyone. A poll just
      // stops -- realtime is clearly alive.
      const raced = membersEventSeqRef.current !== eventsAtIssue;
      if (raced && poll) return null;
      if (raced && attempt < 2) continue;

      const fresh: Member[] = rows.map((m) => {
        const profile = profileById.get(m.user_id) ?? shownById.get(m.user_id);
        return {
          user_id: m.user_id,
          joined_at: m.joined_at,
          seat: m.seat ?? null,
          nickname: profile?.nickname ?? null,
          avatar_url: profile?.avatar_url ?? null,
          score: m.score ?? 0,
          last_points: m.last_points,
          last_reason: m.last_reason,
          last_awarded_at: m.last_awarded_at,
        };
      });
      if (poll) {
        const diff = membersDiff(membersRef.current, fresh);
        if (diff.length === 0) return null;
        console.warn("[table-sync] poll repaired:", { members: diff });
      }
      membersAppliedSeqRef.current = ticket;
      setMembers((current) =>
        raced ? [...current, ...fresh.filter((m) => !current.some((c) => c.user_id === m.user_id))] : fresh
      );
      setMembersLoaded(true);
      return null;
    }
  }, []);

  // Fetches the current active game + full roster for a table. Used both for
  // the initial load and to "catch up" after the realtime connection drops
  // and reconnects, since postgres_changes only streams events that happen
  // while connected -- anything missed during a disconnect has to be re-fetched.
  const readTableState = useCallback(async (tableId: string) => {
    // Must find cutting games too, or a game mid-cut reads as "no game" and
    // the client would offer "New Game" for a table that already has one.
    const ticket = ++gameReadSeqRef.current;
    const { data: existingGame } = await supabase
      .from("games")
      .select(GAME_COLUMNS)
      .eq("table_id", tableId)
      .in("status", LIVE_GAME_STATUSES)
      .maybeSingle();

    // A read issued later (another refresh, or reconcileGame) has already
    // been applied: this result is older than what's on screen, so it must
    // not replace it. The roster below is still worth loading.
    const isLatestRead = ticket > gameAppliedSeqRef.current;
    if (isLatestRead) {
      gameAppliedSeqRef.current = ticket;
      setActiveGame(existingGame ?? null);
      // Set NOW, not one render later by the effect: realtime events for this
      // game may arrive before that render, and are matched against this.
      activeGameIdRef.current = existingGame?.id ?? null;
      lastGameStatusRef.current = existingGame?.status ?? null;
    }

    // A different hand from the one this client last set up -- missed while
    // disconnected, or reached by our own Next Hand / New Game tap before the
    // broadcast arrived. Everything below refetches anyway; this clears what
    // a refetch doesn't (sort, count status), and keeps the realtime handler
    // from resetting a second time when its event lands.
    const handKey = existingGame ? `${existingGame.id}:${existingGame.hand_no}` : null;
    if (isLatestRead && handKey !== handKeyRef.current) {
      resetHandState();
      handKeyRef.current = handKey;
    }

    // Everything that depends on the game row is skipped for a superseded
    // read, for the same reason as above: acting on an older phase (clearing
    // shown hands that a newer state still shows, say) would be a rollback.
    if (isLatestRead) {
      // No hand exists during 'cutting' -- that is the entire point of the phase.
      if (existingGame && existingGame.status === "active") {
        await fetchMyHand(existingGame.id);
        await fetchPlays(existingGame.id);
      } else {
        handAppliedSeqRef.current = ++handReadSeqRef.current; // outdates hand reads in flight
        setMyHand([]);
        setPlays([]);
      }

      // Both hands, and the crib from its count on, are readable only from
      // counting on (phase2-open-hands-in-count.sql).
      if (
        existingGame &&
        existingGame.status === "active" &&
        (existingGame.phase === "counting" || existingGame.phase === "done")
      ) {
        revealKeyRef.current = revealKey(existingGame);
        await fetchRevealed(existingGame.id);
      } else {
        clearRevealed();
      }

      // The result of the last game, if it was won -- so a reload, or a player
      // who reconnects after the winning point, still sees who won. Only while
      // no game is live: once the next one starts, the old result is history.
      if (existingGame) {
        showFinishedGame(null);
      } else {
        const { data: lastGame } = await supabase
          .from("games")
          .select(
            "id, created_at, ended_reason, winner_id, players, ready_by, starter_card, dealer_id, play_segment"
          )
          .eq("table_id", tableId)
          .order("created_at", { ascending: false })
          .limit(1)
          .maybeSingle();

        const finished: FinishedGame | null =
          lastGame && lastGame.ended_reason === "won"
            ? {
                id: lastGame.id,
                created_at: lastGame.created_at ?? null,
                winner_id: lastGame.winner_id,
                players: lastGame.players ?? [],
                ready_by: lastGame.ready_by ?? [],
                starter_card: lastGame.starter_card,
                dealer_id: lastGame.dealer_id,
                // The same won game already on screen with a fully read
                // board: keep it (nothing on it changes once the game has
                // ended) rather than read the three tables again.
                board: wonBoardReusable(finishedGameRef.current, lastGame.id)
                  ? finishedGameRef.current!.board
                  : await readWonBoard(lastGame.id, lastGame.play_segment ?? 0),
              }
            : null;

        // Still the newest read? The board read above is one more wait, and a
        // later read (a New Game starting, say) must not be undone by this.
        if (gameAppliedSeqRef.current === ticket) showFinishedGame(finished);
      }
    }

    // The roster, through the members read guard (loadMembers).
    const membersError = await loadMembers(tableId);
    if (membersError) setError(membersError);
    setTableRead(true);
  }, [fetchMyHand, fetchPlays, fetchRevealed, clearRevealed, resetHandState, showFinishedGame, loadMembers]);

  // Counted while in flight, so the safety poll waits for it.
  const refreshTableState = useCallback(
    async (tableId: string) => {
      refreshesInFlightRef.current++;
      try {
        await readTableState(tableId);
      } finally {
        refreshesInFlightRef.current--;
      }
    },
    [readTableState]
  );

  // Takes my seat at the table (idempotent) and loads it. setTable first, as
  // before: it starts the realtime subscription while the seat is written.
  const takeSeat = useCallback(
    async (row: TableRow, isCancelled: () => boolean) => {
      setTable(row);

      const { error: joinError } = await supabase
        .from("table_members")
        .upsert(
          { table_id: row.id, user_id: session!.user.id },
          { onConflict: "table_id,user_id", ignoreDuplicates: true }
        );

      if (isCancelled()) return;
      if (joinError) {
        setError(joinError.message);
        return;
      }

      await refreshTableState(row.id);
    },
    [session, refreshTableState]
  );

  // Look up the table, join it (idempotent), then load the current roster.
  // retryKey lets the error screen's "Retry" button re-run this from scratch.
  useEffect(() => {
    if (!session) return;

    let cancelled = false;

    async function setup() {
      setError(null);
      setClosedComputerTable(false);
      setPendingJoin(null);

      const { data: tableRow, error: tableError } = await supabase
        .from("tables")
        .select("id, code, status, ended_reason, is_muggins, created_by, max_players, team_mode, computer_level")
        .eq("code", code)
        .maybeSingle();

      if (cancelled) return;

      if (tableError) {
        setError(tableError.message);
        return;
      }
      if (!tableRow) {
        setError(`No table found with code ${code}.`);
        return;
      }
      if (tableRow.status !== "open") {
        setClosedComputerTable(Boolean(tableRow.computer_level));
        setError(tableEndedMessage(tableRow.ended_reason, tableRow.computer_level));
        return;
      }

      // Who is seated: for the nickname gate and the Muggins notice below.
      const { data: seats, error: seatsError } = await supabase
        .from("table_members")
        .select("user_id")
        .eq("table_id", tableRow.id);
      if (cancelled) return;
      const seated = (seats ?? []).map((m) => m.user_id);
      const isMember = !seatsError && seated.includes(session!.user.id);
      const isFull = !seatsError && seated.length >= (tableRow.max_players ?? 2);

      // THE NICKNAME GATE. A NEW seat needs a nickname first: off to the
      // nickname step, back to this table after. Never a player already
      // seated (mid-game, a refresh, Rejoin), never a full table (the server
      // refuses the seat as before), and not when the seats or the profile
      // can't be read -- someone mid-game must never be locked out by a
      // failed read. Client-side only (the PRD, 11.6).
      if (!seatsError && !isMember && !isFull) {
        const needs = await fetchNeedsNickname(session!.user.id);
        if (cancelled) return;
        if (needs === true) {
          setToNickname(true);
          router.replace(nicknameStepHref(`/tables/${tableRow.code}`));
          return;
        }
      }

      // THE JOINER'S MUGGINS NOTICE. A Muggins table asks a new player to
      // agree before they are seated: not the creator (they agreed when
      // creating), not a player already seated (a refresh, Rejoin), and not
      // a full table (all max_players seats taken), which goes on exactly as
      // before: the seat is refused by the server ("This table is full.").
      // If the seats can't be read, ask anyway -- never seat without
      // agreement.
      if (tableRow.is_muggins && tableRow.created_by !== session!.user.id) {
        if (!isMember && !isFull) {
          setPendingJoin(tableRow);
          return;
        }
      }

      await takeSeat(tableRow, () => cancelled);
    }

    setup();

    return () => {
      cancelled = true;
    };
  }, [session, code, retryKey, takeSeat, router]);

  // Creating the game and dealing are one atomic server-side action now. The
  // shuffle happens inside Postgres, so no browser ever receives the full deck
  // -- which is what makes the deal fair even to whoever clicked the button.
  async function handleStartNewGame() {
    if (!table || !session) return;

    setGameStatus("creating");
    setGameMessage(null);
    setGameEndedNotice(null);
    // The result is NOT cleared here: after a won match the tap may only be
    // recorded (the ready gate), and the result stays up while we wait. It
    // goes when the new game arrives -- the re-read below, or its INSERT.

    const { data: newGameId, error: rpcError } = await trackAction(
      supabase.rpc("start_game_with_deal", {
        p_table_id: table.id,
      })
    );

    if (rpcError) {
      // The function's own guards (not a member, table closed, wrong player
      // count) surface here as readable messages.
      setGameStatus("error");
      setGameMessage(rpcError.message);
      return;
    }

    // NULL: the New Game ready gate recorded the tap (or already had it) and
    // is waiting for the other player -- not an error, and nothing was dealt.
    // A null always means this player is in the won game's ready_by, so it's
    // shown at once rather than after the realtime echo; the re-read confirms
    // it from the server (and finds the game, if the other tap has since
    // started it).
    if (newGameId === null) {
      const myId = session.user.id;
      setFinishedGame((current) =>
        current ? { ...current, ready_by: unionIds(current.ready_by, [myId]) } : current
      );
      await refreshTableState(table.id);
      setGameStatus("idle");
      return;
    }

    // Re-read rather than trusting a local guess: on a simultaneous-click race
    // the function may have handed us back someone else's game, and our hand
    // has to come from the server regardless.
    await refreshTableState(table.id);
    setHandSorted(false); // genuinely new hand -- show it as dealt
    setGameStatus("idle");
  }

  // THE WAITING ROOM's move (3 and 4 players, the host only): the picked
  // player goes to the tapped seat -- an empty seat moves them, an occupied
  // one swaps the two (set_seat does either in one call). The pick clears
  // after the call whether it worked or not; a refusal is shown word for
  // word. The roster is re-read either way, so the screen matches the
  // server even if a realtime event is missed (the poll would also repair
  // it).
  async function handleSeatMove(seat: number) {
    if (!table || !seatPick || seatStatus === "sending") return;
    const userId = seatPick;
    setSeatStatus("sending");
    setSeatMessage(null);

    const { error: rpcError } = await trackAction(
      supabase.rpc("set_seat", {
        p_table_id: table.id,
        p_user_id: userId,
        p_seat: seat,
      })
    );

    setSeatPick(null);
    if (rpcError) {
      setSeatStatus("error");
      setSeatMessage(rpcError.message);
    } else {
      setSeatStatus("idle");
    }
    await loadMembers(table.id);
  }

  async function handleLeave() {
    if (!table) return;

    setLeaveStatus("leaving");
    setLeaveMessage(null);

    // A computer table closes when its player leaves (both seats go, and
    // the table ends): leave_computer_table. Every other table: leave_table.
    const { error: rpcError } = await trackAction(
      supabase.rpc(table.computer_level ? "leave_computer_table" : "leave_table", {
        p_table_id: table.id,
      })
    );

    if (rpcError) {
      setLeaveStatus("error");
      setLeaveMessage(rpcError.message);
      setLeaveConfirming(false);
      return;
    }

    // Navigating away matters as much as the delete: the setup effect re-joins
    // (upserts table_members) on every visit to this URL, so staying here would
    // silently put us straight back at the table we just left.
    router.push("/");
  }

  // Draws THIS player's cut card. The card does not exist until this call --
  // the server picks it, excluding anything already drawn this round, and
  // returns it. Nothing about the dealer is known beforehand.
  async function handleDrawCutCard(): Promise<string | null> {
    if (!activeGame) return "No active game.";

    const { error: rpcError } = await trackAction(
      supabase.rpc("draw_cut_card", {
        p_game_id: activeGame.id,
      })
    );

    if (rpcError) return rpcError.message;

    // Our own draw comes back through the games UPDATE broadcast too, but
    // re-reading makes the card appear immediately for the player who tapped.
    if (table) await refreshTableState(table.id);
    return null;
  }

  // Acknowledges a completed round. On a tie the server opens a fresh round;
  // on a decisive round it DEALS. Either way it only acts once every player has
  // acknowledged -- one player clicking moves nobody's screen. Returns an error
  // message rather than setting page state, since the cut view fills the screen.
  async function handleAcknowledgeCut(): Promise<string | null> {
    if (!activeGame) return "No active game.";

    const { error: rpcError } = await trackAction(
      supabase.rpc("acknowledge_deal_cut", {
        p_game_id: activeGame.id,
      })
    );

    if (rpcError) return rpcError.message;

    if (table) await refreshTableState(table.id);
    return null;
  }

  // Plays one card. Everything that follows -- whether the opponent can
  // answer, whether a go gets recorded, whether the count resets, whether the
  // hand is over -- is resolved server-side inside this one call.
  async function handlePlayCard(card: string) {
    if (!activeGame) return;

    setPlayStatus("sending");
    setPlayMessage(null);

    const { error: rpcError } = await trackAction(
      supabase.rpc("play_card", {
        p_game_id: activeGame.id,
        p_card: card,
      })
    );

    if (rpcError) {
      // The function's guards (not your turn, not your card, over 31) surface
      // here as readable messages. The UI tries to make these unreachable, but
      // the server is what actually enforces them.
      setPlayStatus("error");
      setPlayMessage(rpcError.message);
      return;
    }

    if (table) await refreshTableState(table.id);
    setPlayStatus("idle");
  }

  // The three counting actions share one status line. Each is one locked RPC;
  // the server decides everything, including the points -- the client only
  // ever says which game, and for Confirm Count, which step it is looking at.
  async function runCountAction(rpc: () => PromiseLike<{ error: { message: string } | null }>) {
    setCountStatus("sending");
    setCountMessage(null);

    const { error: rpcError } = await trackAction(rpc());

    if (rpcError) {
      setCountStatus("error");
      setCountMessage(rpcError.message);
      return;
    }

    if (table) await refreshTableState(table.id);
    setCountStatus("idle");
  }

  // MUGGINS: the win bar's three calls. Each is one locked RPC; the server
  // enforces every rule (Muggins table, live game, a player, one claim at a
  // time, only the claimant cancels, never confirm your own claim), and a
  // refusal shows its message above the bar while the bar follows the real
  // claim. Afterwards the game is re-read: a claim or cancel through
  // reconcileGame; a confirm through the full refresh, because the match has
  // ENDED (reconcileGame leaves endings alone) and the refresh is what shows
  // the won screen if the ending's event is missed.
  async function runWinAction(fn: "claim_win" | "clear_win_claim" | "confirm_win") {
    if (!activeGame || !table) return;
    const gameId = activeGame.id;
    setWinSending(true);
    setWinError(null);

    const { error: rpcError } = await trackAction(supabase.rpc(fn, { p_game_id: gameId }));

    if (rpcError) setWinError({ gameId, message: rpcError.message });
    if (fn === "confirm_win" && !rpcError) await refreshTableState(table.id);
    else await reconcileGame(gameId);
    setWinSending(false);
  }

  // p_step is the step THIS screen is showing. If the server has already moved
  // past it (a double tap, a second tab) the call returns quietly instead of
  // scoring twice; a step ahead of the server is rejected.
  //
  // THE CRIB (step 2 with 2 players, step N with N): there's no Show Crib
  // tap -- the crib is already face-up on every screen (the read policy opens
  // it at its step) -- but confirm_count still requires crib_revealed (its
  // Guard 9), so the dealer's Confirm sets it first. show_crib is a quiet
  // no-op if it's already set; if confirm_count then fails, the crib was
  // face-up anyway.
  function handleConfirmCount(step: number) {
    if (!activeGame) return;
    const gameId = activeGame.id;
    const cribStep = cribStepFor(activeGame.players);
    return runCountAction(async () => {
      if (step === cribStep) {
        const shown = await supabase.rpc("show_crib", { p_game_id: gameId });
        if (shown.error) return shown;
      }
      return supabase.rpc("confirm_count", { p_game_id: gameId, p_step: step });
    });
  }

  // Marks this player ready for the next hand; the tap that makes EVERY
  // player ready deals it (the ready gate, phase2-batch2b-ready-gate.sql).
  // hand_no is the hand THIS screen is showing: a tap that arrives after the
  // deal, or a repeat tap, returns quietly -- no error. Shares the counting
  // status line, so the button disables while the call is in flight; after
  // that, "already tapped" keeps it disabled via ready_by, not local state.
  function handleNextHand() {
    if (!activeGame) return;
    const gameId = activeGame.id;
    const handNo = activeGame.hand_no;
    return runCountAction(() =>
      supabase.rpc("next_hand", { p_game_id: gameId, p_hand_no: handNo })
    );
  }

  function toggleCardSelection(card: string) {
    setDiscardMessage(null);
    setSelectedCards((current) => {
      if (current.includes(card)) return current.filter((c) => c !== card);
      // Silently ignore a third pick rather than swapping one out -- swapping
      // would make it unclear which card you just deselected.
      if (current.length >= sizesFor(activeGame?.players).discard) return current;
      return [...current, card];
    });
  }

  async function handleDiscard() {
    if (!activeGame || selectedCards.length !== sizesFor(activeGame.players).discard) return;

    setDiscardStatus("sending");
    setDiscardMessage(null);

    const gameId = activeGame.id;
    const { error: rpcError } = await trackAction(
      supabase.rpc("discard_to_crib", {
        p_game_id: gameId,
        p_cards: selectedCards,
      })
    );

    if (rpcError) {
      // The function's guards (already discarded, not your card, game no longer
      // active) surface here as readable messages.
      setDiscardStatus("error");
      setDiscardMessage(rpcError.message);
      return;
    }

    // TABLE SYNC: my four kept cards, read directly. The re-read below skips
    // its hand read when a newer games read (a reconcile after this discard's
    // own broadcasts) lands first -- which left the six dealt cards on
    // screen. This read is ordered by the hand tickets, not the game ones.
    fetchMyHand(gameId);

    // Re-read for the same reason as above: the hand and discarded_by are both
    // server-owned now. The opponent learns about this via the games UPDATE
    // broadcast, which carries discarded_by but never the crib's contents.
    if (table) await refreshTableState(table.id);
    setDiscardStatus("idle");
  }

  // Live updates: append anyone who joins after we've loaded the roster.
  useEffect(() => {
    if (!table) return;

    const channel = supabase
      .channel(`table-members-${table.id}`)
      .on(
        "postgres_changes",
        {
          event: "INSERT",
          schema: "public",
          table: "table_members",
          filter: `table_id=eq.${table.id}`,
        },
        async (payload) => {
          membersEventSeqRef.current++; // see the members read guard
          const newRow = payload.new as {
            user_id: string;
            joined_at: string;
            seat: number | null;
            score: number | null;
          };

          setMembers((current) => {
            if (current.some((m) => m.user_id === newRow.user_id)) {
              return current; // already have it (e.g. our own join)
            }
            return [
              ...current,
              {
                user_id: newRow.user_id,
                joined_at: newRow.joined_at,
                seat: newRow.seat ?? null,
                nickname: null,
                avatar_url: null,
                // A joining player starts at 0 with nothing to explain yet.
                score: newRow.score ?? 0,
                last_points: null,
                last_reason: null,
                last_awarded_at: null,
              },
            ];
          });

          const { data: profile } = await supabase
            .from("profiles")
            .select("nickname, avatar_url")
            .eq("id", newRow.user_id)
            .maybeSingle();

          if (profile) {
            setMembers((current) =>
              current.map((m) =>
                m.user_id === newRow.user_id
                  ? { ...m, nickname: profile.nickname, avatar_url: profile.avatar_url }
                  : m
              )
            );
          }
        }
      )
      .on(
        "postgres_changes",
        {
          event: "UPDATE",
          schema: "public",
          table: "table_members",
          filter: `table_id=eq.${table.id}`,
        },
        (payload) => {
          membersEventSeqRef.current++; // see the members read guard
          // The score tracker's live channel. award_points() is the only thing
          // that writes these columns, so in practice every event here is a
          // score change -- the number moves on both screens at once, and the
          // "+2 — pair" flash fires off last_awarded_at changing.
          //
          // table_members has been in the realtime publication since Slice 4
          // with UPDATE already enabled, so this listener needed no SQL at all.
          // A seat move (set_seat, before a game) arrives here too: the seat
          // is merged, and the score columns come back unchanged.
          const updated = payload.new as {
            user_id: string;
            seat?: number | null;
            score: number | null;
            last_points: number | null;
            last_reason: string | null;
            last_awarded_at: string | null;
          };

          // THE "19" SPLASH: a hand or crib just counted for 0 (confirm_count
          // awards 0 as "hand: nothing" / "crib: nothing"). Only while a game
          // is live, and only an award made by THIS change: its time (now()
          // in the awarding transaction) within seconds of the commit. A
          // seat move, or a Teams partner's row (award_points moves the
          // partner's score but keeps their last award), re-sends an older
          // one. NOT compared with the award on screen -- after a confirm
          // (mine, or the computer's from this tab) the re-read can put this
          // very award there before this event arrives. The key stops a
          // repeat.
          const shown = membersRef.current.find((m) => m.user_id === updated.user_id);
          const awardAge = updated.last_awarded_at
            ? Date.parse(payload.commit_timestamp) - Date.parse(updated.last_awarded_at)
            : NaN;
          if (
            updated.last_points === 0 &&
            isCountReason(updated.last_reason) &&
            updated.last_awarded_at &&
            activeGameRef.current?.status === "active" &&
            // An unreadable commit time doesn't block the splash.
            (Number.isNaN(awardAge) || Math.abs(awardAge) < 10_000)
          ) {
            showZero(
              `zero:${updated.user_id}:${Date.parse(updated.last_awarded_at)}`,
              displayName(shown),
              updated.last_reason!.startsWith("crib:")
            );
          }

          setMembers((current) =>
            current.map((m) =>
              m.user_id === updated.user_id
                ? {
                    ...m,
                    seat: updated.seat !== undefined ? updated.seat : m.seat,
                    score: updated.score ?? m.score,
                    last_points: updated.last_points,
                    last_reason: updated.last_reason,
                    last_awarded_at: updated.last_awarded_at,
                  }
                : m
            )
          );
        }
      )
      .on(
        "postgres_changes",
        {
          event: "DELETE",
          schema: "public",
          table: "table_members",
          filter: `table_id=eq.${table.id}`,
        },
        (payload) => {
          membersEventSeqRef.current++; // see the members read guard
          // DELETE payloads only carry the row's replica identity columns,
          // which defaults to the primary key -- here (table_id, user_id).
          // That's exactly what's needed: table_id for the filter above,
          // user_id to know who to drop from the roster.
          const goneRow = payload.old as { user_id?: string };
          if (!goneRow?.user_id) return;

          setMembers((current) => current.filter((m) => m.user_id !== goneRow.user_id));
        }
      )
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "game_plays" },
        (payload) => {
          const event = payload.new as PlayEvent & { game_id: string };

          // Unfiltered subscription, filtered here instead. game_plays has no
          // table_id to match this channel's table filter on, and the active
          // game changes within a table -- a game_id filter baked into the
          // subscription would go stale on the next "New Game". Same approach
          // as the profiles UPDATE listener: at this scale, letting the client
          // discard what isn't its own is simpler than re-subscribing.
          if (event.game_id !== activeGameIdRef.current) return;

          // THE GO SPLASH: once per player per run -- a player stuck for
          // several plays logs a go each time, like the one Go label.
          if (event.kind === "go") {
            showGo(`go:${event.game_id}:${activeGameRef.current?.hand_no}:${event.segment}:${event.user_id}`);
          }

          setPlays((current) => {
            if (current.some((p) => p.seq === event.seq)) return current; // already have it
            return [...current, event].sort((a, b) => a.seq - b.seq);
          });
        }
      )
      .on(
        "postgres_changes",
        { event: "UPDATE", schema: "public", table: "profiles" },
        (payload) => {
          const updated = payload.new as { id: string; nickname: string; avatar_url: string | null };

          setMembers((current) =>
            current.map((m) =>
              m.user_id === updated.id
                ? { ...m, nickname: updated.nickname, avatar_url: updated.avatar_url }
                : m
            )
          );
        }
      )
      .on(
        "postgres_changes",
        {
          event: "INSERT",
          schema: "public",
          table: "games",
          filter: `table_id=eq.${table.id}`,
        },
        (payload) => {
          gameEventSeqRef.current++; // see the safety poll
          const newGame = payload.new as {
            id: string;
            created_at: string;
            status: string;
            players: string[] | null;
            dealer_id: string | null;
            discarded_by: string[] | null;
            deal_cut: DealCutRound[] | null;
            deal_cut_ack_by: string[] | null;
            starter_card: string | null;
            phase: string | null;
            current_player: string | null;
            play_count: number | null;
            play_segment: number | null;
            count_step: number | null;
            revealed_by: string[] | null;
            crib_revealed: boolean | null;
            winner_id: string | null;
            hand_no: number | null;
            ready_by: string[] | null;
            win_claim_by: string | null;
            win_confirmed_by?: string[] | null;
          };
          // A new game arrives as EITHER 'cutting' (no decisive previous
          // result -- first game, a non-win ending, a changed roster: cut for
          // deal, no cards yet) or 'active' (a rematch after a win: the loser
          // deals, cards already dealt). Both are a brand-new game id, so the
          // last game's result and every per-hand trace of it go.
          //
          // If both players tapped New Game, only ONE insert happens -- the
          // slower call is handed the faster one's game -- so this fires once
          // and both screens land in the same game.
          if (LIVE_GAME_STATUSES.includes(newGame.status)) {
            // The player who tapped New Game usually has this game already:
            // handleStartNewGame re-reads it straight after the call. The
            // INSERT payload is the row as first created, so applying it now
            // could roll back anything that has happened since (a discard, a
            // cut card). Keep what we have.
            if (newGame.id === activeGameIdRef.current) {
              setGameEndedNotice(null);
              showFinishedGame(null);
              return;
            }
            setActiveGame({
              id: newGame.id,
              created_at: newGame.created_at,
              status: newGame.status,
              players: newGame.players,
              dealer_id: newGame.dealer_id,
              discarded_by: newGame.discarded_by ?? [],
              deal_cut: newGame.deal_cut,
              deal_cut_ack_by: newGame.deal_cut_ack_by ?? [],
              starter_card: newGame.starter_card,
              phase: newGame.phase ?? "discard",
              current_player: newGame.current_player,
              play_count: newGame.play_count ?? 0,
              play_segment: newGame.play_segment ?? 0,
              count_step: newGame.count_step ?? 0,
              revealed_by: newGame.revealed_by ?? [],
              crib_revealed: newGame.crib_revealed ?? false,
              winner_id: newGame.winner_id,
              hand_no: newGame.hand_no ?? 1,
              ready_by: newGame.ready_by ?? [],
              win_claim_by: newGame.win_claim_by ?? null,
              win_confirmed_by: newGame.win_confirmed_by ?? [],
            });
            // Set NOW, not one render later: the UPDATEs that follow (a
            // discard, a cut card) are matched against this, and can arrive
            // before that render.
            activeGameIdRef.current = newGame.id;
            lastGameStatusRef.current = newGame.status;
            setGameEndedNotice(null); // stale once a fresh game is under way
            showFinishedGame(null); // likewise the last game's result -- the win banner
            // Plays, selection, sort, shown hands, crib, count status. Scores
            // need nothing here: start_game_with_deal reset them, and those
            // table_members UPDATEs arrive on their own -- with last_points
            // null, so the plates move to 0 without a flash.
            resetHandState();
            handKeyRef.current = `${newGame.id}:${newGame.hand_no ?? 1}`;
            // Only fetch a hand if one can exist. During 'cutting' there are no
            // cards at all, which is the whole point of the phase.
            if (newGame.status === "active") fetchMyHand(newGame.id);
            // The INSERT payload is the row as first created. If anything has
            // already changed it, this brings the screen up to date.
            reconcileGame(newGame.id);
          }
        }
      )
      .on(
        "postgres_changes",
        {
          event: "UPDATE",
          schema: "public",
          table: "games",
          filter: `table_id=eq.${table.id}`,
        },
        (payload) => {
          gameEventSeqRef.current++; // see the safety poll
          const updatedGame = payload.new as {
            id: string;
            created_at?: string | null;
            status: string;
            ended_reason: string | null;
            players: string[] | null;
            dealer_id: string | null;
            discarded_by: string[] | null;
            deal_cut: DealCutRound[] | null;
            deal_cut_ack_by: string[] | null;
            starter_card: string | null;
            phase: string | null;
            current_player: string | null;
            play_count: number | null;
            play_segment: number | null;
            count_step: number | null;
            revealed_by: string[] | null;
            crib_revealed: boolean | null;
            winner_id: string | null;
            hand_no: number | null;
            ready_by: string[] | null;
            win_claim_by: string | null;
            win_confirmed_by?: string[] | null;
          };
          // THE WON GAME ON SCREEN: its only change after it ends is a New
          // Game tap (ready_by). Merge that and nothing else -- a union, so an
          // event and a re-read can land in either order. Everything else
          // about ended games stays ignored, as below.
          if (
            updatedGame.id === finishedGameIdRef.current &&
            !LIVE_GAME_STATUSES.includes(updatedGame.status)
          ) {
            const readyBy: string[] = updatedGame.ready_by ?? [];
            setFinishedGame((current) =>
              current && current.id === updatedGame.id
                ? { ...current, ready_by: unionIds(current.ready_by, readyBy) }
                : current
            );
            return;
          }

          // ONLY THE GAME ON SCREEN. This subscription is per TABLE, so it
          // also carries rows for other games at the table. Before this check,
          // the merge below folded whatever game's row arrived into the one on
          // screen (keeping the old id), and any game ending cleared the
          // screen -- including an old game's.
          if (updatedGame.id !== activeGameIdRef.current) {
            // A live game we aren't showing means we missed how it arrived
            // (its INSERT, or a reconnect). Re-read rather than guess.
            if (LIVE_GAME_STATUSES.includes(updatedGame.status)) {
              refreshTableState(table.id);
            }
            return;
          }

          const previousStatus = lastGameStatusRef.current;
          lastGameStatusRef.current = updatedGame.status;

          // STATUS BEFORE PHASE. An ended game can carry any phase -- a win on
          // his heels leaves phase 'play', a win mid-count leaves 'counting' --
          // so nothing below may look at phase until status has said the game
          // is still live.
          //
          // Ended, by a win, an admin force-end, a departing player, or the
          // timeout. 'cutting' is a LIVE status, so this check can't be "not
          // active" -- that would treat every cut as an ended game.
          if (!LIVE_GAME_STATUSES.includes(updatedGame.status)) {
            setActiveGame(null);
            activeGameIdRef.current = null;
            handAppliedSeqRef.current = ++handReadSeqRef.current; // outdates hand reads in flight
            setMyHand([]);
            setSelectedCards([]);
            clearRevealed();
            setCountStatus("idle");
            setCountMessage(null);
            lastGameStatusRef.current = null;
            handKeyRef.current = null;
            if (updatedGame.ended_reason === "won") {
              // The winner and final scores render from this plus the
              // roster, whose 121 arrives on its own table_members UPDATE.
              // THE FINAL BOARD: the starter, the dealer, the last run and my
              // hand, shown at once from what's already on screen; the
              // opponent's hand and the crib aren't on screen yet (face-down
              // until the read below brings them).
              const segment = updatedGame.play_segment ?? 0;
              const mine = myHandRef.current;
              showFinishedGame({
                id: updatedGame.id,
                created_at: updatedGame.created_at ?? null,
                winner_id: updatedGame.winner_id,
                players: updatedGame.players ?? [],
                ready_by: updatedGame.ready_by ?? [],
                starter_card: updatedGame.starter_card,
                dealer_id: updatedGame.dealer_id,
                board: {
                  finalRun: finalRunOf(playsRef.current, segment),
                  // Only the kept four: a his-heels win can land before my
                  // post-discard refetch, while the six dealt are still here.
                  hands:
                    mine && mine.cards.length === sizesFor(updatedGame.players).kept
                      ? { [mine.userId]: mine.cards }
                      : {},
                  crib: null,
                },
              });
              // Then the whole board from the server: the opponent's hand
              // and the crib (never broadcast -- they can only be read), and
              // the run again (the winning card's own INSERT is matched
              // against the game on screen, which this branch has just
              // cleared -- if it ever arrived after this UPDATE, it was
              // dropped). Applied only if this won game is still on screen.
              const wonId = updatedGame.id;
              readWonBoard(wonId, segment).then((board) =>
                setFinishedGame((current) =>
                  current && current.id === wonId ? { ...current, board } : current
                )
              );
            }
            // Deliberately doesn't name the leaver: the roster DELETE arrives
            // as a separate event with no ordering guarantee, so building the
            // name in here would race. The roster visibly updating alongside
            // this already shows *who* left.
            if (updatedGame.ended_reason === "player_left") {
              setGameEndedNotice("A player left the table — the game was ended.");
            }
            return;
          }

          // Otherwise the game is live and something moved: a cut card, an
          // acknowledgement, a discard, the starter, a play, a count, a reveal,
          // a new hand. None of it ever carries a hand or the crib.
          //
          // Applied straight away so the screen reacts instantly -- but this
          // payload is a snapshot after ONE statement, and is not trusted to be
          // the final word. reconcileGame (below) re-reads the row and shows
          // what the database actually holds.
          setActiveGame((current) =>
            current && current.id === updatedGame.id
              ? {
                  ...current,
                  status: updatedGame.status,
                  players: updatedGame.players ?? current.players,
                  dealer_id: updatedGame.dealer_id,
                  discarded_by: updatedGame.discarded_by ?? [],
                  deal_cut: updatedGame.deal_cut ?? current.deal_cut,
                  deal_cut_ack_by: updatedGame.deal_cut_ack_by ?? [],
                  starter_card: updatedGame.starter_card,
                  phase: updatedGame.phase ?? current.phase,
                  current_player: updatedGame.current_player,
                  play_count: updatedGame.play_count ?? 0,
                  play_segment: updatedGame.play_segment ?? 0,
                  count_step: updatedGame.count_step ?? 0,
                  revealed_by: updatedGame.revealed_by ?? [],
                  crib_revealed: updatedGame.crib_revealed ?? false,
                  winner_id: updatedGame.winner_id,
                  hand_no: updatedGame.hand_no ?? current.hand_no,
                  ready_by: updatedGame.ready_by ?? [],
                  win_claim_by: updatedGame.win_claim_by ?? null,
                  // A payload without the column (a stale row) keeps what
                  // the screen has, rather than wiping the confirmations.
                  win_confirmed_by: updatedGame.win_confirmed_by ?? current.win_confirmed_by ?? [],
                }
              : current
          );

          // New hand, reveals, cut resolved -- the same follow-ups a fresh
          // read triggers, so the two paths can't drift apart.
          afterGameChange(updatedGame, previousStatus);

          // And end every burst of events with an authoritative read.
          reconcileGame(updatedGame.id);
        }
      )
      .on(
        "postgres_changes",
        {
          event: "UPDATE",
          schema: "public",
          table: "tables",
          filter: `id=eq.${table.id}`,
        },
        (payload) => {
          const updatedTable = payload.new as {
            status: string;
            ended_reason: string | null;
            computer_level?: string | null;
          };
          if (updatedTable.status !== "open" && !leavingRef.current) {
            const level = updatedTable.computer_level ?? table.computer_level;
            setClosedComputerTable(Boolean(level));
            setError(tableEndedMessage(updatedTable.ended_reason, level));
          }
        }
      )
      .subscribe((status) => {
        if (status === "SUBSCRIBED") {
          setRealtimeStatus("connected");
          // CATCH UP on EVERY subscribe, the first one included.
          // postgres_changes only streams events that happen while
          // subscribed: after a reconnect anything that changed while we were
          // down (a join, a new game, a nickname edit) was missed -- and on
          // the FIRST subscribe, anything between the setup effect's reads
          // and this moment was too (TABLE SYNC, gap A). The read tickets
          // keep this from rolling anything back.
          refreshTableState(table.id);
        } else if (status === "CLOSED" || status === "TIMED_OUT" || status === "CHANNEL_ERROR") {
          setRealtimeStatus("disconnected");
        }
      });

    return () => {
      supabase.removeChannel(channel);
    };
  }, [table, refreshTableState, fetchMyHand, clearRevealed, resetHandState, afterGameChange, reconcileGame, showFinishedGame, showZero, showGo]);

  // TABLE SYNC: CATCH UP when the tab becomes visible again or the device
  // comes back online -- the same full refresh as on subscribe. A hidden tab
  // or a sleeping device can lose events without the channel ever reporting
  // it. Not once the table has ended.
  useEffect(() => {
    if (!table) return;
    const catchUp = () => {
      if (document.visibilityState !== "visible" || errorRef.current) return;
      refreshTableState(table.id);
    };
    document.addEventListener("visibilitychange", catchUp);
    window.addEventListener("online", catchUp);
    return () => {
      document.removeEventListener("visibilitychange", catchUp);
      window.removeEventListener("online", catchUp);
    };
  }, [table, refreshTableState]);

  // TABLE SYNC: THE SAFETY POLL. While the tab is visible, every
  // SAFETY_POLL_MS (12 s) -- or SAFETY_POLL_CONNECTED_MS (30 s) while the
  // channel reports SUBSCRIBED (pollIntervalMs, lib/tableSync.ts) -- a LIGHT read -- the table's live game row and the roster -- to
  // repair anything a missed realtime event left wrong. Skipped while the tab
  // is hidden, while one of my actions or a full refresh is in flight, and
  // once the table has ended. A difference is applied (the game through
  // reconcileGame and its tickets, the roster through the members guard) and
  // logged as "[table-sync] poll repaired:", so a missed event shows in the
  // console instead of being silently hidden.
  // "Connected" is exactly the channel's last status being SUBSCRIBED
  // (realtimeStatus, set in the subscribe callback above); "connecting"
  // (startup) and "disconnected" (CLOSED, TIMED_OUT, CHANNEL_ERROR) poll at
  // 12 s.
  const realtimeConnected = realtimeStatus === "connected";
  useEffect(() => {
    if (!table) return;
    const tableId = table.id;
    let polling = false;

    async function pollOnce() {
      const eventsAtIssue = gameEventSeqRef.current;
      const shown = activeGameRef.current;
      const { data: fresh, error: gameError } = await supabase
        .from("games")
        .select(GAME_COLUMNS)
        .eq("table_id", tableId)
        .in("status", LIVE_GAME_STATUSES)
        .maybeSingle();
      // A games event arrived during the read: realtime is alive and the
      // screen may be newer than this read. Don't compare.
      if (!gameError && gameEventSeqRef.current === eventsAtIssue) {
        if (fresh?.id !== shown?.id) {
          // A new game, or the end of one, was missed: the full refresh
          // rebinds everything (hands, plays, the result).
          console.warn("[table-sync] poll repaired:", {
            game: `live game ${shown?.id ?? "none"} -> ${fresh?.id ?? "none"}`,
          });
          await refreshTableState(tableId);
        } else if (fresh && shown) {
          const diff = gameDiff(shown, fresh);
          if (diff.length > 0) {
            console.warn("[table-sync] poll repaired:", { game: diff });
            await reconcileGame(fresh.id);
            // The play log is read, never derived from the row: a missed
            // play's row change means its play event was missed too.
            if (fresh.status === "active") await fetchPlays(fresh.id);
          }
        }
      }
      await loadMembers(tableId, true);
    }

    const timer = window.setInterval(() => {
      if (
        polling ||
        document.visibilityState !== "visible" ||
        errorRef.current ||
        actionsInFlightRef.current > 0 ||
        refreshesInFlightRef.current > 0 ||
        reconcileInFlightRef.current
      ) {
        return;
      }
      polling = true;
      pollOnce().finally(() => {
        polling = false;
      });
    }, pollIntervalMs(realtimeConnected));
    return () => window.clearInterval(timer);
    // realtimeConnected: a change of channel status restarts the interval at
    // the new pace, so a disconnect is back to 12 s at once.
  }, [table, refreshTableState, reconcileGame, loadMembers, fetchPlays, realtimeConnected]);

  // Keeps the ref above in step with state. Assigning a ref is not a state
  // update, so this is a legitimate effect rather than a cascading render.
  useEffect(() => {
    activeGameIdRef.current = activeGame?.id ?? null;
  }, [activeGame?.id]);
  useEffect(() => {
    finishedGameRef.current = finishedGame;
  }, [finishedGame]);

  // The starter's slide is over once it has had its time: a starter mounted
  // again later in the same count just sits in its place.
  useEffect(() => {
    if (!starterLiveKey) return;
    const timer = window.setTimeout(() => setStarterLiveKey(null), STARTER_SLIDE_MS + 100);
    return () => window.clearTimeout(timer);
  }, [starterLiveKey]);

  // THE COMPUTER OPPONENT (a computer table this user created): its moves,
  // made from this browser. Only while the table is open on this screen and
  // not being left. The other seated member is the computer; the server's
  // guard checks that too. "Count hands" not yet tapped holds its counting
  // back, so the human sees pegging end first.
  const myUserId = session?.user.id ?? null;
  const computerTable = Boolean(table?.computer_level) && table?.created_by === myUserId;
  useComputerDriver({
    enabled: computerTable && !error && leaveStatus !== "leaving",
    tableId: table?.id ?? null,
    level: table?.computer_level ?? null,
    computerId: computerTable ? (members.find((m) => m.user_id !== myUserId)?.user_id ?? null) : null,
    tableFull: members.length === (table?.max_players ?? 2),
    humanHoldsPegging: Boolean(activeGame) && pegHoldKey === `${activeGame?.id}:${activeGame?.hand_no}`,
    game: activeGame,
    finished: finishedGame
      ? { id: finishedGame.id, players: finishedGame.players, ready_by: finishedGame.ready_by }
      : null,
    humanHand: myHand,
    trackAction,
    refresh: async () => {
      if (table) await refreshTableState(table.id);
    },
  });

  // .table-loading: painted in this device's cached surface from the first
  // paint (app/globals.css), so a refresh doesn't flash Classic.
  if (loading || !appearance.ready || toNickname) {
    return (
      <main className="table-loading flex flex-1 items-center justify-center">
        <p>Loading...</p>
      </main>
    );
  }

  // Not logged in, and table not found / load failed: the card-room look
  // (CardRoomFrame), not the player's table surface -- there is no table here.
  if (!session) {
    return (
      <CardRoomFrame backHome={false}>
        <p>You need to be logged in to join a table.</p>
        <Link href="/login" className="peg-btn peg-btn--brass">
          Log in
        </Link>
      </CardRoomFrame>
    );
  }

  if (error) {
    return (
      <CardRoomFrame backHome={false}>
        <p className="text-[var(--error-on-felt)]">{error}</p>
        {closedComputerTable ? (
          // A closed computer table: there's nothing to retry or rejoin.
          <div className="flex flex-col gap-2.5">
            <Link href="/" className="peg-btn peg-btn--brass">
              Back to home
            </Link>
          </div>
        ) : (
          <div className="flex flex-col gap-2.5">
            <button
              onClick={() => setRetryKey((k) => k + 1)}
              className="peg-btn peg-btn--brass"
            >
              Retry
            </button>
            <Link href="/tables/join" className="peg-btn peg-btn--ghost">
              Try a different code
            </Link>
          </div>
        )}
      </CardRoomFrame>
    );
  }

  // THE JOINER'S MUGGINS NOTICE, before any seat or table content. "Join
  // Self-Scoring (Muggins) table" takes the seat and loads the table; Go back (or Escape,
  // or the backdrop) goes home without one.
  if (pendingJoin) {
    return (
      <CardRoomFrame backHome={false}>
        <p>Table {pendingJoin.code} is a Self-Scoring (Muggins) table.</p>
        <MugginsNotice
          open
          mode="join"
          playerCount={pendingJoin.max_players}
          onCancel={() => router.replace("/")}
          onConfirm={() => {
            const row = pendingJoin;
            setPendingJoin(null);
            takeSeat(row, () => false);
          }}
        />
      </CardRoomFrame>
    );
  }

  // THE FIRST READ, on a table that will draw square: until the table's first
  // full read is in, the same "Loading..." as above -- not the classic table
  // with nothing on it, which would flash before the square one (2 and 3
  // players -- self-scoring (Muggins) ones too -- and 4 players, Teams or
  // Solo). A classic table (?layout=classic) draws as it always has.
  if (
    !tableRead &&
    isSquareTable({
      layoutParam,
      playerCount: table?.max_players ?? 2,
      isMuggins: table?.is_muggins === true,
      teams: table?.team_mode === "teams",
    })
  ) {
    return (
      <main className="table-loading flex flex-1 items-center justify-center">
        <p>Loading...</p>
      </main>
    );
  }

  const me = members.find((m) => m.user_id === session.user.id);
  // Seating: everyone who isn't you sits across the top. Rendered from an
  // array rather than a single hardcoded opponent so 3- and 4-player tables
  // (Phase 3) slot in without restructuring the layout.
  const opponents = members.filter((m) => m.user_id !== session.user.id);
  // THE TABLE'S SIZE: tables.max_players, 2 for every table before Phase 3.
  // A 3- or 4-player table has the waiting room and the host's Start (stage
  // A2).
  const capacity = table?.max_players ?? 2;
  const isTwoPlayerTable = capacity === 2;
  const canStartGame = members.length === capacity;
  // Alone at the table with no game and no result on screen. Only once the
  // roster has loaded -- an empty roster before then isn't "alone".
  const waitingAlone =
    membersLoaded && !activeGame && !finishedGame && members.length < capacity;

  // PHASE 3 (A2), 3- and 4-player tables. Nothing here applies to a
  // 2-player table.
  const isPhase3Table = !isTwoPlayerTable;
  // THE HOST, worked out exactly as the server's table_host(): the creator
  // while seated, otherwise the player in the lowest seat.
  const seatedBySeat = [...members].sort((a, b) => (a.seat ?? 99) - (b.seat ?? 99));
  const hostId =
    table && members.some((m) => m.user_id === table.created_by)
      ? table.created_by
      : (seatedBySeat[0]?.user_id ?? null);
  const isHost = hostId === session.user.id;
  // Teams: 4 players in team_mode 'teams' -- seats 1 and 3 against 2 and 4.
  const isTeams = capacity === 4 && table?.team_mode === "teams";
  // The waiting room: no game and no result on screen -- or, after a won
  // match, a roster that is no longer the won game's players (someone left,
  // or joined). The server then starts with a cut, which only the host may
  // start, so the result gives way to the seats and the host's Start.
  const finishedSameRoster =
    !!finishedGame &&
    finishedGame.players.length === members.length &&
    finishedGame.players.every((id) => members.some((m) => m.user_id === id));
  const inWaitingRoom =
    isPhase3Table && !activeGame && (!finishedGame || (membersLoaded && !finishedSameRoster));
  // The game's players (seat order) and how many: hand sizes, the crib, the
  // seats and the plates follow them. 2 for every 2-player table.
  const gamePlayers = activeGame?.players ?? finishedGame?.players ?? null;
  const playerCount = isPhase3Table ? gamePlayers?.length || capacity : 2;
  const sizes = handSizes(playerCount);
  // THE PHASE 3 LAYOUT (3 and 4 players): the others around me --
  // the next player clockwise on my left, then across the top, then on my
  // right -- from the game's players list. Not in the waiting room or the
  // cut, which have their own screens.
  const phase3Layout = isPhase3Table && !!gamePlayers && !inWaitingRoom && activeGame?.status !== "cutting";
  const places = phase3Layout && gamePlayers ? seatPlaces(gamePlayers, session.user.id) : null;

  const phase = activeGame?.phase ?? "discard";
  // STATUS BEFORE PHASE: every phase flag requires a live, dealt game first.
  // activeGame should only ever hold a live game, but an ended row can carry
  // any phase, so the check is explicit rather than assumed.
  const isActive = activeGame?.status === "active";
  const isPlaying = isActive && phase === "play";
  const isCounting = isActive && phase === "counting";

  // Spot the play -> counting step AS IT HAPPENS on this screen, and hold
  // the pegging view. React's "adjust state when a value changes" pattern
  // (as in ScoreStrip): compared during render, so it catches the change
  // whichever way it arrived -- a realtime event, our own last card's
  // re-read, or a reconcile. Only a step seen live counts: a page that
  // LOADS in counting (a refresh) never saw "play", so it goes straight to
  // counting. Server and other screen are untouched.
  const currentHandKey = activeGame ? `${activeGame.id}:${activeGame.hand_no}` : null;
  const phaseKey = isActive && currentHandKey ? `${currentHandKey}:${phase}` : null;
  if (phaseKey !== seenPhaseKey) {
    if (seenPhaseKey === `${currentHandKey}:play` && phase === "counting") {
      setPegHoldKey(currentHandKey);
    }
    setSeenPhaseKey(phaseKey);
  }
  // On hold: the hand is in counting (or beyond) on the server, but this
  // screen still shows pegging. Keyed to this hand, so it lapses by itself
  // on Next Hand or New Game, and an ended game (activeGame gone) never
  // shows it.
  const onPegHold =
    isActive && (phase === "counting" || phase === "done") && pegHoldKey === currentHandKey;
  // The pegging layout is on screen: during play, or holding after it.
  const pegView = isPlaying || onPegHold;

  // game_hands.cards is the immutable four-card hand; what you still HOLD is
  // that minus what you've already played.
  const playedByMe = new Set(
    plays.filter((p) => p.kind === "play" && p.user_id === session.user.id).map((p) => p.card!)
  );
  // During counting you want the whole hand back -- those four cards are what
  // gets scored. Only during play is it reduced to what's left to play.
  const handForDisplay = pegView ? myHand.filter((c) => !playedByMe.has(c)) : myHand;
  // From counting onward every hand is shown sorted, on every screen --
  // including your own -- so a shown hand reads in the same order for its
  // owner and for the table. Sort is locked on until the next hand.
  const sortLocked = isActive && (phase === "counting" || phase === "done");
  const displayedHand =
    handSorted || sortLocked ? sortHand(handForDisplay) : handForDisplay;

  const isMyTurn = isPlaying && activeGame?.current_player === session.user.id;
  const playCount = activeGame?.play_count ?? 0;

  // Mirrors the server's Guard 7. Shown as an affordance so a player can see
  // which cards are available rather than tapping and being rejected -- but
  // play_card re-checks it, since this is only a hint.
  function canPlayCard(card: string) {
    return isMyTurn && cardPlayValue(card) + playCount <= 31;
  }

  const discardedBy = activeGame?.discarded_by ?? [];
  const iHaveDiscarded = discardedBy.includes(session.user.id);
  // Every player has discarded (2, 3 or 4).
  const cribComplete = discardedBy.length >= playerCount;
  const iAmDealer = activeGame?.dealer_id === session.user.id;
  const waitingOn = opponents.filter((o) => !discardedBy.includes(o.user_id));

  // A LIVE DEAL (the dealing animation; square table only). Animate only a
  // hand this screen sees START (liveDealStep, lib/dealAnimation.ts). The
  // first render after the table's first full read (tableRead) records
  // whatever hand is already dealt as seen -- so a load, a reload, a late
  // join or a spectator never animates. After that, a dealt hand
  // ("<game id>:<hand_no>") this screen hasn't seen, still in the discard
  // with my cards not yet discarded, is a live deal: a Next Hand, the first
  // hand after the cut, a New Game. Compared during render (as the pegging
  // hold above), and keyed to the hand, so a re-render or a realtime echo
  // can never replay it; dealDoneKey marks it finished or skipped. Off with
  // reduced motion or the Profile switch off -- decided when the hand
  // arrives, so turning either back on mid-discard can't start a late deal.
  const dealHandKey = isActive ? currentHandKey : null;
  const dealStep = liveDealStep({
    tableRead,
    seenKey: dealSeenKey,
    handKey: dealHandKey,
    phase,
    iHaveDiscarded,
    animationOn: dealAnimationOn && !reducedMotion,
  });
  if (dealStep.seenKey !== dealSeenKey) {
    if (dealStep.liveKey) setDealLiveKey(dealStep.liveKey);
    setDealSeenKey(dealStep.seenKey);
  }
  // The square table (by default for 2, 3 and 4 players, Teams or Solo,
  // self-scoring ones too, without ?layout=classic -- 3- and 4-player
  // self-scoring always): only it shows the
  // deal and the discard tosses -- with every seat filled, as its screens
  // need (3 and 4 players: every game player still at the table, as THE
  // SQUARE SCREEN, 3 AND 4 PLAYERS requires, so a deal is never held for a
  // screen that draws classic).
  const squareTable = isSquareTable({ layoutParam, playerCount: capacity, isMuggins, teams: isTeams });
  const squareDealTable =
    squareTable &&
    (capacity === 2
      ? opponents.length === 1
      : (capacity === 3 || capacity === 4) &&
        opponents.length === capacity - 1 &&
        gamePlayers?.length === capacity &&
        gamePlayers.every((id) => members.some((m) => m.user_id === id)));
  const dealInFlight =
    squareDealTable &&
    dealAnimationOn &&
    !reducedMotion &&
    !!dealHandKey &&
    dealLiveKey === dealHandKey &&
    dealDoneKey !== dealHandKey &&
    phase === "discard" &&
    !iHaveDiscarded &&
    !!gamePlayers?.includes(session.user.id);
  // Nothing to tap while cards are in the air.
  const canDiscard =
    Boolean(activeGame) && !iHaveDiscarded && myHand.length === sizes.dealt && !dealInFlight;

  // A LIVE DISCARD (the discard toss; square table only). The same guard as
  // the deal (liveDiscardStep): discards already there at the first full
  // read, or when a hand first shows, are recorded and never thrown; a
  // player newly in discarded_by after that is thrown to the crib once --
  // unless a deal is still being shown (the crib just appears when it ends)
  // or the animations are off. Mine is thrown when I tap Send to Crib
  // (startMyToss), so here only the other players' are.
  const cardAnimationsOn = squareDealTable && dealAnimationOn && !reducedMotion;
  const squarePositionOf = (userId: string) =>
    gamePlayers ? seatPositionOf(gamePlayers, session.user.id, userId) : null;
  // THE COMPUTER'S DISCARD, SHOWN ON TIME (lib/dealAnimation.ts): at a
  // 2-player square table with a computer opponent (computerTable, as the
  // computer driver knows it), 7 s after my dealt hand first appears here
  // (the deal's start, or the hand showing) without its real discard -- never
  // mid-deal -- it is shown as discarded: display only; the game waits for
  // the real one as before. Its clock is ComputerDiscardClock (the square
  // screen); once shown, its hand shows the kept four, the crib its cards,
  // and its real discard is never thrown again (markDiscardSeen) or counted
  // twice (shownCribIds).
  const shownComputerId =
    computerTable && capacity === 2 && squareDealTable ? (opponents[0]?.user_id ?? null) : null;
  const discardShowInput = {
    eligible: !!shownComputerId,
    handKey: dealHandKey,
    phase,
    handShown: myHand.length === sizes.dealt && !!gamePlayers?.includes(session.user.id),
    dealInFlight,
    computerDiscarded: !!shownComputerId && discardedBy.includes(shownComputerId),
    iDiscarding: iHaveDiscarded || discardStatus === "sending",
  };
  const computerShown = discardShown({ ...discardShowInput, state: discardShow });
  const showComputerDiscard = (handKey: string) => {
    if (!shownComputerId || handKey !== dealHandKey || discardShowInput.computerDiscarded) return;
    if (!discardShow || discardShow.handKey !== handKey || discardShow.fired || discardShow.cancelled) return;
    setDiscardShow((current) => fireDiscardShow(current, handKey));
    writeDiscardShown(handKey);
    // Its two cards thrown to the crib, as a real discard is (animations on).
    if (cardAnimationsOn) {
      const id = `${handKey}:shown`;
      const seats: TossSeat[] = [{ key: shownComputerId, position: "top", cards: sizes.discard }];
      setTosses((current) => (current.some((t) => t.id === id) ? current : [...current, { id, handKey, seats }]));
    }
  };
  const discardStep = liveDiscardStep({
    tableRead,
    seen: computerShown ? markDiscardSeen(discardSeen, dealHandKey, shownComputerId) : discardSeen,
    handKey: dealHandKey,
    discardedBy,
    dealInFlight,
    animationOn: cardAnimationsOn,
  });
  if (discardStep.seen !== discardSeen) {
    const thrown = discardStep.live.filter((id) => id !== session.user.id && opponents.some((o) => o.user_id === id));
    const position = thrown.length ? squarePositionOf(thrown[0]) : null;
    if (dealHandKey && position) {
      const id = `${dealHandKey}:${thrown.join(",")}`;
      const seats = thrown.map((userId) => ({ key: userId, position: squarePositionOf(userId) ?? position, cards: sizes.discard }));
      setTosses((current) => (current.some((t) => t.id === id) ? current : [...current, { id, handKey: dealHandKey, seats }]));
    }
    setDiscardSeen(discardStep.seen);
  }
  // A throw from an earlier hand can't still be in flight.
  if (tosses.some((t) => t.handKey !== dealHandKey)) {
    setTosses((current) => current.filter((t) => t.handKey === dealHandKey));
  }
  // My discard, thrown as I tap Send to Crib: the picked cards fly from my
  // hand to the crib, turning face-down.
  const startMyToss = () => {
    if (!cardAnimationsOn || !dealHandKey || !canDiscard) return;
    const id = `${dealHandKey}:mine`;
    const seat: TossSeat = {
      key: session.user.id,
      position: "bottom",
      cards: selectedCards.length,
      faces: [...selectedCards],
      fromSlots: selectedCards.map((card) => displayedHand.indexOf(card)),
    };
    setMyTossKey(dealHandKey);
    setTosses((current) => (current.some((t) => t.id === id) ? current : [...current, { id, handKey: dealHandKey, seats: [seat] }]));
  };
  // THE CRIB PILE on the square table: empty while a deal is shown here, and
  // without the cards still flying to it; mine count from the moment they
  // land, even if the server hasn't answered yet (until it refuses); the
  // computer's once shown as discarded (each player once).
  const tossingIds = new Set(tosses.flatMap((t) => t.seats.map((s) => s.key)));
  const cribIds = shownCribIds({
    discardedBy,
    mineSending: discardStatus === "sending" && myTossKey === dealHandKey ? session.user.id : null,
    shownComputer: computerShown ? shownComputerId : null,
    tossing: tossingIds,
  });
  const squareCribCount = dealInFlight ? 0 : cribCountDuringDiscard(playerCount, cribIds.size);
  // Every discard in, as the square screen shows it (the prompt's line).
  const cribShownComplete = cribComplete || (computerShown && iHaveDiscarded);

  // The cut phase. Only the table's FIRST game cuts -- later games alternate
  // the deal, are created straight into 'active', and never enter this.
  const isCutting = activeGame?.status === "cutting";

  // COUNTING. activeGame only ever holds a LIVE game (the realtime handler
  // drops it the moment status leaves cutting/active), so every phase check
  // below already sits behind a status check.
  const isDone = isActive && phase === "done";
  // Who deals the next hand: the current pone -- the player who isn't
  // dealing now. Display only; next_hand decides it on the server (the
  // player after the dealer, which in 2-player is the same person). With 3
  // and 4 players: the next seat clockwise from the dealer (nextSeat).
  const nextDealerId = isPhase3Table
    ? nextSeat(activeGame?.players ?? [], activeGame?.dealer_id)
    : (activeGame?.players?.find((p) => p !== activeGame?.dealer_id) ?? null);
  const nextDealerName =
    nextDealerId === session.user.id
      ? "you"
      : displayName(members.find((m) => m.user_id === nextDealerId));

  // THE READY GATE, read straight from the game row. Gated on isDone as well:
  // next_hand clears ready_by in the same UPDATE that leaves 'done', so it is
  // empty in every other phase anyway, but this makes it impossible for a
  // "waiting" state to show anywhere except the hand it belongs to.
  const readyBy = isDone ? (activeGame?.ready_by ?? []) : [];
  const iAmReady = readyBy.includes(session.user.id);
  const nameOf = (userId: string) => displayName(members.find((m) => m.user_id === userId));
  // Other players who have tapped / still have to.
  const othersReady = (activeGame?.players ?? []).filter(
    (p) => p !== session.user.id && readyBy.includes(p)
  );
  const othersNotReady = (activeGame?.players ?? []).filter(
    (p) => p !== session.user.id && !readyBy.includes(p)
  );
  // The counting UI (banner, breakdowns, Show Hand) -- only once this player
  // has left the pegging hold.
  const isCountingOrDone = (isCounting || isDone) && !onPegHold;
  const countStep = activeGame?.count_step ?? 0;
  const starterCard = activeGame?.starter_card ?? null;
  const countBusy = countStatus === "sending";

  // THE COUNTING VIEW (UI polish, stage 3): what goes in my hand row, in the
  // middle, in the opponent's strip and in the crib pile at each step --
  // decided in one pure function (components/table/countingView.ts) that the
  // layout mock calls too. 2-player: the one opponent.
  const countOpp = opponents[0];
  const view2 =
    !isPhase3Table && isCountingOrDone && activeGame?.dealer_id && countOpp
      ? countingView({
          myId: session.user.id,
          dealerId: activeGame.dealer_id,
          oppName: displayName(countOpp),
          phase: isDone ? "done" : "counting",
          step: countStep,
          myHand: sortHand(myHand),
          // Whatever the read policies returned: from counting on, the
          // opponent's whole hand (face-down until it arrives).
          oppCards: revealedHands[countOpp.user_id] ? sortHand(revealedHands[countOpp.user_id]) : null,
          cribCards: cribCards ? sortHand(cribCards) : null,
          starter: starterCard,
          hideNumbers: hideCountNumbers,
        })
      : null;
  // 3 and 4 players (Phase 3, A5a): countingViewN (lib/countingN.ts) -- the
  // hand being counted in the middle, every other hand face-up on its seat,
  // the crib at step N, N+1 recap lines.
  const viewN =
    isPhase3Table && isCountingOrDone && activeGame?.dealer_id && gamePlayers
      ? countingViewN({
          players: gamePlayers,
          myId: session.user.id,
          dealerId: activeGame.dealer_id,
          names: Object.fromEntries(members.map((m) => [m.user_id, displayName(m)])),
          phase: isDone ? "done" : "counting",
          step: countStep,
          myHand: sortHand(myHand),
          hands: Object.fromEntries(
            gamePlayers
              .filter((id) => id !== session.user.id)
              .map((id) => [id, revealedHands[id] ? sortHand(revealedHands[id]) : null])
          ),
          cribCards: cribCards ? sortHand(cribCards) : null,
          starter: starterCard,
          hideNumbers: hideCountNumbers,
        })
      : null;
  // One view for the screen: the N-player one in the 2-player shape, so the
  // middle, the pile row and my hand row read it the same way.
  const view: CountingView | null = viewN
    ? {
        myTurn: viewN.myTurn,
        myRow: viewN.myRow,
        myRowCounting: viewN.myRowCounting,
        middle: viewN.middle,
        middleLabel: viewN.middleLabel ?? "",
        cribFan: viewN.cribFan,
        headline: viewN.headline,
        hint: viewN.hint,
        waitingOn: viewN.waitingOn,
        canConfirm: viewN.canConfirm,
        recap: viewN.recap.map((r) => r.text),
      }
    : view2;

  // THE STARTER IN COUNTING (square table; countingStarterPlace,
  // lib/tableLayout.ts): from the dealer's deck to just above my hand (my
  // crib) or the middle (anyone else's). It slides there only when this
  // screen sees counting begin (liveStarterStep: the same guard as the deal
  // -- never on a load, a reload or a late join), with the animations on;
  // otherwise it is just there.
  const countingPicture = squareDealTable && isCountingOrDone && !!view;
  const starterStep = liveStarterStep({
    tableRead,
    seenKey: starterSeenKey,
    handKey: dealHandKey,
    counting: countingPicture,
    animationOn: cardAnimationsOn,
  });
  if (starterStep.seenKey !== starterSeenKey) {
    if (starterStep.liveKey) setStarterLiveKey(starterStep.liveKey);
    setStarterSeenKey(starterStep.seenKey);
  }
  const starterSlides = cardAnimationsOn && !!dealHandKey && starterLiveKey === dealHandKey;
  // The starter in its counting place, for `place` (above my hand, or the
  // middle); null on the deck.
  const countingStarterFor = (place: ReturnType<typeof countingStarterPlace>, card: string | null, slide: boolean) =>
    place === "deck" || !card ? null : (
      <CountingStarter card={card} sizing={place === "above-hand" ? HAND_CARD : "w-full aspect-[5/7]"} slide={slide} />
    );

  const winner = members.find((m) => m.user_id === finishedGame?.winner_id);
  // THE FINAL BOARD: the won game's result, while no game is live.
  const finalBoard = activeGame ? null : finishedGame;
  // A WON GAME'S RESULT AFTER A REJOIN: the players whose seat was joined
  // after the won game began (they left and came back) -- their seat's score
  // is the new seat's 0, not the game's, so the result hides it (the winner
  // banner's number, their plate) rather than show it wrong. Empty during
  // play, and for everyone who stayed seated.
  const rejoinedIds = new Set(
    finalBoard
      ? members.filter((m) => !scoreFromThisGame(m.joined_at, finalBoard.created_at)).map((m) => m.user_id)
      : []
  );
  const winnerScoreShown = !!winner && !rejoinedIds.has(winner.user_id);
  // Whose hand it was: the live game's dealer, or the won game's.
  const handDealerId = activeGame ? activeGame.dealer_id : (finalBoard?.dealer_id ?? null);

  // THE NEW GAME READY GATE, as the server applies it: only after a won match
  // between exactly the players now at the table (anything else is a cut for
  // deal, which starts on the first tap). Every state comes from the won
  // game's ready_by, so a refresh shows the same thing.
  const memberIds = members.map((m) => m.user_id);
  const newGameGated =
    !!finishedGame &&
    canStartGame &&
    finishedGame.players.length === memberIds.length &&
    finishedGame.players.every((id) => memberIds.includes(id));
  const newGameReadyBy = newGameGated ? finishedGame.ready_by : [];
  const iAmReadyForNewGame = newGameReadyBy.includes(session.user.id);
  const othersReadyForNewGame = newGameGated
    ? finishedGame.players.filter((id) => id !== session.user.id && newGameReadyBy.includes(id))
    : [];
  const othersNotReadyForNewGame = newGameGated
    ? finishedGame.players.filter((id) => id !== session.user.id && !newGameReadyBy.includes(id))
    : [];
  // Who deals the rematch, shown with 3 and 4 players: what
  // start_game_with_deal does -- the next seat clockwise from the winner, by
  // the seats now (phase3-e2-dealing.sql), with no cut.
  const rematchDealerId =
    isPhase3Table && newGameGated
      ? nextSeat(seatedBySeat.map((m) => m.user_id), finishedGame.winner_id)
      : null;

  // Derived from discarded_by rather than mirroring our own hand length: once
  // you discard and your opponent hasn't, mirroring would show 4 cards for a
  // player still holding 6. Hand sizes are public knowledge from the rules, so
  // this reveals nothing that isn't already known.
  function opponentCardCount(opponentId: string) {
    if (!activeGame) return 0;
    if (pegView) {
      // Derived from the public play log -- how many of their four they've
      // laid down. Reveals nothing: which cards they've played is already
      // public, and hand sizes are visible in a real game anyway.
      return cardsLeft(sizes.kept, plays, opponentId);
    }
    if (isCountingOrDone) return sizes.kept;
    if (computerShown && opponentId === shownComputerId) return sizes.kept;
    return discardedBy.includes(opponentId) ? sizes.kept : sizes.dealt;
  }

  // ---- The table, as a fixed-height shell (UI polish, stage 1). ----------
  //
  // TableShell gives every region a fixed height except the middle, which takes
  // what's left -- so the hand, the piles and the scores stay put for the
  // whole game and the page never scrolls. Errors and notices are overlays
  // inside the middle, so they never add height either.

  // WHO SAID GO in the run on the table (pegging, or the hold after it): an
  // amber "Go" by each such player -- above my hand, or under the opponent's
  // name. It clears when the run clears, because it's read from the same run
  // the play area shows (displayedRun).
  const goBy =
    pegView && activeGame
      ? goSayers(displayedRun(plays, activeGame.play_segment, onPegHold).events)
      : new Set<string>();
  const goLabel = <span className="text-xs font-semibold text-amber-600 dark:text-amber-500 surface:text-amber-200">Go</span>;
  const countingLabel = (
    <span className="text-xs font-semibold text-emerald-600 dark:text-emerald-500 surface:text-violet-200">Counting</span>
  );

  // Opponents across the top. Each seat's hand is drawn face-down from the
  // public hand size -- except in counting, where it shows face-up in the
  // middle and the strip keeps only the name -- or face-up, sorted, on the
  // final board.
  const seatOf = (opponent: Member): OpponentSeat => {
    return {
      userId: opponent.user_id,
      name: displayName(opponent),
      avatarUrl: opponent.avatar_url,
      isDealer: handDealerId === opponent.user_id,
      // In counting the hand is in the middle: the strip keeps no cards.
      // The final board: the hand face-up when readable, else face-down.
      cardCount: finalBoard
        ? sizes.kept
        : viewN
          ? (viewN.seatCards[opponent.user_id]?.count ?? sizes.kept)
          : view
            ? 0
            : opponentCardCount(opponent.user_id),
      shownCards: finalBoard
        ? finalBoard.board.hands[opponent.user_id]
          ? sortHand(finalBoard.board.hands[opponent.user_id])
          : undefined
        : viewN
          ? (viewN.seatCards[opponent.user_id]?.shown ?? undefined)
          : undefined,
      saidGo: goBy.has(opponent.user_id),
    };
  };
  const seats: OpponentSeat[] = opponents.map(seatOf);
  // Phase 3: who sits where (left, top, right), as seats.
  const memberSeat = (userId: string | null) => {
    const m = userId ? members.find((x) => x.user_id === userId) : undefined;
    return m ? seatOf(m) : null;
  };
  const leftSeat = places ? memberSeat(places.left) : null;
  const topSeat = places ? memberSeat(places.top) : null;
  const rightSeat = places ? memberSeat(places.right) : null;

  // THE SCORE PLATES, built in one place (buildPlates, lib/phase3.ts). 2
  // players: one plate per player, me first -- exactly the list this screen
  // always built. 3 players and 4-player Solo: one per player, me first,
  // then clockwise. 4-player Teams: one per team, my team first, the flash
  // naming the partner who scored. On a won game's result, a rejoined
  // player's plate is left blank (hideRejoinedScores; rejoinedIds above).
  const plateMembers: Member[] = phase3Layout && gamePlayers
    ? seatOrderFrom(gamePlayers, session.user.id).flatMap((id) => members.filter((m) => m.user_id === id))
    : [...(me ? [me] : []), ...opponents];
  const plates: ScorePlate[] = hideRejoinedScores(
    buildPlates({
      rows: plateMembers.map((m) => ({
        user_id: m.user_id,
        name: displayName(m),
        avatar_url: m.avatar_url,
        score: m.score,
        last_points: m.last_points,
        last_reason: m.last_reason,
        last_awarded_at: m.last_awarded_at,
      })),
      myId: session.user.id,
      dealerId: handDealerId,
      teamsPlayers: phase3Layout && isTeams && gamePlayers ? gamePlayers : null,
    }),
    rejoinedIds
  );

  // Every error the old layout stacked into the page as extra lines now
  // shares one overlay at the bottom of the middle region.
  const errorToast =
    (leaveStatus === "error" && leaveMessage) ||
    (discardStatus === "error" && discardMessage) ||
    (playStatus === "error" && playMessage) ||
    (gameStatus === "error" && gameMessage) ||
    (seatStatus === "error" && seatMessage) ||
    null;

  // The header's controls -- the same in the square view's header.
  const headerRight = (
        <>
          {/* Hide counts, saved at once. Not while Leave is asking to
              confirm, so the header's right side never grows past one
              line. On a Muggins table it is locked: nothing to show, so
              nothing to hide, and nothing is saved. */}
          {appearance.ready && !leaveConfirming && (
            <CountsToggle
              locked={isMuggins}
              hidden={appearance.hideCounts}
              onSave={(nextHidden) =>
                appearance.save({
                  surface: appearance.surface,
                  back: appearance.back,
                  hideCounts: nextHidden,
                })
              }
            />
          )}
          {realtimeStatus === "disconnected" && (
            <span className="text-xs text-amber-600 dark:text-amber-500 surface:text-amber-200">Reconnecting...</span>
          )}
          {leaveConfirming ? (
            <>
              <button
                onClick={handleLeave}
                disabled={leaveStatus === "leaving"}
                className="tap-40 rounded bg-red-600 px-3 text-xs text-white disabled:opacity-50"
              >
                {leaveStatus === "leaving" ? "Leaving..." : "End game & leave"}
              </button>
              <button
                onClick={() => setLeaveConfirming(false)}
                className="tap-40 px-1 text-xs text-zinc-600 underline dark:text-zinc-400"
              >
                Cancel
              </button>
            </>
          ) : (
            <button
              onClick={() => (activeGame ? setLeaveConfirming(true) : handleLeave())}
              disabled={leaveStatus === "leaving"}
              className="tap-40 px-1 text-xs text-zinc-600 underline disabled:opacity-50 dark:text-zinc-400"
            >
              {leaveStatus === "leaving" ? "Leaving..." : "Leave"}
            </button>
          )}
        </>
  );
  const header = (
    <TableHeader
      code={code}
      handNo={isActive ? (activeGame?.hand_no ?? null) : null}
      muggins={isMuggins}
      right={headerRight}
    />
  );

  // Overlays: never part of the flow, so they can't grow the table. The same
  // in the square view's middle.
  const middleOverlays = (
    <>
      {gameEndedNotice && (
        <div className="absolute inset-x-0 top-0 z-10 flex items-center justify-center gap-3 rounded border border-amber-500 bg-background px-3 py-1 text-sm text-amber-700 shadow dark:text-amber-500">
          <span>{gameEndedNotice}</span>
          <button onClick={() => setGameEndedNotice(null)} className="tap-40 px-1 underline">
            Dismiss
          </button>
        </div>
      )}
      {errorToast && (
        <p className="absolute inset-x-0 bottom-0 z-10 rounded bg-red-600 px-3 py-1 text-center text-sm text-white shadow">
          {errorToast}
        </p>
      )}
    </>
  );

  // The discard's prompt in the middle -- the same in the square view.
  const discardPrompt = iHaveDiscarded ? (
    <p className="text-sm text-zinc-500">
      Waiting for {waitingOn.map(displayName).join(", ")} to discard...
    </p>
  ) : (
    <p className="text-base font-medium">
      {isPhase3Table ? (
        <>
          Pick {sizes.discard} card for {iAmDealer ? "your" : `${nameOf(activeGame?.dealer_id ?? "")}'s`} crib
        </>
      ) : (
        <>
          Pick {sizes.discard} cards for {iAmDealer ? "your" : "their"} crib
        </>
      )}
    </p>
  );

  // The counting stage in the middle: headline, the hand being counted
  // (`subject`), Confirm / Next Hand, the recap. The square view passes no
  // subject (its cards stay at the seats); everything else is the same.
  const countActions = view
    ? isDone ? (
            <>
              {/* NEXT HAND. Every state comes from ready_by on the
                  game row, so a refresh shows the same thing. The tap
                  that completes the set deals; the hand_no change
                  then resets both screens. */}
              {!iAmReady && othersReady.length > 0 && (
                <p className="text-sm font-medium">
                  {othersReady.map(nameOf).join(", ")} {othersReady.length === 1 ? "is" : "are"} ready
                </p>
              )}
              <button
                onClick={handleNextHand}
                disabled={countBusy || iAmReady}
                className="min-h-10 rounded bg-foreground px-4 text-sm font-medium text-background disabled:opacity-40"
              >
                {countBusy ? "Sending..." : "Next Hand"}
              </button>
              {iAmReady && (
                <p className="text-sm text-zinc-500">
                  Waiting for {othersNotReady.map(nameOf).join(", ")}…
                </p>
              )}
            </>
          ) : view.myTurn ? (
            <button
              onClick={() => handleConfirmCount(countStep)}
              disabled={!view.canConfirm || countBusy}
              className="min-h-10 rounded bg-foreground px-4 text-sm font-medium text-background disabled:opacity-40"
            >
              {countBusy && view.canConfirm ? "Confirming..." : "Confirm Count"}
            </button>
          ) : view.waitingOn ? (
            <p className="text-sm text-zinc-500">{view.waitingOn}</p>
          ) : undefined
    : undefined;
  const countStageFor = (subject: CardSlot) =>
    view ? (
      <CountStage
        headline={view.headline}
        hint={isDone ? `Next dealer: ${nextDealerName}` : view.hint}
        subject={subject}
        subjectLabel={view.middleLabel}
        recap={view.recap}
        recapKeys={viewN ? viewN.recap.map((r) => r.key) : undefined}
        variant={viewN ? "n" : undefined}
        error={countStatus === "error" ? countMessage : null}
        actions={countActions}
      />
    ) : null;

  // THE RESULT and New Game, below the final board's run -- the same in the
  // square view's final board.
  // Who won, as words (also the banner's tooltip: a 4-player table's banner
  // ends in an ellipsis when a name runs out of room).
  const winText = finishedGame
    ? isPhase3Table
      ? winHeadline({
          players: finishedGame.players,
          winnerId: finishedGame.winner_id,
          myId: session.user.id,
          nameOf: (id) => {
            const m = members.find((x) => x.user_id === id);
            return m ? displayName(m) : null;
          },
          teams: isTeams,
        })
      : finishedGame.winner_id === session.user.id
        ? "You win!"
        : `${winner ? displayName(winner) : "A player who has left"} wins!`
    : null;
  const resultStage = (
    <div className="result-stage">
      {/* THE RESULT. Shown once a game has ended by a win and nothing
          has replaced it -- a reload or a late reconnect finds it via
          refreshTableState. Scores are read live from the roster, so
          the winner's 121 shows even if its UPDATE lands after this. */}
      {finishedGame && (
        <div className="result-banner flex flex-col items-center gap-1 rounded border-2 border-emerald-600 surface:border-violet-300 px-6 py-3 text-center">
          <p className="text-lg font-semibold" title={winText ?? undefined}>
            {winText}
            {/* How it ended: the winner's last award IS the winning one,
                since nothing can score after the game ends. */}
            {/* Not on a Muggins table: it shows no score anywhere. */}
            {winner && !isMuggins && (
              <>
                {/* No number if the winner left and came back: their seat's
                    score is the new seat's 0 (rejoinedIds). Their new seat
                    has no last award either, so nothing follows. */}
                {winnerScoreShown && (
                  <>
                    {" "}
                    {winner.score}
                  </>
                )}
                {/* With count numbers hidden, a count win shows
                    only the score: no breakdown, no (+N). */}
                {winner.last_reason &&
                  !(hideCountNumbers && isCountReason(winner.last_reason)) &&
                  ` — ${winner.last_reason} (+${winner.last_points ?? 0})`}
              </>
            )}
          </p>
        </div>
      )}
      {/* NEW GAME, after a won match: the Next Hand pattern. The other
          player's tap shows above the button; mine greys it out, with
          who we're waiting for below. A repeat tap is quiet server-side
          too. Leave stays available throughout. */}
      <>
        <div className="result-stage__actions">
          {!iAmReadyForNewGame && othersReadyForNewGame.length > 0 && (
            <p className="text-sm font-medium" title={othersReadyForNewGame.map(nameOf).join(", ")}>
              {othersReadyForNewGame.map(nameOf).join(", ")}{" "}
              {othersReadyForNewGame.length === 1 ? "is" : "are"} ready
            </p>
          )}
          <button
            onClick={handleStartNewGame}
            disabled={gameStatus === "creating" || !canStartGame || iAmReadyForNewGame}
            className="min-h-11 rounded bg-foreground px-6 text-lg text-background disabled:opacity-40"
          >
            {gameStatus === "creating"
              ? newGameGated && othersNotReadyForNewGame.length > 0
                ? "Sending..."
                : "Dealing..."
              : "New Game"}
          </button>
          {iAmReadyForNewGame && othersNotReadyForNewGame.length > 0 && (
            <p className="text-sm text-zinc-500" title={othersNotReadyForNewGame.map(nameOf).join(", ")}>
              Waiting for {othersNotReadyForNewGame.map(nameOf).join(", ")}…
            </p>
          )}
          {/* 3 and 4 players: who deals the rematch (no cut). */}
          {rematchDealerId && (
            <p className="text-xs text-zinc-500" title={rematchDealerId === session.user.id ? undefined : nameOf(rematchDealerId)}>
              Next dealer: {rematchDealerId === session.user.id ? "you" : nameOf(rematchDealerId)}
            </p>
          )}
        </div>
        {!canStartGame && (
          <p className="text-sm text-zinc-500">
            Needs exactly {capacity} players ({members.length} here).
          </p>
        )}
      </>
    </div>
  );

  const middle = (
    <>
      {middleOverlays}

      {/* THE CUT. During 'cutting' there are no hands, no crib and no
          starter, so the cut view takes the whole middle; the hand row and
          the pile row are left out (see below) to give it the room. */}
      {isCutting && activeGame ? (
        <CutForDealView
          rounds={activeGame.deal_cut ?? [[]]}
          players={activeGame.players ?? []}
          myUserId={session.user.id}
          dealerId={activeGame.dealer_id}
          ackBy={activeGame.deal_cut_ack_by}
          nameFor={(userId) => displayName(members.find((m) => m.user_id === userId))}
          onDraw={handleDrawCutCard}
          onAcknowledge={handleAcknowledgeCut}
        />
      ) : activeGame ? (
        !cribComplete ? (
          discardPrompt
        ) : (
          <>
            {pegView && (
              <>
                <PlayArea
                  plays={plays}
                  playCount={playCount}
                  playSegment={activeGame.play_segment}
                  currentPlayer={activeGame.current_player}
                  myUserId={session.user.id}
                  nameFor={(userId) => displayName(members.find((m) => m.user_id === userId))}
                  // The hold: the hand is over; show the final run and a
                  // "Count hands" button. Tapping it only clears this
                  // screen's hold -- nothing is sent anywhere -- so it can
                  // never stall the other player, and whoever counts first
                  // can always reach Confirm Count by tapping it.
                  handOver={onPegHold ? { onCountHands: () => setPegHoldKey(null) } : undefined}
                />
              </>
            )}

            {/* THE COUNTING STAGE. Order is fixed by the server: the pone's
                hand, the dealer's hand, then the crib. Buttons appear only on
                MY turn; otherwise a plain "X is counting". Both hands stay
                face-up throughout (the opponent's here, mine in my hand
                row); each confirmed count leaves a small recap line -- and
                nothing shows a count's points before its confirm. */}
            {view && countStageFor(view.middle)}
          </>
        )
      ) : inWaitingRoom ? (
        // THE WAITING ROOM (A2): the seats, the host's moves and Start.
        <WaitingRoom
          code={code}
          capacity={capacity}
          seats={Array.from({ length: capacity }, (_, i) => {
            const m = members.find((x) => x.seat === i + 1);
            return {
              seat: i + 1,
              player: m ? { userId: m.user_id, name: displayName(m), avatarUrl: m.avatar_url } : null,
            };
          })}
          myId={session.user.id}
          hostId={hostId}
          hostName={hostId ? nameOf(hostId) : null}
          isTeams={isTeams}
          picked={seatPick}
          busy={seatStatus === "sending"}
          onPick={(userId) => {
            setSeatStatus((s) => (s === "error" ? "idle" : s));
            setSeatPick((current) => (current === userId ? null : userId));
          }}
          onMove={handleSeatMove}
          canStart={isHost && members.length === capacity}
          starting={gameStatus === "creating"}
          onStart={handleStartNewGame}
        />
      ) : waitingAlone ? (
        // A host waiting for the table to fill, with no result to show: what
        // they are waiting for, and the code to send. New Game needs a full
        // table, so its disabled button is left out here.
        <WaitingForPlayer code={code} seated={members.length} capacity={capacity} />
      ) : (
        <div className="final-board">
          {/* THE FINAL BOARD: the hand's last run as it stood, with its
              count -- no turn pill, no Go labels, nothing to tap. None on
              his heels (nothing played yet). */}
          {finalBoard && finalBoard.board.finalRun.length > 0 && (
            <PlayArea
              ended
              plays={finalBoard.board.finalRun}
              playCount={0}
              playSegment={0}
              currentPlayer={null}
              myUserId={session.user.id}
              nameFor={(userId) => displayName(members.find((m) => m.user_id === userId))}
            />
          )}
          {resultStage}
        </div>
      )}
    </>
  );

  // The score flash, between the piles, above Sort. Not mounted until the
  // roster has loaded: see ScoreFlash. The same element in both pile rows
  // below, so the winning point's flash carries over onto the final board.
  // Never on a Muggins table (pegging's Go and last-card labels are not part
  // of it, and stay).
  const scoreFlash = membersLoaded && !isMuggins ? (
    <ScoreFlash plates={plates} hideCountAwards={hideCountNumbers} />
  ) : null;

  // The hand's action buttons, between the piles (the same in the square
  // view's pile row).
  const pileButtons = (
    <>
      {/* Hidden, not just disabled, once sorting is locked (counting
          onward): the shown crib fans out in this row then, and needs the
          room at hand-card size. */}
      {myHand.length > 0 && !sortLocked && (
        <button
          onClick={() => setHandSorted(true)}
          disabled={handSorted}
          className="min-h-10 rounded border border-zinc-400 px-5 text-sm font-medium disabled:opacity-40 dark:border-zinc-600"
        >
          Sort
        </button>
      )}
      {/* Only once the full discard is picked (2 cards, or 1 with 3 and 4
          players) -- there is no valid partial discard, so a
          disabled-but-visible button would just be noise. */}
      {canDiscard && selectedCards.length === sizes.discard && (
        <button
          onClick={() => {
            startMyToss();
            handleDiscard();
          }}
          disabled={discardStatus === "sending"}
          className="min-h-10 rounded bg-foreground px-5 text-sm font-medium text-background disabled:opacity-50"
        >
          {discardStatus === "sending" ? "Sending..." : "Send to Crib"}
        </button>
      )}
    </>
  );

  // The crib (left) and the starter or deck (right), with the hand's action
  // buttons between them. While cards are out -- and on the final board
  // after a win: the crib and the starter, and no buttons.
  const piles = finalBoard ? (
    <PileRow
      // The crib face-up (fanned) when readable, else a face-down pile.
      crib={{
        faceDownCount: sizes.kept,
        shownCards: finalBoard.board.crib ? sortHand(finalBoard.board.crib) : null,
        dealerIsMe: handDealerId === session.user.id,
      }}
      starter={finalBoard.starter_card ? { card: finalBoard.starter_card } : null}
      flash={scoreFlash}
    />
  ) : isActive ? (
    <PileRow
      crib={
        view
          ? // Counting: a face-down pile until the crib's count is up, then
            // the face-up fan (as on the final board), through 'done'. With 3
            // and 4 players the crib is in the middle at its step, so its pile
            // is an empty slot meanwhile (viewN.cribPile).
            {
              faceDownCount: viewN?.cribPile === "empty" ? 0 : sizes.kept,
              shownCards: view.cribFan,
              dealerIsMe: handDealerId === session.user.id,
            }
          : {
              // Everyone's discards so far (and, with 3 players, the deck
              // card dealt to the crib).
              faceDownCount: cribCountDuringDiscard(playerCount, discardedBy.length),
              shownCards: null,
              dealerIsMe: handDealerId === session.user.id,
            }
      }
      starter={{ card: starterCard }}
      flash={scoreFlash}
    >
      {pileButtons}
    </PileRow>
  ) : null;

  // My hand: on the final board, my four cards face-up (sorted, nothing to
  // tap), or face-down if they somehow couldn't be read.
  const finalMyHand = finalBoard?.board.hands[session.user.id];
  const hand = finalBoard ? (
    <HandRow>
      {finalMyHand
        ? sortHand(finalMyHand).map((card) => (
            <PlayingCard key={card} card={card} sizing={HAND_CARD} />
          ))
        : Array.from({ length: sizes.kept }, (_, i) => (
            <FaceDownCard key={i} sizing={HAND_CARD} />
          ))}
    </HandRow>
  ) : view ? (
    // Counting: my four at full size for the whole count -- never shrunk,
    // never cleared -- marked while it's the hand being counted.
    <HandRow label={view.myRowCounting ? countingLabel : undefined}>
      <SlotCards slot={view.myRow} />
    </HandRow>
  ) : (
    <HandRow label={goBy.has(session.user.id) ? goLabel : undefined}>
      {displayedHand.map((card) => (
        <PlayingCard
          key={card}
          card={card}
          sizing={HAND_CARD}
          selected={selectedCards.includes(card)}
          // Dimmed when it exists but can't be used right now: not your
          // turn, or it would take the count past 31. Visible-but-inert
          // beats hiding it, since "why can't I play my king?" has an
          // answer the player should be able to see.
          dimmed={isPlaying && !canPlayCard(card)}
          // One handler, two phases. Omitted entirely when no action is
          // available, which also renders the card as a plain div with
          // nothing to click or tab to.
          onSelect={
            canDiscard
              ? () => toggleCardSelection(card)
              : isPlaying && canPlayCard(card) && playStatus !== "sending"
                ? () => handlePlayCard(card)
                : undefined
          }
        />
      ))}
    </HandRow>
  );

  // MUGGINS: "I win" / "Confirm loss", only while a game is dealt and live
  // ('active'): nothing to claim during the cut, between games or on the won
  // screen. Its state is games.win_claim_by, which realtime, the re-reads and
  // the safety poll all keep current.
  const winClaimBy = activeGame?.win_claim_by ?? null;
  const mugginsWinBar =
    isMuggins && activeGame && isActive ? (
      <MugginsWinBar
        claim={!winClaimBy ? "none" : winClaimBy === session.user.id ? "mine" : "theirs"}
        otherName={
          winClaimBy && winClaimBy !== session.user.id
            ? nameOf(winClaimBy)
            : opponents.map((o) => displayName(o)).join(", ") || "the other player"
        }
        busy={winSending}
        error={winError?.gameId === activeGame.id ? winError.message : null}
        onClaim={() => runWinAction("claim_win")}
        onCancel={() => runWinAction("clear_win_claim")}
        onConfirm={() => runWinAction("confirm_win")}
      />
    ) : null;
  // MUGGINS, 3 AND 4 PLAYERS: no win bar -- the plates ARE the win controls
  // (MugginsPlates; what each says: mugginsPlateStates), me first then
  // clockwise, as the score plates are. A live match: from win_claim_by and
  // win_confirmed_by (kept current like the claim; `?? []` for a row without
  // it); the final board (winnerId): "Won" on the winner's, nothing to tap.
  // The calls are the win bar's, with the same error pill above.
  const mugginsPlatesFor = (players: string[], winnerId: string | null) => (
    <MugginsPlates
      plates={mugginsPlateStates({
        order: seatOrderFrom(players, session.user.id).map((id) => ({ userId: id, name: nameOf(id) })),
        myId: session.user.id,
        claimBy: winnerId ? null : winClaimBy,
        confirmedBy: winnerId ? [] : (activeGame?.win_confirmed_by ?? []),
        winnerId,
      })}
      busy={winSending}
      error={!winnerId && activeGame && winError?.gameId === activeGame.id ? winError.message : null}
      onClaim={() => runWinAction("claim_win")}
      onCancel={() => runWinAction("clear_win_claim")}
      onConfirm={() => runWinAction("confirm_win")}
    />
  );
  // The live controls for a Muggins table of any size (null when there is
  // nothing to claim): the win bar for 2 players, the plates for 3 and 4.
  const mugginsControls =
    capacity > 2
      ? isMuggins && activeGame?.players && isActive
        ? mugginsPlatesFor(activeGame.players, null)
        : null
      : mugginsWinBar;

  // THE SQUARE SCREEN (PRD item 31) -- the default on a 2-player table,
  // unless ?layout=classic (chooseTableLayout), for a dealt
  // hand: the discard, pegging and its hold, and counting through Next Hand
  // (see below); the final board after a win is the next block. 3 players
  // (also by default) have their own square screen (THE SQUARE SCREEN, 3
  // PLAYERS, after the board helpers). Everything else -- the cut for the
  // deal, the waiting room, ?layout=classic -- is the table
  // below, unchanged. A self-scoring (Muggins) table: the self-scoring banner
  // in the board's place (squareBoardFor), the win bar in the plates' place
  // (mugginsWinBar), its tag under the header; scores, flashes and count
  // numbers hidden as on the classic table.
  //
  // Drawing only: the same data and handlers as the table below (the plays,
  // the count, whose turn, Go, the hold, the score flash, my hand and its
  // play action, Sort, the piles, the plates). The dealer's crib and deck
  // sit at the DEALER's seat (seatGeometry: crib on the left of their hand,
  // deck on the right, from their side); no "D" anywhere. The board strip
  // (squareBoardFor, below) above the plates.
  //
  // The whole dealt hand: the discard (phase 'discard'; the starter is cut
  // inside the last discard, so there is no step between), pegging (phase
  // 'play'), the hold after it, and counting ('counting', 'done') once
  // Count hands is tapped -- until Next Hand deals. In the discard the middle
  // keeps the same shape -- the seats' (empty) rows, and CenterCount with the
  // discard's prompt in place of its pill -- so nothing moves when pegging
  // starts, and the score flash stays mounted across that change.
  const squareOpponent = opponents[0];
  // THE BOARD STRIP and the plates for the square screens (PRD item 31, step
  // 1b): each player's lane from the game's seat order (games.players -- the
  // same array on every screen, so the same colours everywhere), their pegs
  // from their row's score and last award (CribbageBoard / nextPegs), and
  // their lane's colour as the ring round their avatar (plates and header).
  // No "D" on the plates. 4-player Teams (teams): a lane per TEAM
  // (laneForPlayer: team 1 red, team 2 blue), both partners ringed in it,
  // each team's pegs on its team score -- from its plate (buildPlates: the
  // team total, and the newest award, the scorer's, for the back peg).
  // 4-player Solo: a lane per player on the 4-lane straight board
  // (boardLanesFor), four plates of one player each.
  const squareBoardFor = (seatOrder: string[], teams = false) => {
    const skin = boardSkin;
    // A self-scoring (Muggins) table (2, 3 or 4 players): no board, pegs or
    // lane rings -- the self-scoring banner in the board strip's slot.
    if (isMuggins) {
      return {
        laneColorOf: (): string | undefined => undefined,
        board: <SelfScoringBanner skin={skin} />,
        plates: plates.map((p) => ({ ...p, hasDealer: false })),
      };
    }
    const seated = seatOrder.flatMap((id) => members.filter((m) => m.user_id === id));
    const laneOfPlayer = (userId: string) => laneForPlayer({ players: seatOrder, userId, teams });
    const laneColorOf = (userId: string) => {
      const lane = laneOfPlayer(userId);
      return lane === null ? undefined : laneRingColor(skin, lane);
    };
    const boardPlayers = teams
      ? plates.flatMap((p) => {
          const lane = p.members[0] ? laneOfPlayer(p.members[0].userId) : null;
          return lane === null
            ? []
            : [{ userId: p.key, name: p.members.map((m) => m.name).join(" & "), lane, score: p.score, lastPoints: p.lastPoints }];
        })
      : seated.map((m) => ({
          userId: m.user_id,
          name: displayName(m),
          lane: laneOfPlayer(m.user_id) ?? -1,
          score: m.score,
          lastPoints: m.last_points,
        }));
    return {
      laneColorOf,
      // 4-player Solo: the 4-lane straight board, whatever the pattern.
      board: (
        <CribbageBoard
          skin={skin}
          pattern={boardPattern}
          lanes={boardLanesFor(seatOrder.length, teams)}
          players={boardPlayers}
        />
      ),
      plates: plates.map((p) => ({
        ...p,
        hasDealer: false,
        laneColor: p.members.length === 1 || teams ? laneColorOf(p.members[0].userId) : undefined,
      })),
    };
  };
  const squareScreen: TableScreen = !isActive
    ? "other"
    : phase === "discard"
      ? "discard"
      : pegView
        ? "pegging"
        : isCountingOrDone && !!view
          ? "counting"
          : "other";
  // THE DEAL AND THE DISCARD TOSSES on a square table (see A LIVE DEAL and A
  // LIVE DISCARD above), for the seats in `dealSeats` (games.players). Once
  // my dealt cards are on screen, the overlay flies every hand in from the
  // dealer's deck, clockwise from the dealer's left -- planned from the seat
  // order, so any seat count, then (3 players) the crib's card. Mine stack in
  // the middle of my hand, then fan out face-up.
  const squareOverlaysFor = (dealSeats: string[]) => {
    const dealPositionOf = (userId: string) => seatPositionOf(dealSeats, session.user.id, userId);
    const dealerPosition = handDealerId ? dealPositionOf(handDealerId) : null;
    const dealOverlay =
      dealInFlight && dealHandKey && handDealerId && dealerPosition && myHand.length === sizes.dealt ? (
        <DealAnimation
          key={dealHandKey}
          plan={dealPlan({
            seatCount: dealSeats.length,
            dealerIndex: dealSeats.indexOf(handDealerId),
            cardsPerSeat: sizes.dealt,
            cribExtras: cribCountDuringDiscard(playerCount, 0),
            stackSeat: dealSeats.indexOf(session.user.id),
          })}
          seats={dealSeats.map(dealPositionOf)}
          dealer={dealerPosition}
          faces={displayedHand}
          onDone={() => setDealDoneKey(dealHandKey)}
        />
      ) : dealInFlight && dealHandKey ? (
        <DealStandby key={dealHandKey} onGiveUp={() => setDealDoneKey(dealHandKey)} />
      ) : null;
    const tossOverlays =
      dealerPosition &&
      tosses.map((t) => (
        <DiscardToss
          key={t.id}
          seats={t.seats}
          dealer={dealerPosition}
          onDone={() => setTosses((current) => current.filter((x) => x.id !== t.id))}
        />
      ));
    return (
      <>
        {dealOverlay}
        {tossOverlays}
      </>
    );
  };

  // THE SQUARE SCREEN, 3 AND 4 PLAYERS (PRD item 31; mockups 04 and 05) --
  // 3 players and 4 players (Teams, and Solo on the 4-lane board) by default
  // (chooseTableLayout; ?layout=classic for the classic table); every seat
  // filled, me among the game's players. Me at the bottom, the next player
  // clockwise on my LEFT, then (4 players: in Teams my partner) the TOP, the
  // last on my RIGHT
  // (seatsOnScreen); 3 players: nobody across. The top seat is drawn as the
  // 2-player across seat -- its name, ring and status word in the header, its
  // hand (and, when it deals, its piles, level with it: ringLayout) as the
  // across row -- and only its played cards in the middle, upside down
  // above the count. Drawing only, from the same data and handlers as the
  // 2-player square screen below and the classic table: the side seats
  // (SquareRingMiddle) hold each player's hand as sideways cards, their Go /
  // discarded / counting word, and -- at the dealer's seat -- the crib and
  // deck; their played cards lie in front of them, the count and pill in the
  // centre (CenterCount), mine below it.
  // COUNTING: each hand turns over in place at its seat when its count comes
  // up, clockwise from the dealer's left (countingReveals, the server's
  // order); the crib last, turned over at the dealer's seat; the counting
  // stage's text, recap and buttons in the centre.
  const ringPlayers = activeGame?.players ?? finalBoard?.players ?? null;
  const ringTable = (screen: TableScreen) =>
    (capacity === 3 || capacity === 4) &&
    chooseTableLayout({ layoutParam, playerCount: capacity, isMuggins, teams: isTeams, screen }) === "square" &&
    opponents.length === capacity - 1 &&
    !!ringPlayers &&
    ringPlayers.length === capacity &&
    ringPlayers.includes(session.user.id) &&
    ringPlayers.every((id) => members.some((m) => m.user_id === id));
  // A seat round me, from the seat order: who sits there and their row.
  const ringMember = (players: string[], position: "left" | "top" | "right") => {
    const id = seatsOnScreen(players, session.user.id)[position];
    return id ? (members.find((m) => m.user_id === id) ?? null) : null;
  };
  const ringPositions = (players: string[]) =>
    (players.length === 4 ? (["left", "top", "right"] as const) : (["left", "right"] as const)) as readonly (
      | "left"
      | "top"
      | "right"
    )[];
  // THE TOP ROW (4 players), from the top seat: the header's name, ring and
  // word (Go, else its status), and its hand -- with its piles, level with
  // it, when it deals (crib on my right, deck on my left: seatGeometry).
  const ringTopRow = (top: RingSeat | undefined, statusKind: "discarded" | "discarding" | "counting" | null, saidGo: boolean) =>
    top
      ? {
          header: {
            name: top.name,
            avatarUrl: top.avatarUrl,
            saidGo,
            laneColor: top.laneColor,
            status: <SeatStatus kind={statusKind} />,
          },
          row: (
            <SquareOpponentHand
              cardCount={top.hand.count}
              counting={
                top.hand.revealed !== undefined
                  ? { cards: (top.hand.cards as string[] | null) ?? null, revealed: top.hand.revealed }
                  : undefined
              }
              shownCards={top.hand.revealed === undefined && top.hand.cards ? (top.hand.cards as string[]) : undefined}
              piles={
                top.piles
                  ? {
                      cribCount: top.piles.cribCount,
                      starter: top.piles.starter,
                      cribSide: seatGeometry("top").crib,
                      cribCards: top.piles.cribCards,
                      starterMoved: top.piles.starterMoved,
                      level: ringLayout({ top: true, sides: true }).acrossPiles === "level",
                    }
                  : null
              }
            />
          ),
        }
      : null;
  if (ringTable(squareScreen) && activeGame && ringPlayers) {
    const players = ringPlayers;
    const ringCount = isCountingOrDone && !!viewN;
    const reveals =
      ringCount && handDealerId
        ? countingReveals({ players, dealerId: handDealerId, step: countStep, done: isDone })
        : null;
    // The crib, face-up at the dealer's seat from its count on.
    const cribFan = reveals?.crib && cribCards ? sortHand(cribCards) : null;
    const iDealHand = handDealerId === session.user.id;
    // The starter in counting: above my hand, or the middle (THE STARTER IN
    // COUNTING).
    const starterPlace = countingStarterPlace(
      handDealerId ? seatPositionOf(players, session.user.id, handDealerId) : null,
      ringCount && !!starterCard
    );
    const movedStarter = countingStarterFor(starterPlace, starterCard, starterSlides);
    const { seats: played, finished: runFinished } = playedBySeat({
      plays,
      playSegment: activeGame.play_segment,
      handOver: onPegHold,
      players,
      myId: session.user.id,
    });
    const ringScores = squareBoardFor(players, isTeams && players.length === 4);
    // A seat's word: Picking… / Discarded in the discard, Counting on its
    // count (Go is shown apart).
    const statusKindOf = (id: string) =>
      phase === "discard" && !cribComplete
        ? discardedBy.includes(id)
          ? ("discarded" as const)
          : ("discarding" as const)
        : ringCount && viewN?.counterId === id
          ? ("counting" as const)
          : null;
    const ringSeats = ringPositions(players).flatMap((position): RingSeat[] => {
      const m = ringMember(players, position);
      if (!m) return [];
      const id = m.user_id;
      return [
        {
          position,
          userId: id,
          name: displayName(m),
          avatarUrl: m.avatar_url,
          laneColor: ringScores.laneColorOf(id),
          status: <SeatStatus kind={goBy.has(id) ? "go" : statusKindOf(id)} />,
          // Counting: their four, face-down until their count comes up (and
          // until the read policies return them).
          hand: ringCount
            ? {
                count: sizes.kept,
                cards: revealedHands[id] ? sortHand(revealedHands[id]) : null,
                revealed: reveals?.hands[id] ?? false,
              }
            : { count: opponentCardCount(id) },
          // The crib pile: nothing while the deal is shown, nor what is
          // still flying to it (squareCribCount).
          piles:
            handDealerId === id
              ? {
                  cribCount: ringCount ? sizes.kept : squareCribCount,
                  cribCards: cribFan,
                  starter: starterCard,
                  starterMoved: starterPlace === "middle",
                }
              : null,
          played: played[position].cards,
        },
      ];
    });
    const topSeat = ringSeats.find((s) => s.position === "top");
    const topRow = ringTopRow(topSeat, topSeat ? statusKindOf(topSeat.userId) : null, !!topSeat && goBy.has(topSeat.userId));
    return (
      <>
        <SquareTableShell
          dealing={dealInFlight}
          overlay={squareOverlaysFor(players)}
          header={
            <SquareTableHeader
              code={code}
              handNo={activeGame.hand_no ?? null}
              opponent={topRow?.header ?? null}
              right={headerRight}
              muggins={isMuggins}
            />
          }
          opponent={topRow?.row ?? null}
          middle={
            <>
              {middleOverlays}
              {ringCount ? (
                <SquareRingMiddle
                  variant="count"
                  seats={ringSeats}
                  played={false}
                  myPlayed={null}
                  center={
                    <div className="sq-count-column flex flex-col items-center gap-2">
                      {starterPlace === "middle" && <div className="sq-count-starter">{movedStarter}</div>}
                      <div className="sq-count-flash">{scoreFlash}</div>
                      {countStageFor({ kind: "none" })}
                    </div>
                  }
                />
              ) : (
                <SquareRingMiddle
                  seats={ringSeats}
                  played={pegView}
                  myPlayed={played.bottom.cards}
                  dimmed={runFinished && !onPegHold}
                  center={
                    <CenterCount
                      plays={plays}
                      playCount={playCount}
                      playSegment={activeGame.play_segment}
                      currentPlayer={activeGame.current_player}
                      myUserId={session.user.id}
                      nameFor={(userId) => displayName(members.find((m) => m.user_id === userId))}
                      handOver={onPegHold ? { onCountHands: () => setPegHoldKey(null) } : undefined}
                      flash={scoreFlash}
                      prompt={pegView ? undefined : !cribComplete ? discardPrompt : <p />}
                    />
                  }
                />
              )}
            </>
          }
          piles={
            <div className="sq-piles">
              <PileRow
                crib={
                  iDealHand
                    ? { faceDownCount: ringCount ? sizes.kept : squareCribCount, shownCards: cribFan, dealerIsMe: false }
                    : null
                }
                starter={iDealHand ? { card: starterCard, moved: starterPlace === "above-hand" } : null}
                above={starterPlace === "above-hand" ? movedStarter : undefined}
              >
                {pileButtons}
              </PileRow>
            </div>
          }
          hand={<div className="sq-hand-row">{hand}</div>}
          board={ringScores.board}
          // A self-scoring (Muggins) table: the plates are the win controls
          // (mugginsPlatesFor).
          scores={
            <div className="sq-plates">
              {isMuggins ? (mugginsControls ?? <div className="h-12" aria-hidden />) : <ScoreStrip plates={ringScores.plates} />}
            </div>
          }
          surface={appearance.surface}
          back={appearance.back}
        />
        <Splash splash={splash} onDone={dismissSplash} />
      </>
    );
  }

  // THE SQUARE FINAL BOARD, 3 AND 4 PLAYERS (by default; 4 players with the
  // top seat as the across row -- Teams: the winning team in the headline
  // and on the board; Solo: the winner, on the 4-lane board): a won game, as the
  // 2-player square final board below does it -- a pegging win shows the
  // run in front of its players with its count, and the rest of each hand
  // at its seat; a count win (or his heels) every hand face-up at its seat
  // and the crib fanned at the dealer's. The result in the centre; the
  // winner's front peg in the game hole.
  const ringWinner = finalBoard ? members.find((m) => m.user_id === finalBoard.winner_id) : undefined;
  if (ringTable("won") && finalBoard && finalBoard.dealer_id && ringWinner && ringPlayers) {
    const players = finalBoard.players;
    const board = finalBoard.board;
    const winReason = ringWinner.last_reason;
    const pegWin =
      !!winReason && !isCountReason(winReason) && winReason !== "his heels" && board.finalRun.length > 0;
    const iDealt = finalBoard.dealer_id === session.user.id;
    const { seats: run } = playedBySeat({
      plays: board.finalRun,
      playSegment: 0,
      handOver: true,
      players,
      myId: session.user.id,
    });
    // At each seat: the whole hand (counting picture), or the rest of it
    // (pegging picture).
    const restOf = (userId: string, position: SeatPosition) => {
      const kept = board.hands[userId] ?? null;
      return kept ? sortHand(pegWin ? kept.filter((c) => !run[position].cards.includes(c)) : kept) : null;
    };
    const faceDownLeft = (inRun: number) => (pegWin ? Math.max(sizes.kept - inRun, 0) : sizes.kept);
    const cribFanned = !pegWin && board.crib ? sortHand(board.crib) : null;
    // The counting picture keeps the starter where counting put it.
    const starterPlace = countingStarterPlace(
      seatPositionOf(players, session.user.id, finalBoard.dealer_id),
      !pegWin && !!finalBoard.starter_card
    );
    const movedStarter = countingStarterFor(starterPlace, finalBoard.starter_card, false);
    const ringScores = squareBoardFor(players, isTeams && players.length === 4);
    const ringSeats = ringPositions(players).flatMap((position): RingSeat[] => {
      const m = ringMember(players, position);
      if (!m) return [];
      const cards = restOf(m.user_id, position);
      return [
        {
          position,
          userId: m.user_id,
          name: displayName(m),
          avatarUrl: m.avatar_url,
          laneColor: ringScores.laneColorOf(m.user_id),
          // The top seat (4 players) spreads its shown hand as the across
          // seat does on the 2-player final board.
          hand: cards
            ? { count: cards.length, cards, ...(position === "top" ? { revealed: true } : {}) }
            : { count: faceDownLeft(run[position].cards.length) },
          piles:
            finalBoard.dealer_id === m.user_id
              ? {
                  cribCount: sizes.kept,
                  cribCards: cribFanned,
                  starter: finalBoard.starter_card,
                  starterMoved: starterPlace === "middle",
                }
              : null,
          played: pegWin ? run[position].cards : [],
        },
      ];
    });
    const myCards = restOf(session.user.id, "bottom");
    const topRow = ringTopRow(
      ringSeats.find((s) => s.position === "top"),
      null,
      false
    );
    return (
      <>
        <SquareTableShell
          header={
            <SquareTableHeader
              code={code}
              handNo={null}
              opponent={topRow?.header ?? null}
              right={headerRight}
              muggins={isMuggins}
            />
          }
          opponent={topRow?.row ?? null}
          middle={
            <>
              {middleOverlays}
              {pegWin ? (
                <SquareRingMiddle
                  variant="final"
                  seats={ringSeats}
                  played
                  myPlayed={run.bottom.cards}
                  center={
                    <CenterCount
                      ended
                      plays={board.finalRun}
                      playCount={0}
                      playSegment={0}
                      currentPlayer={null}
                      myUserId={session.user.id}
                      nameFor={(userId) => displayName(members.find((m) => m.user_id === userId))}
                      flash={scoreFlash}
                    />
                  }
                  below={resultStage}
                />
              ) : (
                <SquareRingMiddle
                  variant="count"
                  seats={ringSeats}
                  played={false}
                  myPlayed={null}
                  center={
                    <div className="sq-count-column flex flex-col items-center gap-2">
                      {starterPlace === "middle" && <div className="sq-count-starter">{movedStarter}</div>}
                      <div className="sq-count-flash">{scoreFlash}</div>
                      {resultStage}
                    </div>
                  }
                />
              )}
            </>
          }
          piles={
            <div className="sq-piles">
              <PileRow
                crib={iDealt ? { faceDownCount: sizes.kept, shownCards: cribFanned, dealerIsMe: false } : null}
                starter={
                  iDealt && finalBoard.starter_card
                    ? { card: finalBoard.starter_card, moved: starterPlace === "above-hand" }
                    : null
                }
                above={starterPlace === "above-hand" ? movedStarter : undefined}
              />
            </div>
          }
          hand={
            <div className="sq-hand-row">
              <HandRow>
                {myCards
                  ? myCards.map((card) => <PlayingCard key={card} card={card} sizing={HAND_CARD} />)
                  : Array.from({ length: faceDownLeft(run.bottom.cards.length) }, (_, i) => (
                      <FaceDownCard key={i} sizing={HAND_CARD} />
                    ))}
              </HandRow>
            </div>
          }
          board={ringScores.board}
          // A self-scoring (Muggins) table: the plates, "Won" on the
          // winner's.
          scores={
            <div className="sq-plates">
              {isMuggins ? mugginsPlatesFor(players, finalBoard.winner_id) : <ScoreStrip plates={ringScores.plates} />}
            </div>
          }
          surface={appearance.surface}
          back={appearance.back}
        />
        <Splash splash={splash} onDone={dismissSplash} />
      </>
    );
  }

  const squareView =
    capacity === 2 &&
    chooseTableLayout({ layoutParam, playerCount: capacity, isMuggins, screen: squareScreen }) === "square" &&
    !!squareOpponent;
  if (squareView && activeGame && squareOpponent) {
    // COUNTING (counting and done, after Count hands): no cards in the
    // middle. Each hand at its seat -- mine face-up in my hand row (the same
    // `hand` as the classic screen), theirs at the top, turned face-up in
    // place once their hand's count comes up (the pone counts at step 0, the
    // dealer at step 1) and staying up; the crib at the dealer's seat,
    // face-up there from its count on (view.cribFan); the starter on the
    // deck throughout. The middle keeps the classic counting stage's text,
    // recap and buttons (countStageFor, with no subject).
    const squareCount = isCountingOrDone && !!view;
    const oppCountStep = handDealerId === squareOpponent.user_id ? 1 : 0;
    const oppHand =
      squareCount && view && view.middle.kind === "full" ? view.middle.cards : null;
    const oppHandUp = isDone || countStep >= oppCountStep;
    const cribFan = squareCount && view ? view.cribFan : null;
    const iDealHand = handDealerId === session.user.id;
    // The starter in counting: above my hand, or the middle (THE STARTER IN
    // COUNTING).
    const starterPlace = countingStarterPlace(
      handDealerId ? squarePositionOf(handDealerId) : null,
      squareCount && !!starterCard
    );
    const movedStarter = countingStarterFor(starterPlace, starterCard, starterSlides);
    const oppName = displayName(squareOpponent);
    // The crib pile: nothing while the deal is shown, nor what is still
    // flying to it (squareCribCount).
    const cribCount = squareCribCount;
    const { seats: played, finished: runFinished } = playedBySeat({
      plays,
      playSegment: activeGame.play_segment,
      handOver: onPegHold,
      players: activeGame.players ?? [session.user.id, squareOpponent.user_id],
      myId: session.user.id,
    });
    // The other player's seat is across the table (2 players).
    const across = seatGeometry("top");
    const squareScores = squareBoardFor(activeGame.players ?? [session.user.id, squareOpponent.user_id]);
    // THE DEAL and THE DISCARD TOSSES in flight (squareOverlaysFor).
    const dealSeats = activeGame.players ?? [session.user.id, squareOpponent.user_id];
    return (
      <>
        <SquareTableShell
          dealing={dealInFlight}
          overlay={
            <>
              {squareOverlaysFor(dealSeats)}
              {/* The computer's discard, shown on time (no UI of its own). */}
              {shownComputerId && (
                <ComputerDiscardClock
                  input={discardShowInput}
                  state={discardShow}
                  onState={setDiscardShow}
                  onShow={showComputerDiscard}
                />
              )}
            </>
          }
          header={
            <SquareTableHeader
              code={code}
              handNo={activeGame.hand_no ?? null}
              opponent={{
                name: oppName,
                avatarUrl: squareOpponent.avatar_url,
                saidGo: goBy.has(squareOpponent.user_id),
                laneColor: squareScores.laneColorOf(squareOpponent.user_id),
              }}
              right={headerRight}
              muggins={isMuggins}
            />
          }
          opponent={
            <SquareOpponentHand
              cardCount={squareCount ? sizes.kept : opponentCardCount(squareOpponent.user_id)}
              counting={squareCount ? { cards: oppHand, revealed: oppHandUp } : undefined}
              // They deal: their crib and deck on their side, crib on their
              // left -- my right (seatGeometry("top").crib).
              piles={
                iDealHand
                  ? null
                  : {
                      cribCount: squareCount ? sizes.kept : cribCount,
                      starter: starterCard,
                      cribSide: across.crib,
                      cribCards: cribFan,
                      starterMoved: starterPlace === "middle",
                    }
              }
            />
          }
          middle={
            squareCount ? (
              <>
                {middleOverlays}
                <div className="square-middle square-middle--count">
                  {starterPlace === "middle" && <div className="sq-count-starter">{movedStarter}</div>}
                  <div className="sq-count-flash">{scoreFlash}</div>
                  {countStageFor({ kind: "none" })}
                </div>
              </>
            ) : (
            <>
              {middleOverlays}
              <div className="square-middle">
                <SeatPlayedCards
                  cards={played.top.cards}
                  rotation={across.rotation}
                  label={`${oppName}'s played cards`}
                  dimmed={runFinished && !onPegHold}
                  scale={0.89}
                />
                <CenterCount
                  plays={plays}
                  playCount={playCount}
                  playSegment={activeGame.play_segment}
                  currentPlayer={activeGame.current_player}
                  myUserId={session.user.id}
                  nameFor={(userId) => displayName(members.find((m) => m.user_id === userId))}
                  handOver={onPegHold ? { onCountHands: () => setPegHoldKey(null) } : undefined}
                  flash={scoreFlash}
                  // The discard: its prompt, as on the classic screen (and,
                  // with every discard in but the phase not yet moved on, an
                  // empty line, as the classic middle shows nothing then;
                  // the computer's discard counts once shown).
                  prompt={pegView ? undefined : !cribShownComplete ? discardPrompt : <p />}
                />
                <SeatPlayedCards
                  cards={played.bottom.cards}
                  rotation={seatGeometry("bottom").rotation}
                  label="Your played cards"
                  dimmed={runFinished && !onPegHold}
                />
              </div>
            </>
            )
          }
          piles={
            <div className="sq-piles">
              <PileRow
                crib={
                  iDealHand
                    ? {
                        faceDownCount: squareCount ? sizes.kept : cribCount,
                        shownCards: cribFan,
                        dealerIsMe: false,
                      }
                    : null
                }
                starter={iDealHand ? { card: starterCard, moved: starterPlace === "above-hand" } : null}
                above={starterPlace === "above-hand" ? movedStarter : undefined}
              >
                {pileButtons}
              </PileRow>
            </div>
          }
          hand={<div className="sq-hand-row">{hand}</div>}
          board={squareScores.board}
          // A self-scoring (Muggins) table: the win bar in the plates' place,
          // exactly as the classic table shows it in its strip's.
          scores={
            <div className="sq-plates">
              {isMuggins ? mugginsWinBar : <ScoreStrip plates={squareScores.plates} />}
            </div>
          }
          surface={appearance.surface}
          back={appearance.back}
        />
        <Splash splash={splash} onDone={dismissSplash} />
      </>
    );
  }

  // THE SQUARE FINAL BOARD (2 players, not Muggins, by default): a won
  // game, from the same finalBoard data as the classic final board. How it
  // was won picks the picture -- the winner's last award IS the winning one:
  //   * a hand or crib count, or his heels: the counting picture -- every
  //     hand face-up at its seat, the crib fanned at the dealer's seat, the
  //     starter on the deck; no pegging cards and no count;
  //   * a peg: the pegging picture -- the run on the table in front of its
  //     players with its count in the centre, the crib face-down at the
  //     dealer's seat, and at each seat the rest of that hand (the four kept
  //     minus that player's cards in the run: the board keeps only the last
  //     run, so cards played in an earlier run of that hand still show here).
  // The centre is the classic result: the banner, the ready lines, New Game.
  // No "D". The table below (classic) instead: a game that ended any other
  // way (no board), a won game whose winner or other player has left the
  // table, or one with no dealer recorded.
  const finalWinner = finalBoard ? members.find((m) => m.user_id === finalBoard.winner_id) : undefined;
  const squareFinal =
    chooseTableLayout({ layoutParam, playerCount: capacity, isMuggins, screen: finalBoard ? "won" : "other" }) ===
      "square" &&
    !!finalBoard &&
    !!finalBoard.dealer_id &&
    !!squareOpponent &&
    !!finalWinner &&
    finalBoard.players.length === 2 &&
    finalBoard.players.includes(session.user.id) &&
    finalBoard.players.includes(squareOpponent.user_id);
  if (squareFinal && finalBoard && squareOpponent && finalWinner) {
    const board = finalBoard.board;
    const winReason = finalWinner.last_reason;
    const pegWin =
      !!winReason && !isCountReason(winReason) && winReason !== "his heels" && board.finalRun.length > 0;
    const iDealt = finalBoard.dealer_id === session.user.id;
    const across = seatGeometry("top");
    const oppName = displayName(squareOpponent);
    const { seats: run } = playedBySeat({
      plays: board.finalRun,
      playSegment: 0,
      handOver: true,
      players: finalBoard.players,
      myId: session.user.id,
    });
    const myKept = board.hands[session.user.id] ?? null;
    const oppKept = board.hands[squareOpponent.user_id] ?? null;
    // At each seat: the whole hand (counting picture), or the rest of it
    // (pegging picture).
    const myCards = myKept
      ? sortHand(pegWin ? myKept.filter((c) => !run.bottom.cards.includes(c)) : myKept)
      : null;
    const oppCards = oppKept
      ? sortHand(pegWin ? oppKept.filter((c) => !run.top.cards.includes(c)) : oppKept)
      : null;
    const cribFanned = !pegWin && board.crib ? sortHand(board.crib) : null;
    const faceDownLeft = (inRun: number) => (pegWin ? Math.max(sizes.kept - inRun, 0) : sizes.kept);
    // The counting picture keeps the starter where counting put it.
    const starterPlace = countingStarterPlace(iDealt ? "bottom" : "top", !pegWin && !!finalBoard.starter_card);
    const movedStarter = countingStarterFor(starterPlace, finalBoard.starter_card, false);
    // The board: the winner's front peg in the game hole (121+ is the game
    // hole).
    const squareScores = squareBoardFor(finalBoard.players);
    return (
      <>
        <SquareTableShell
          header={
            <SquareTableHeader
              code={code}
              handNo={null}
              opponent={{
                name: oppName,
                avatarUrl: squareOpponent.avatar_url,
                saidGo: false,
                laneColor: squareScores.laneColorOf(squareOpponent.user_id),
              }}
              right={headerRight}
              muggins={isMuggins}
            />
          }
          opponent={
            <SquareOpponentHand
              cardCount={oppCards ? oppCards.length : faceDownLeft(run.top.cards.length)}
              counting={{ cards: oppCards, revealed: true }}
              piles={
                iDealt
                  ? null
                  : {
                      cribCount: sizes.kept,
                      starter: finalBoard.starter_card,
                      cribSide: across.crib,
                      cribCards: cribFanned,
                      starterMoved: starterPlace === "middle",
                    }
              }
            />
          }
          middle={
            pegWin ? (
              <>
                {middleOverlays}
                <div className="square-middle square-middle--final">
                  <SeatPlayedCards
                    cards={run.top.cards}
                    rotation={across.rotation}
                    label={`${oppName}'s played cards`}
                    scale={0.89}
                  />
                  <CenterCount
                    ended
                    plays={board.finalRun}
                    playCount={0}
                    playSegment={0}
                    currentPlayer={null}
                    myUserId={session.user.id}
                    nameFor={(userId) => displayName(members.find((m) => m.user_id === userId))}
                    flash={scoreFlash}
                  />
                  {resultStage}
                  <SeatPlayedCards
                    cards={run.bottom.cards}
                    rotation={seatGeometry("bottom").rotation}
                    label="Your played cards"
                  />
                </div>
              </>
            ) : (
              <>
                {middleOverlays}
                <div className="square-middle square-middle--count">
                  {starterPlace === "middle" && <div className="sq-count-starter">{movedStarter}</div>}
                  <div className="sq-count-flash">{scoreFlash}</div>
                  {resultStage}
                </div>
              </>
            )
          }
          piles={
            <div className="sq-piles">
              <PileRow
                crib={iDealt ? { faceDownCount: sizes.kept, shownCards: cribFanned, dealerIsMe: false } : null}
                starter={
                  iDealt && finalBoard.starter_card
                    ? { card: finalBoard.starter_card, moved: starterPlace === "above-hand" }
                    : null
                }
                above={starterPlace === "above-hand" ? movedStarter : undefined}
              />
            </div>
          }
          hand={
            <div className="sq-hand-row">
              <HandRow>
                {myCards
                  ? myCards.map((card) => <PlayingCard key={card} card={card} sizing={HAND_CARD} />)
                  : Array.from({ length: faceDownLeft(run.bottom.cards.length) }, (_, i) => (
                      <FaceDownCard key={i} sizing={HAND_CARD} />
                    ))}
              </HandRow>
            </div>
          }
          board={squareScores.board}
          // A self-scoring (Muggins) table shows no score: after the match
          // there's nothing to claim either, so the plates' row stays empty
          // (its height kept, so the banner sits where it did).
          scores={
            <div className="sq-plates">
              {isMuggins ? <div className="h-12" aria-hidden /> : <ScoreStrip plates={squareScores.plates} />}
            </div>
          }
          surface={appearance.surface}
          back={appearance.back}
        />
        <Splash splash={splash} onDone={dismissSplash} />
      </>
    );
  }

  return (
    <>
    <TableShell
      header={header}
      // Phase 3 (3 and 4 players): the waiting room leaves out the
      // opponents band, the piles, the hand row and the scores, to give the
      // seats the room. In a game, the player across the top (4 players)
      // uses the band, and the players on my left and right the sides. A
      // 2-player table is never any of these.
      opponents={
        isCutting || inWaitingRoom
          ? null
          : phase3Layout
            ? topSeat
              ? <OpponentBand seats={[topSeat]} />
              : null
            : // Alone at a 2-player table: the middle's WaitingForPlayer
              // says it, so the band stays quiet (the message shows once).
              <OpponentBand seats={seats} waitingShown={waitingAlone} />
      }
      sides={
        phase3Layout
          ? {
              left: leftSeat ? <SideSeat seat={leftSeat} side="left" /> : null,
              right: rightSeat ? <SideSeat seat={rightSeat} side="right" /> : null,
            }
          : undefined
      }
      middle={middle}
      piles={isCutting || inWaitingRoom ? null : piles}
      // The hand row reserves its full height even when empty (no game yet),
      // so the table doesn't jump when cards are dealt -- except during the
      // cut, which needs the space and has no hand to show.
      hand={isCutting || inWaitingRoom ? null : hand}
      // A Muggins table has no score strip: the win bar takes its place (see
      // mugginsWinBar; 3 and 4 players, the plates: mugginsControls), and
      // nothing at all -- no height -- while no game is dealt.
      scores={
        inWaitingRoom ? null : isMuggins ? mugginsControls : <ScoreStrip plates={plates} />
      }
      surface={appearance.surface}
      back={appearance.back}
    />
    {/* The splash: outside the shell, since the middle's size container
        would pin a fixed overlay to the middle instead of the screen. */}
    <Splash splash={splash} onDone={dismissSplash} />
    </>
  );
}
