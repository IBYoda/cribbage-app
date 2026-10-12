"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { supabase } from "@/lib/supabase";
import { cardPlayValue, sortHand } from "@/lib/cards";
import { FaceDownCard, PlayingCard } from "@/components/PlayingCard";
import { CutForDealView } from "@/components/CutForDealView";
import { TableHeader, TableShell } from "@/components/table/TableShell";
import { OpponentBand, type OpponentSeat } from "@/components/table/OpponentBand";
import { PileRow } from "@/components/table/PileRow";
import { HandRow } from "@/components/table/HandRow";
import { ScoreFlash, ScoreStrip, type ScorePlate } from "@/components/table/ScoreStrip";
import { HAND_CARD } from "@/components/table/sizes";
import { countingView } from "@/components/table/countingView";
import { CountStage, SlotCards } from "@/components/table/CountStage";
import { PlayArea, displayedRun, goSayers, type PlayEvent } from "@/components/PlayArea";

type TableRow = {
  id: string;
  code: string;
  status: string;
};

type Member = {
  user_id: string;
  nickname: string | null;
  // For the score plate. Optional on the profile; plates fall back to an initial.
  avatar_url: string | null;
  joined_at: string;
  // The running score, and the last award that moved it. Lives on
  // table_members because that table is already keyed (table_id, user_id) --
  // exactly the grain a per-player running total needs.
  score: number;
  last_points: number | null;
  last_reason: string | null;
  last_awarded_at: string | null;
};

const MEMBER_COLUMNS =
  "user_id, joined_at, score, last_points, last_reason, last_awarded_at";

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
};

// Must stay a single string LITERAL, not a concatenation: supabase-js infers
// the returned row shape from this exact literal type, and "a" + "b" widens to
// plain `string`, which silently collapses the result type to an error type.
const GAME_COLUMNS =
  "id, created_at, status, players, dealer_id, discarded_by, deal_cut, deal_cut_ack_by, starter_card, phase, current_player, play_count, play_segment, count_step, revealed_by, crib_revealed, winner_id, hand_no, ready_by";

