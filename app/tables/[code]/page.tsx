"use client";

import { useCallback, useEffect, useState } from "react";
import { useParams } from "next/navigation";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { supabase } from "@/lib/supabase";
import { sortHand } from "@/lib/cards";
import { FaceDownCard, PlayingCard } from "@/components/PlayingCard";

type TableRow = {
  id: string;
  code: string;
  status: string;
};

type Member = {
  user_id: string;
  nickname: string | null;
  joined_at: string;
};

type Game = {
  id: string;
  created_at: string;
  dealer_id: string | null;
};

const REQUIRED_PLAYERS = 2;

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

    setMyHand(data?.cards ?? []);
    setHandSorted(false);
  }, []);

  // Fetches the current active game + full roster for a table. Used both for
  // the initial load and to "catch up" after the realtime connection drops
  // and reconnects, since postgres_changes only streams events that happen
  // while connected -- anything missed during a disconnect has to be re-fetched.
  const refreshTableState = useCallback(async (tableId: string) => {
    const { data: existingGame } = await supabase
      .from("games")
      .select("id, created_at, dealer_id")
      .eq("table_id", tableId)
      .eq("status", "active")
      .maybeSingle();

    setActiveGame(existingGame ?? null);

    if (existingGame) {
      await fetchMyHand(existingGame.id);
    } else {
      setMyHand([]);
    }

    const { data: memberRows, error: membersError } = await supabase
      .from("table_members")
      .select("user_id, joined_at")
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
      }))
    );
  }, [fetchMyHand]);

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
    setGameStatus("idle");
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
          const newRow = payload.new as { user_id: string; joined_at: string };

          setMembers((current) => {
            if (current.some((m) => m.user_id === newRow.user_id)) {
              return current; // already have it (e.g. our own join)
            }
            return [...current, { user_id: newRow.user_id, joined_at: newRow.joined_at, nickname: null }];
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
            dealer_id: string | null;
          };
          if (newGame.status === "active") {
            setActiveGame({
              id: newGame.id,
              created_at: newGame.created_at,
              dealer_id: newGame.dealer_id,
            });
            // The other player dealt -- go fetch our own cards. The hand itself
            // is never broadcast; only the fact that a game now exists is.
            fetchMyHand(newGame.id);
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
          const updatedGame = payload.new as { status: string };
          // An admin force-ending the active game (or it ending some other
          // way in future) should clear it live for anyone still watching.
          if (updatedGame.status !== "active") {
            setActiveGame(null);
            setMyHand([]);
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
  // We can't read an opponent's hand (RLS), and shouldn't -- but hand sizes are
  // public knowledge from the rules, so mirroring our own count is both correct
  // and stays correct after discarding in a later slice.
  const opponentCardCount = myHand.length;
  const displayedHand = handSorted ? sortHand(myHand) : myHand;
  const canStartGame = members.length === REQUIRED_PLAYERS;

  return (
    <main className="flex flex-1 flex-col gap-4 p-4">
      <header className="flex items-baseline justify-between">
        <h1 className="text-lg font-semibold">Table {code}</h1>
        <div className="flex items-center gap-3 text-sm">
          {realtimeStatus === "disconnected" && (
            <span className="text-amber-600 dark:text-amber-500">Reconnecting...</span>
          )}
          <Link href="/" className="underline text-zinc-600 dark:text-zinc-400">
            Leave
          </Link>
        </div>
      </header>

      {/* OPPONENTS -- always the top of the screen */}
      <section className="flex justify-center gap-6">
        {opponents.length === 0 ? (
          <p className="text-sm text-zinc-500">Waiting for another player to join...</p>
        ) : (
          opponents.map((opponent) => (
            <div key={opponent.user_id} className="flex w-full max-w-xs flex-col items-center gap-2">
              <div className="flex w-full gap-1">
                {Array.from({ length: opponentCardCount }).map((_, i) => (
                  <FaceDownCard key={i} />
                ))}
              </div>
              <p className="text-sm font-medium">
                {displayName(opponent)}
                {activeGame?.dealer_id === opponent.user_id && (
                  <span className="text-zinc-500"> · dealer</span>
                )}
              </p>
            </div>
          ))
        )}
      </section>

      {/* MIDDLE -- game controls / status. Grows to push the hand to the bottom. */}
      <section className="flex flex-1 flex-col items-center justify-center gap-2">
        {activeGame ? (
          <p className="rounded border border-green-600 px-4 py-2 text-sm text-green-700 dark:text-green-500">
            Game in progress
          </p>
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
          <button
            onClick={() => setHandSorted(true)}
            disabled={handSorted}
            className="rounded border border-zinc-400 px-6 py-1.5 text-sm font-medium disabled:opacity-40 dark:border-zinc-600"
          >
            Sort
          </button>
        )}

        <div className="flex w-full max-w-md gap-1">
          {displayedHand.map((card) => (
            <PlayingCard key={card} card={card} />
          ))}
        </div>

        <p className="text-sm font-medium">
          {displayName(me)} <span className="text-zinc-500">(you)</span>
          {activeGame?.dealer_id === session.user.id && (
            <span className="text-zinc-500"> · dealer</span>
          )}
        </p>
      </section>
    </main>
  );
}
