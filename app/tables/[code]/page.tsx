"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { supabase } from "@/lib/supabase";
import { cardPlayValue, sortHand } from "@/lib/cards";
import { FaceDownCard, PlayingCard } from "@/components/PlayingCard";
import { CutForDealView } from "@/components/CutForDealView";
import { PlayerScore } from "@/components/PlayerScore";
import { PlayArea, type PlayEvent } from "@/components/PlayArea";

type TableRow = {
  id: string;
  code: string;
  status: string;
};

type Member = {
  user_id: string;
  nickname: string | null;
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
};

// Must stay a single string LITERAL, not a concatenation: supabase-js infers
// the returned row shape from this exact literal type, and "a" + "b" widens to
// plain `string`, which silently collapses the result type to an error type.
const GAME_COLUMNS =
  "id, created_at, status, players, dealer_id, discarded_by, deal_cut, deal_cut_ack_by, starter_card, phase, current_player, play_count, play_segment";

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

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });
  }, []);

  // Fetches this player's own hand. RLS on game_hands means this can only ever
  // return our own row -- asking for someone else's returns zero rows, so there
  // is no filtering to do here on the client.
  const fetchMyHand = useCallback(async (gameId: string) => {
    const { data } = await supabase
      .from("game_hands")
      .select("cards")
      .eq("game_id", gameId)
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

  // Fetches the current active game + full roster for a table. Used both for
  // the initial load and to "catch up" after the realtime connection drops
  // and reconnects, since postgres_changes only streams events that happen
  // while connected -- anything missed during a disconnect has to be re-fetched.
  const refreshTableState = useCallback(async (tableId: string) => {
    // Must find cutting games too, or a game mid-cut reads as "no game" and
    // the client would offer "New Game" for a table that already has one.
    const { data: existingGame } = await supabase
      .from("games")
      .select(GAME_COLUMNS)
      .eq("table_id", tableId)
      .in("status", LIVE_GAME_STATUSES)
      .maybeSingle();

    setActiveGame(existingGame ?? null);
    lastGameStatusRef.current = existingGame?.status ?? null;

    // No hand exists during 'cutting' -- that is the entire point of the phase.
    if (existingGame && existingGame.status === "active") {
      await fetchMyHand(existingGame.id);
      await fetchPlays(existingGame.id);
    } else {
      setMyHand([]);
      setPlays([]);
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
      .select("id, nickname")
      .in("id", userIds.length > 0 ? userIds : [""]);

    const nicknameById = new Map((profileRows ?? []).map((p) => [p.id, p.nickname]));

    setMembers(
      (memberRows ?? []).map((m) => ({
        user_id: m.user_id,
        joined_at: m.joined_at,
        nickname: nicknameById.get(m.user_id) ?? null,
        score: m.score ?? 0,
        last_points: m.last_points,
        last_reason: m.last_reason,
        last_awarded_at: m.last_awarded_at,
      }))
    );
  }, [fetchMyHand, fetchPlays]);

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

    const { error: rpcError } = await supabase.rpc("start_game_with_deal", {
      p_table_id: table.id,
    });

    if (rpcError) {
      // The function's own guards (not a member, table closed, wrong player
      // count) surface here as readable messages.
      setGameStatus("error");
      setGameMessage(rpcError.message);
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
            .select("nickname")
            .eq("id", newRow.user_id)
            .maybeSingle();

          if (profile) {
            setMembers((current) =>
              current.map((m) =>
                m.user_id === newRow.user_id ? { ...m, nickname: profile.nickname } : m
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
          const updated = payload.new as { id: string; nickname: string };

          setMembers((current) =>
            current.map((m) =>
              m.user_id === updated.id ? { ...m, nickname: updated.nickname } : m
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
          };
          // A new game now arrives as EITHER 'cutting' (first game at the
          // table -- no cards yet) or 'active' (deal alternated, dealt at once).
          if (LIVE_GAME_STATUSES.includes(newGame.status)) {
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
            });
            lastGameStatusRef.current = newGame.status;
            setHandSorted(false); // genuinely new hand -- show it as dealt
            setGameEndedNotice(null); // stale once a fresh game is under way
            setPlays([]); // a fresh game has no play history
            // Only fetch a hand if one can exist. During 'cutting' there are no
            // cards at all, which is the whole point of the phase.
            if (newGame.status === "active") fetchMyHand(newGame.id);
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
          };
          const previousStatus = lastGameStatusRef.current;
          lastGameStatusRef.current = updatedGame.status;

          // Ended, by an admin force-end, a departing player, or the timeout.
          // 'cutting' is now a LIVE status, so this check can no longer be
          // "not active" -- that would treat every cut as an ended game.
          if (!LIVE_GAME_STATUSES.includes(updatedGame.status)) {
            setActiveGame(null);
            setMyHand([]);
            setSelectedCards([]);
            lastGameStatusRef.current = null;
            // Deliberately doesn't name the leaver: the roster DELETE arrives
            // as a separate event with no ordering guarantee, so building the
            // name in here would race. The roster visibly updating alongside
            // this already shows *who* left.
            if (updatedGame.ended_reason === "player_left") {
              setGameEndedNotice("A player left the table — the game was ended.");
            }
            return;
          }
          // Otherwise the game is live and something moved. This one broadcast
          // now carries every phase:
          //   - a cut card being drawn (deal_cut grows)
          //   - a redraw/deal acknowledgement (deal_cut_ack_by)
          //   - a discard, and then the starter being cut (public by design)
          //   - a card played: current_player, play_count and play_segment,
          //     which is what moves the turn indicator on BOTH screens
          // None of it ever carries a hand or the crib.
          //
          // The cutting -> active transition rides here too: the deal happens
          // inside the same statement that flips the status, so both land in
          // one event.
          setActiveGame((current) =>
            current
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
                }
              : current
          );

          // The exact moment cards come into existence: the OTHER player's
          // acknowledgement dealt them, and this broadcast is how we find out.
          // Gated on the transition rather than firing for every 'active'
          // update, so an opponent's discard doesn't refetch our hand and wipe
          // a selection we're part-way through making.
          if (previousStatus === "cutting" && updatedGame.status === "active") {
            setHandSorted(false); // freshly dealt -- show it as dealt
            fetchMyHand(updatedGame.id);
          }
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
  }, [table, refreshTableState, fetchMyHand]);

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
  const isPlaying = Boolean(activeGame) && phase === "play";
  const isCounting = Boolean(activeGame) && phase === "counting";

  // game_hands.cards is the immutable four-card hand; what you still HOLD is
  // that minus what you've already played.
  const playedByMe = new Set(
    plays.filter((p) => p.kind === "play" && p.user_id === session.user.id).map((p) => p.card!)
  );
  // During counting you want the whole hand back -- those four cards are what
  // gets scored. Only during play is it reduced to what's left to play.
  const handForDisplay = isPlaying ? myHand.filter((c) => !playedByMe.has(c)) : myHand;
  const displayedHand = handSorted ? sortHand(handForDisplay) : handForDisplay;

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
  const dealer = members.find((m) => m.user_id === activeGame?.dealer_id);
  const waitingOn = opponents.filter((o) => !discardedBy.includes(o.user_id));
  const canDiscard = Boolean(activeGame) && !iHaveDiscarded && myHand.length === CARDS_DEALT;

  // The cut phase. Only the table's FIRST game cuts -- later games alternate
  // the deal, are created straight into 'active', and never enter this.
  const isCutting = activeGame?.status === "cutting";

  // Derived from discarded_by rather than mirroring our own hand length: once
  // you discard and your opponent hasn't, mirroring would show 4 cards for a
  // player still holding 6. Hand sizes are public knowledge from the rules, so
  // this reveals nothing that isn't already known.
  function opponentCardCount(opponentId: string) {
    if (!activeGame) return 0;
    if (isPlaying) {
      // Derived from the public play log -- how many of their four they've
      // laid down. Reveals nothing: which cards they've played is already
      // public, and hand sizes are visible in a real game anyway.
      const played = plays.filter((p) => p.kind === "play" && p.user_id === opponentId).length;
      return Math.max(CARDS_AFTER_DISCARD - played, 0);
    }
    if (isCounting) return CARDS_AFTER_DISCARD;
    return discardedBy.includes(opponentId) ? CARDS_AFTER_DISCARD : CARDS_DEALT;
  }

  return (
    <main className="flex flex-1 flex-col gap-4 p-4">
      <header className="flex items-baseline justify-between">
        <h1 className="text-lg font-semibold">Table {code}</h1>
        <div className="flex items-center gap-3 text-sm">
          {realtimeStatus === "disconnected" && (
            <span className="text-amber-600 dark:text-amber-500">Reconnecting...</span>
          )}
          {leaveConfirming ? (
            <>
              <button
                onClick={handleLeave}
                disabled={leaveStatus === "leaving"}
                className="rounded bg-red-600 px-3 py-1 text-white disabled:opacity-50"
              >
                {leaveStatus === "leaving" ? "Leaving..." : "End game & leave"}
              </button>
              <button
                onClick={() => setLeaveConfirming(false)}
                className="underline text-zinc-600 dark:text-zinc-400"
              >
                Cancel
              </button>
            </>
          ) : (
            <button
              onClick={() => (activeGame ? setLeaveConfirming(true) : handleLeave())}
              disabled={leaveStatus === "leaving"}
              className="underline text-zinc-600 disabled:opacity-50 dark:text-zinc-400"
            >
              {leaveStatus === "leaving" ? "Leaving..." : "Leave"}
            </button>
          )}
        </div>
      </header>

      {leaveStatus === "error" && leaveMessage && (
        <p className="text-center text-sm text-red-600">{leaveMessage}</p>
      )}

      {gameEndedNotice && (
        <div className="flex items-center justify-center gap-3 rounded border border-amber-500 px-3 py-2 text-sm text-amber-700 dark:text-amber-500">
          <span>{gameEndedNotice}</span>
          <button onClick={() => setGameEndedNotice(null)} className="underline">
            Dismiss
          </button>
        </div>
      )}

      {/* THE CUT. Replaces the table entirely rather than overlaying it: during
          'cutting' there are no hands, no crib and no starter, so there is
          genuinely nothing to render underneath. It has its own seating (you at
          the bottom) and no dismissal -- closing it would strand the player on
          an empty table with no way back into the cut. */}
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
      ) : (
      <>
      {/* OPPONENTS -- always the top of the screen */}
      <section className="flex justify-center gap-6">
        {opponents.length === 0 ? (
          <p className="text-sm text-zinc-500">Waiting for another player to join...</p>
        ) : (
          opponents.map((opponent) => (
            <div key={opponent.user_id} className="flex w-full max-w-xs flex-col items-center gap-2">
              <div className="flex w-full gap-1">
                {Array.from({ length: opponentCardCount(opponent.user_id) }).map((_, i) => (
                  <FaceDownCard key={i} />
                ))}
              </div>
              <p className="flex items-baseline gap-2 text-sm font-medium">
                <span>
                  {displayName(opponent)}
                  {activeGame?.dealer_id === opponent.user_id && (
                    <span className="text-zinc-500"> · dealer</span>
                  )}
                </span>
                <PlayerScore
                  score={opponent.score}
                  lastPoints={opponent.last_points}
                  lastReason={opponent.last_reason}
                  lastAwardedAt={opponent.last_awarded_at}
                />
              </p>
            </div>
          ))
        )}
      </section>

      {/* MIDDLE -- game controls / status. Grows to push the hand to the bottom. */}
      <section className="flex flex-1 flex-col items-center justify-center gap-2">
        {activeGame ? (
          <>
            {cribComplete ? (
              <>
                {/* items-end so the two labels sit on a shared baseline even
                    though the starter is rendered larger than a crib card.
                    Both shrink once play starts, to leave room for the run. */}
                <div className="flex items-end justify-center gap-6">
                  <div className="flex flex-col items-center gap-1">
                    {/* Face-down for EVERYONE, dealer included -- game_cribs has no
                        read policy at all until the counting-phase reveal slice. */}
                    <div className={`flex gap-1 ${isPlaying || isCounting ? "w-20" : "w-32"}`}>
                      {Array.from({ length: REQUIRED_PLAYERS * CARDS_TO_DISCARD }).map((_, i) => (
                        <FaceDownCard key={i} />
                      ))}
                    </div>
                    <p className="text-xs font-medium">
                      {iAmDealer ? "Your crib" : `${displayName(dealer)}'s crib`}
                    </p>
                  </div>

                  {/* The one card everybody is meant to be looking at. Absent
                      for the brief moment between the crib completing and the
                      starter UPDATE arriving. */}
                  {activeGame.starter_card && (
                    <div className="flex flex-col items-center gap-1">
                      <div className={`flex gap-1 ${isPlaying || isCounting ? "w-12" : "w-16"}`}>
                        <PlayingCard card={activeGame.starter_card} />
                      </div>
                      <p className="text-xs font-medium">Starter</p>
                    </div>
                  )}
                </div>

                {isPlaying && (
                  <PlayArea
                    plays={plays}
                    playCount={playCount}
                    playSegment={activeGame.play_segment}
                    currentPlayer={activeGame.current_player}
                    myUserId={session.user.id}
                    nameFor={(userId) => displayName(members.find((m) => m.user_id === userId))}
                  />
                )}

                {isCounting && (
                  <p className="rounded border border-zinc-400 px-4 py-2 text-center text-sm dark:border-zinc-600">
                    All eight cards played — pegging is over.
                    <br />
                    <span className="text-zinc-500">Counting is the next slice.</span>
                  </p>
                )}
              </>
            ) : iHaveDiscarded ? (
              <p className="text-sm text-zinc-500">
                Waiting for {waitingOn.map(displayName).join(", ")} to discard...
              </p>
            ) : (
              <p className="text-base font-medium">
                Pick {CARDS_TO_DISCARD} cards for {iAmDealer ? "your" : "their"} crib
              </p>
            )}
          </>
        ) : (
          <>
            <button
              onClick={handleStartNewGame}
              disabled={gameStatus === "creating" || !canStartGame}
              className="rounded bg-foreground px-6 py-3 text-lg text-background disabled:opacity-50"
            >
              {gameStatus === "creating" ? "Dealing..." : "New Game"}
            </button>
            {!canStartGame && (
              <p className="text-sm text-zinc-500">
                Needs exactly {REQUIRED_PLAYERS} players ({members.length} here).
              </p>
            )}
          </>
        )}
        {gameStatus === "error" && gameMessage && (
          <p className="text-center text-sm text-red-600">{gameMessage}</p>
        )}
      </section>

      {/* YOU -- always the bottom of the screen */}
      <section className="flex flex-col items-center gap-2">
        {myHand.length > 0 && (
          <div className="flex items-center gap-2">
            <button
              onClick={() => setHandSorted(true)}
              disabled={handSorted}
              className="rounded border border-zinc-400 px-6 py-1.5 text-sm font-medium disabled:opacity-40 dark:border-zinc-600"
            >
              Sort
            </button>
            {/* Only appears at exactly 2 selected -- there is no valid partial
                discard, so a disabled-but-visible button would just be noise. */}
            {canDiscard && selectedCards.length === CARDS_TO_DISCARD && (
              <button
                onClick={handleDiscard}
                disabled={discardStatus === "sending"}
                className="rounded bg-foreground px-6 py-1.5 text-sm font-medium text-background disabled:opacity-50"
              >
                {discardStatus === "sending" ? "Sending..." : "Send to Crib"}
              </button>
            )}
          </div>
        )}

        {discardStatus === "error" && discardMessage && (
          <p className="text-center text-sm text-red-600">{discardMessage}</p>
        )}

        {playStatus === "error" && playMessage && (
          <p className="text-center text-sm text-red-600">{playMessage}</p>
        )}

        {/* During play, a prompt that names the constraint rather than leaving
            the player to work out why cards are greyed. */}
        {isPlaying && isMyTurn && (
          <p className="text-sm text-zinc-500">
            Tap a card to play — up to {31 - playCount} more
          </p>
        )}

        {/* max-w scales with hand size so a shrinking hand doesn't stretch to
            fill the width six cards needed. */}
        <div
          className={`flex w-full gap-1 ${
            displayedHand.length > CARDS_AFTER_DISCARD ? "max-w-md" : "max-w-xs"
          }`}
        >
          {displayedHand.map((card) => (
            <PlayingCard
              key={card}
              card={card}
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
        </div>

        <p className="flex items-baseline gap-2 text-sm font-medium">
          <span>
            {displayName(me)} <span className="text-zinc-500">(you)</span>
            {activeGame?.dealer_id === session.user.id && (
              <span className="text-zinc-500"> · dealer</span>
            )}
          </span>
          {me && (
            <PlayerScore
              score={me.score}
              lastPoints={me.last_points}
              lastReason={me.last_reason}
              lastAwardedAt={me.last_awarded_at}
            />
          )}
        </p>
      </section>
      </>
      )}
    </main>
  );
}