// The last game to end in a win, kept after the live game is gone so the
// result stays on screen (and survives a reload) until the next game starts.
// players and ready_by are the New Game ready gate's: who played the match,
// and who has tapped New Game since (stored on the WON game's own row).
// starter_card, dealer_id and board are THE FINAL BOARD: the table as the
// match ended -- the starter, whose hand it was, and (board) the last run, both
// hands and the crib.
type FinishedGame = {
  id: string;
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
type WonBoard = {
  finalRun: PlayEvent[];
  hands: Record<string, string[]>;
  crib: string[] | null;
};

function finalRunOf(plays: PlayEvent[], playSegment: number) {
  return displayedRun(plays, playSegment, true).events;
}

// Reads the final board of a won game. game_plays is readable by any logged-in
// user; game_hands and game_cribs by RLS (see WonBoard above). Rows stay until
// next_hand, which an ended game never reaches.
async function readWonBoard(gameId: string, playSegment: number): Promise<WonBoard> {
  const [{ data: playRows }, { data: handRows }, { data: cribRow }] = await Promise.all([
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
  };
}

// Both lists, without repeats. The won game's ready_by only ever grows (the
// gate appends to it; nothing else writes it once the game has ended), so the
// union of two reads is never older than either -- which is what lets a REST
// read and a realtime event land in any order without rolling the other back.
function unionIds(a: string[], b: string[]) {
  return [...a, ...b.filter((id) => !a.includes(id))];
}

// The key for "has visibility changed?" -- compared on every games UPDATE so
// hands and the crib are refetched only when a reveal actually happened, not
// on every unrelated broadcast.
function revealKey(revealedBy: string[] | null | undefined, cribRevealed: boolean | null | undefined) {
  return `${(revealedBy ?? []).join(",")}|${cribRevealed ? 1 : 0}`;
}

// A game is "live" while it is either cutting for deal or actually being
// played. Both block a second game at the table, and both must be found by the
// client, the admin view, leave-table and the timeout sweep.
const LIVE_GAME_STATUSES = ["cutting", "active"];

const REQUIRED_PLAYERS = 2;
const CARDS_DEALT = 6;
const CARDS_TO_DISCARD = 2;
const CARDS_AFTER_DISCARD = CARDS_DEALT - CARDS_TO_DISCARD;

function tableEndedMessage(endedReason: string | null | undefined) {
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
  const code = params.code;

  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [table, setTable] = useState<TableRow | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [activeGame, setActiveGame] = useState<Game | null>(null);
  const [gameStatus, setGameStatus] = useState<"idle" | "creating" | "error">("idle");
  const [gameMessage, setGameMessage] = useState<string | null>(null);
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

    const { data } = await supabase
      .from("game_hands")
      .select("cards")
      .eq("game_id", gameId)
      .eq("user_id", myId)
      .maybeSingle();

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

      // A hand or the crib was just shown -- refetch what the read policies
      // now allow. Only from counting on, the only time anything can be shown.
      const key = revealKey(row.revealed_by, row.crib_revealed);
      if ((row.phase === "counting" || row.phase === "done") && key !== revealKeyRef.current) {
        revealKeyRef.current = key;
        fetchRevealed(row.id);
      }

      // The cut resolved and the cards were dealt (acknowledge_deal_cut flips
      // cutting -> active in the same statement that deals).
      if (previousStatus === "cutting" && row.status === "active") {
        setHandSorted(false); // freshly dealt -- show it as dealt
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

  // Fetches the current active game + full roster for a table. Used both for
  // the initial load and to "catch up" after the realtime connection drops
  // and reconnects, since postgres_changes only streams events that happen
  // while connected -- anything missed during a disconnect has to be re-fetched.
  const refreshTableState = useCallback(async (tableId: string) => {
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
        setMyHand([]);
        setPlays([]);
      }

      // Shown hands and the crib only exist from counting on.
      if (
        existingGame &&
        existingGame.status === "active" &&
        (existingGame.phase === "counting" || existingGame.phase === "done")
      ) {
        revealKeyRef.current = revealKey(existingGame.revealed_by, existingGame.crib_revealed);
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
            "id, ended_reason, winner_id, players, ready_by, starter_card, dealer_id, play_segment"
          )
          .eq("table_id", tableId)
          .order("created_at", { ascending: false })
          .limit(1)
          .maybeSingle();

        const finished: FinishedGame | null =
          lastGame && lastGame.ended_reason === "won"
            ? {
                id: lastGame.id,
                winner_id: lastGame.winner_id,
                players: lastGame.players ?? [],
                ready_by: lastGame.ready_by ?? [],
                starter_card: lastGame.starter_card,
                dealer_id: lastGame.dealer_id,
                board: await readWonBoard(lastGame.id, lastGame.play_segment ?? 0),
              }
            : null;

        // Still the newest read? The board read above is one more wait, and a
        // later read (a New Game starting, say) must not be undone by this.
        if (gameAppliedSeqRef.current === ticket) showFinishedGame(finished);
      }
    }

    const { data: memberRows, error: membersError } = await supabase
      .from("table_members")
      .select(MEMBER_COLUMNS)
      .eq("table_id", tableId)
      .order("joined_at", { ascending: true });

    if (membersError) {
      setError(membersError.message);
      return;
    }

    const userIds = (memberRows ?? []).map((m) => m.user_id);
    const { data: profileRows } = await supabase
      .from("profiles")
      .select("id, nickname, avatar_url")
      .in("id", userIds.length > 0 ? userIds : [""]);

    const profileById = new Map((profileRows ?? []).map((p) => [p.id, p]));

    setMembers(
      (memberRows ?? []).map((m) => ({
        user_id: m.user_id,
        joined_at: m.joined_at,
        nickname: profileById.get(m.user_id)?.nickname ?? null,
        avatar_url: profileById.get(m.user_id)?.avatar_url ?? null,
        score: m.score ?? 0,
        last_points: m.last_points,
        last_reason: m.last_reason,
        last_awarded_at: m.last_awarded_at,
      }))
    );
    setMembersLoaded(true);
  }, [fetchMyHand, fetchPlays, fetchRevealed, clearRevealed, resetHandState, showFinishedGame]);

  // Look up the table, join it (idempotent), then load the current roster.
  // retryKey lets the error screen's "Retry" button re-run this from scratch.
  useEffect(() => {
    if (!session) return;

    let cancelled = false;

    async function setup() {
      setError(null);

      const { data: tableRow, error: tableError } = await supabase
        .from("tables")
        .select("id, code, status, ended_reason")
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
        setError(tableEndedMessage(tableRow.ended_reason));
        return;
      }

      setTable(tableRow);

      const { error: joinError } = await supabase
        .from("table_members")
        .upsert(
          { table_id: tableRow.id, user_id: session!.user.id },
          { onConflict: "table_id,user_id", ignoreDuplicates: true }
        );

      if (cancelled) return;
      if (joinError) {
        setError(joinError.message);
        return;
      }

      await refreshTableState(tableRow.id);
    }

    setup();

    return () => {
      cancelled = true;
    };
  }, [session, code, retryKey, refreshTableState]);

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

    const { data: newGameId, error: rpcError } = await supabase.rpc("start_game_with_deal", {
      p_table_id: table.id,
    });

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

  async function handleLeave() {
    if (!table) return;

    setLeaveStatus("leaving");
    setLeaveMessage(null);

    const { error: rpcError } = await supabase.rpc("leave_table", {
      p_table_id: table.id,
    });

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

    const { error: rpcError } = await supabase.rpc("draw_cut_card", {
      p_game_id: activeGame.id,
    });

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

    const { error: rpcError } = await supabase.rpc("acknowledge_deal_cut", {
      p_game_id: activeGame.id,
    });

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

    const { error: rpcError } = await supabase.rpc("play_card", {
      p_game_id: activeGame.id,
      p_card: card,
    });

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

    const { error: rpcError } = await rpc();

    if (rpcError) {
      setCountStatus("error");
      setCountMessage(rpcError.message);
      return;
    }

    if (table) await refreshTableState(table.id);
    setCountStatus("idle");
  }

  function handleShowHand() {
    if (!activeGame) return;
    const gameId = activeGame.id;
    return runCountAction(() => supabase.rpc("show_hand", { p_game_id: gameId }));
  }

  function handleShowCrib() {
    if (!activeGame) return;
    const gameId = activeGame.id;
    return runCountAction(() => supabase.rpc("show_crib", { p_game_id: gameId }));
  }

  // p_step is the step THIS screen is showing. If the server has already moved
  // past it (a double tap, a second tab) the call returns quietly instead of
  // scoring twice; a step ahead of the server is rejected.
  function handleConfirmCount(step: number) {
    if (!activeGame) return;
    const gameId = activeGame.id;
    return runCountAction(() =>
      supabase.rpc("confirm_count", { p_game_id: gameId, p_step: step })
    );
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
      if (current.length >= CARDS_TO_DISCARD) return current;
      return [...current, card];
    });
  }

  async function handleDiscard() {
    if (!activeGame || selectedCards.length !== CARDS_TO_DISCARD) return;

    setDiscardStatus("sending");
    setDiscardMessage(null);

    const { error: rpcError } = await supabase.rpc("discard_to_crib", {
      p_game_id: activeGame.id,
      p_cards: selectedCards,
    });

    if (rpcError) {
      // The function's guards (already discarded, not your card, game no longer
      // active) surface here as readable messages.
      setDiscardStatus("error");
      setDiscardMessage(rpcError.message);
      return;
    }

    // Re-read for the same reason as above: the hand and discarded_by are both
    // server-owned now. The opponent learns about this via the games UPDATE
    // broadcast, which carries discarded_by but never the crib's contents.
    if (table) await refreshTableState(table.id);
    setDiscardStatus("idle");
  }

  // Live updates: append anyone who joins after we've loaded the roster.
  useEffect(() => {
    if (!table) return;

    // Tracks whether we've seen the channel go down, so we only resync on a
    // genuine reconnect -- not on the very first successful subscribe (the
    // setup effect above already fetched fresh state for that case).
    let wasDisconnected = false;

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
          const newRow = payload.new as {
            user_id: string;
            joined_at: string;
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
          // The score tracker's live channel. award_points() is the only thing
          // that writes these columns, so in practice every event here is a
          // score change -- the number moves on both screens at once, and the
          // "+2 — pair" flash fires off last_awarded_at changing.
          //
          // table_members has been in the realtime publication since Slice 4
          // with UPDATE already enabled, so this listener needed no SQL at all.
          const updated = payload.new as {
            user_id: string;
            score: number | null;
            last_points: number | null;
            last_reason: string | null;
            last_awarded_at: string | null;
          };

          setMembers((current) =>
            current.map((m) =>
              m.user_id === updated.user_id
                ? {
                    ...m,
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
            // null, so PlayerScore moves to 0 without a flash.
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
          const updatedGame = payload.new as {
            id: string;
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
                    mine && mine.cards.length === CARDS_AFTER_DISCARD
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
          const updatedTable = payload.new as { status: string; ended_reason: string | null };
          if (updatedTable.status !== "open") {
            setError(tableEndedMessage(updatedTable.ended_reason));
          }
        }
      )
      .subscribe((status) => {
        if (status === "SUBSCRIBED") {
          setRealtimeStatus("connected");
          if (wasDisconnected) {
            wasDisconnected = false;
            // We were disconnected and just reconnected -- postgres_changes
            // only streams events that happen while connected, so anything
            // that changed while we were down (a join, a new game, a
            // nickname edit) was missed. Re-fetch to catch up.
            refreshTableState(table.id);
          }
        } else if (status === "CLOSED" || status === "TIMED_OUT" || status === "CHANNEL_ERROR") {
          wasDisconnected = true;
          setRealtimeStatus("disconnected");
        }
      });

    return () => {
      supabase.removeChannel(channel);
    };
  }, [table, refreshTableState, fetchMyHand, clearRevealed, resetHandState, afterGameChange, reconcileGame, showFinishedGame]);

  // Keeps the ref above in step with state. Assigning a ref is not a state
  // update, so this is a legitimate effect rather than a cascading render.
  useEffect(() => {
    activeGameIdRef.current = activeGame?.id ?? null;
  }, [activeGame?.id]);

  if (loading) {
    return (
      <main className="flex flex-1 items-center justify-center">
        <p>Loading...</p>
      </main>
    );
  }

  if (!session) {
    return (
      <main className="flex flex-1 flex-col items-center justify-center gap-4 p-8">
        <p>You need to be logged in to join a table.</p>
        <Link href="/login" className="underline">
          Log in
        </Link>
      </main>
    );
  }

  if (error) {
    return (
      <main className="flex flex-1 flex-col items-center justify-center gap-4 p-8">
        <p className="text-red-600">{error}</p>
        <div className="flex gap-4">
          <button
            onClick={() => setRetryKey((k) => k + 1)}
            className="rounded bg-foreground px-4 py-2 text-background"
          >
            Retry
          </button>
          <Link
            href="/tables/join"
            className="rounded border border-zinc-300 px-4 py-2 dark:border-zinc-700"
          >
            Try a different code
          </Link>
        </div>
      </main>
    );
  }

  const me = members.find((m) => m.user_id === session.user.id);
  // Seating: everyone who isn't you sits across the top. Rendered from an
  // array rather than a single hardcoded opponent so 3- and 4-player tables
  // (Phase 3) slot in without restructuring the layout.
  const opponents = members.filter((m) => m.user_id !== session.user.id);
  const canStartGame = members.length === REQUIRED_PLAYERS;

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
  const cribComplete = discardedBy.length >= REQUIRED_PLAYERS;
  const iAmDealer = activeGame?.dealer_id === session.user.id;
  const waitingOn = opponents.filter((o) => !discardedBy.includes(o.user_id));
  const canDiscard = Boolean(activeGame) && !iHaveDiscarded && myHand.length === CARDS_DEALT;

  // The cut phase. Only the table's FIRST game cuts -- later games alternate
  // the deal, are created straight into 'active', and never enter this.
  const isCutting = activeGame?.status === "cutting";

  // COUNTING. activeGame only ever holds a LIVE game (the realtime handler
  // drops it the moment status leaves cutting/active), so every phase check
  // below already sits behind a status check.
  const isDone = isActive && phase === "done";
  // Who deals the next hand: the current pone -- the player who isn't
  // dealing now. Display only; next_hand decides it on the server (the
  // player after the dealer, which in 2-player is the same person).
  const nextDealerId = activeGame?.players?.find((p) => p !== activeGame?.dealer_id) ?? null;
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
  const revealedBy = activeGame?.revealed_by ?? [];
  const cribRevealed = activeGame?.crib_revealed ?? false;
  const starterCard = activeGame?.starter_card ?? null;
  const iHaveShown = revealedBy.includes(session.user.id);
  const countBusy = countStatus === "sending";

  // THE COUNTING VIEW (UI polish, stage 3): what goes in my hand row, in the
  // middle, in the opponent's strip and in the crib pile at each step --
  // decided in one pure function (components/table/countingView.ts) that the
  // layout mock calls too. 2-player: the one opponent.
  const countOpp = opponents[0];
  const view =
    isCountingOrDone && activeGame?.dealer_id && countOpp
      ? countingView({
          myId: session.user.id,
          dealerId: activeGame.dealer_id,
          oppName: displayName(countOpp),
          phase: isDone ? "done" : "counting",
          step: countStep,
          myHand: sortHand(myHand),
          oppCards:
            revealedBy.includes(countOpp.user_id) && revealedHands[countOpp.user_id]
              ? sortHand(revealedHands[countOpp.user_id])
              : null,
          cribCards: cribCards ? sortHand(cribCards) : null,
          starter: starterCard,
          iHaveShown,
          cribRevealed,
        })
      : null;

  const winner = members.find((m) => m.user_id === finishedGame?.winner_id);
  // THE FINAL BOARD: the won game's result, while no game is live.
  const finalBoard = activeGame ? null : finishedGame;
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
      const played = plays.filter((p) => p.kind === "play" && p.user_id === opponentId).length;
      return Math.max(CARDS_AFTER_DISCARD - played, 0);
    }
    if (isCountingOrDone) return CARDS_AFTER_DISCARD;
    return discardedBy.includes(opponentId) ? CARDS_AFTER_DISCARD : CARDS_DEALT;
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
  const goLabel = <span className="text-xs font-semibold text-amber-600 dark:text-amber-500">Go</span>;

  // Opponents across the top. Each seat's hand is drawn face-down from the
  // public hand size, or face-up -- sorted, as on every screen from counting
  // onward -- once it has been shown.
  const seats: OpponentSeat[] = opponents.map((opponent) => {
    const shown = revealedBy.includes(opponent.user_id) ? revealedHands[opponent.user_id] : undefined;
    return {
      userId: opponent.user_id,
      name: displayName(opponent),
      isDealer: handDealerId === opponent.user_id,
      // In counting the strip keeps only a hand still WAITING to be counted
      // (face-down); a hand being counted is in the middle, and a counted
      // one has cleared.
      // The final board: the hand face-up when readable, else face-down.
      cardCount: finalBoard
        ? CARDS_AFTER_DISCARD
        : view
          ? view.oppBandCount
          : opponentCardCount(opponent.user_id),
      shownCards: finalBoard
        ? finalBoard.board.hands[opponent.user_id]
          ? sortHand(finalBoard.board.hands[opponent.user_id])
          : undefined
        : view
          ? undefined
          : shown
            ? sortHand(shown)
            : undefined,
      saidGo: goBy.has(opponent.user_id),
    };
  });

  // One plate per player (2-player). Built as a list so a 4-player team game
  // only has to group members into plates -- see ScoreStrip.
  const plates: ScorePlate[] = [...(me ? [me] : []), ...opponents].map((m) => ({
    key: m.user_id,
    members: [{ userId: m.user_id, name: displayName(m), avatarUrl: m.avatar_url }],
    score: m.score,
    isMine: m.user_id === session.user.id,
    hasDealer: handDealerId === m.user_id,
    lastPoints: m.last_points,
    lastReason: m.last_reason,
    lastAwardedAt: m.last_awarded_at,
  }));

  // Every error the old layout stacked into the page as extra lines now
  // shares one overlay at the bottom of the middle region.
  const errorToast =
    (leaveStatus === "error" && leaveMessage) ||
    (discardStatus === "error" && discardMessage) ||
    (playStatus === "error" && playMessage) ||
    (gameStatus === "error" && gameMessage) ||
    null;

  const header = (
    <TableHeader
      code={code}
      handNo={isActive ? (activeGame?.hand_no ?? null) : null}
      right={
        <>
          {realtimeStatus === "disconnected" && (
            <span className="text-xs text-amber-600 dark:text-amber-500">Reconnecting...</span>
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
      }
    />
  );

  const middle = (
    <>
      {/* Overlays: never part of the flow, so they can't grow the table. */}
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
          iHaveDiscarded ? (
            <p className="text-sm text-zinc-500">
              Waiting for {waitingOn.map(displayName).join(", ")} to discard...
            </p>
          ) : (
            <p className="text-base font-medium">
              Pick {CARDS_TO_DISCARD} cards for {iAmDealer ? "your" : "their"} crib
            </p>
          )
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
                MY turn; otherwise a plain "X is counting". Each confirmed
                count leaves a small recap line. */}
            {view && (
              <CountStage
                headline={view.headline}
                hint={isDone ? `Next dealer: ${nextDealerName}` : view.hint}
                subject={view.middle}
                subjectLabel={view.middleLabel}
                recap={view.recap}
                error={countStatus === "error" ? countMessage : null}
                actions={
                  isDone ? (
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
                    <>
                      {view.showHandButton && (
                        <button
                          onClick={handleShowHand}
                          disabled={countBusy}
                          className="min-h-10 rounded border border-zinc-400 px-4 text-sm font-medium disabled:opacity-40 dark:border-zinc-600"
                        >
                          Show Hand
                        </button>
                      )}
                      {view.showCribButton && (
                        <button
                          onClick={handleShowCrib}
                          disabled={countBusy}
                          className="min-h-10 rounded border border-zinc-400 px-4 text-sm font-medium disabled:opacity-40 dark:border-zinc-600"
                        >
                          Show Crib
                        </button>
                      )}
                      <button
                        onClick={() => handleConfirmCount(countStep)}
                        disabled={!view.canConfirm || countBusy}
                        className="min-h-10 rounded bg-foreground px-4 text-sm font-medium text-background disabled:opacity-40"
                      >
                        {countBusy && view.canConfirm ? "Confirming..." : "Confirm Count"}
                      </button>
                    </>
                  ) : undefined
                }
              />
            )}
          </>
        )
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
          <div className="result-stage">
            {/* THE RESULT. Shown once a game has ended by a win and nothing
                has replaced it -- a reload or a late reconnect finds it via
                refreshTableState. Scores are read live from the roster, so
                the winner's 121 shows even if its UPDATE lands after this. */}
            {finishedGame && (
              <div className="result-banner flex flex-col items-center gap-1 rounded border-2 border-emerald-600 px-6 py-3 text-center">
                <p className="text-lg font-semibold">
                  {finishedGame.winner_id === session.user.id
                    ? "You win!"
                    : `${winner ? displayName(winner) : "A player who has left"} wins!`}
                  {/* How it ended: the winner's last award IS the winning one,
                      since nothing can score after the game ends. */}
                  {winner && (
                    <>
                      {" "}
                      {winner.score}
                      {winner.last_reason &&
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
            <div className="result-stage__actions">
              {!iAmReadyForNewGame && othersReadyForNewGame.length > 0 && (
                <p className="text-sm font-medium">
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
                <p className="text-sm text-zinc-500">
                  Waiting for {othersNotReadyForNewGame.map(nameOf).join(", ")}…
                </p>
              )}
            </div>
            {!canStartGame && (
              <p className="text-sm text-zinc-500">
                Needs exactly {REQUIRED_PLAYERS} players ({members.length} here).
              </p>
            )}
          </div>
        </div>
      )}
    </>
  );

  // The score flash, between the piles, above Sort. Not mounted until the
  // roster has loaded: see ScoreFlash. The same element in both pile rows
  // below, so the winning point's flash carries over onto the final board.
  const scoreFlash = membersLoaded ? <ScoreFlash plates={plates} /> : null;

  // The crib (left) and the starter or deck (right), with the hand's action
  // buttons between them. While cards are out -- and on the final board
  // after a win: the crib and the starter, and no buttons.
  const piles = finalBoard ? (
    <PileRow
      // The crib face-up (fanned) when readable, else a face-down pile.
      crib={{
        faceDownCount: CARDS_AFTER_DISCARD,
        shownCards: finalBoard.board.crib ? sortHand(finalBoard.board.crib) : null,
      }}
      starter={finalBoard.starter_card ? { card: finalBoard.starter_card } : null}
      flash={scoreFlash}
    />
  ) : isActive ? (
    <PileRow
      crib={
        view
          ? // Counting: a face-down pile until the crib's turn; then an
            // empty outline -- its cards are in the dealer's slot -- which
            // stays once the crib is counted.
            { faceDownCount: view.cribPile === "pile" ? 4 : 0, shownCards: null }
          : {
              faceDownCount: discardedBy.length * CARDS_TO_DISCARD,
              shownCards: null,
            }
      }
      starter={{ card: starterCard }}
      flash={scoreFlash}
    >
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
      {/* Only at exactly 2 selected -- there is no valid partial discard, so
          a disabled-but-visible button would just be noise. */}
      {canDiscard && selectedCards.length === CARDS_TO_DISCARD && (
        <button
          onClick={handleDiscard}
          disabled={discardStatus === "sending"}
          className="min-h-10 rounded bg-foreground px-5 text-sm font-medium text-background disabled:opacity-50"
        >
          {discardStatus === "sending" ? "Sending..." : "Send to Crib"}
        </button>
      )}
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
        : Array.from({ length: CARDS_AFTER_DISCARD }, (_, i) => (
            <FaceDownCard key={i} sizing={HAND_CARD} />
          ))}
    </HandRow>
  ) : view ? (
    // Counting: my hand at full size on my turn, small while it waits, gone
    // once counted -- or the crib, face-down then face-up, if I deal.
    <HandRow>
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

  return (
    <TableShell
      header={header}
      opponents={isCutting ? null : <OpponentBand seats={seats} />}
      middle={middle}
      piles={isCutting ? null : piles}
      // The hand row reserves its full height even when empty (no game yet),
      // so the table doesn't jump when cards are dealt -- except during the
      // cut, which needs the space and has no hand to show.
      hand={isCutting ? null : hand}
      scores={<ScoreStrip plates={plates} />}
    />
  );
}
