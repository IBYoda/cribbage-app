"use client";

import { useEffect, useState } from "react";
import { useParams } from "next/navigation";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { supabase } from "@/lib/supabase";

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
};

const UNIQUE_VIOLATION = "23505";

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

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });
  }, []);

  // Fetches the current active game + full roster for a table. Used both for
  // the initial load and to "catch up" after the realtime connection drops
  // and reconnects, since postgres_changes only streams events that happen
  // while connected -- anything missed during a disconnect has to be re-fetched.
  async function refreshTableState(tableId: string) {
    const { data: existingGame } = await supabase
      .from("games")
      .select("id, created_at")
      .eq("table_id", tableId)
      .eq("status", "active")
      .maybeSingle();

    setActiveGame(existingGame ?? null);

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
  }

  // Look up the table, join it (idempotent), then load the current roster.
  // retryKey lets the error screen's "Retry" button re-run this from scratch.
  useEffect(() => {
    if (!session) return;

    let cancelled = false;

    async function setup() {
      setError(null);

      const { data: tableRow, error: tableError } = await supabase
        .from("tables")
        .select("id, code, status")
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
        setError("This table is no longer open.");
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
  }, [session, code, retryKey]);

  async function handleStartNewGame() {
    if (!table || !session) return;

    setGameStatus("creating");
    setGameMessage(null);

    const { data, error: insertError } = await supabase
      .from("games")
      .insert({ table_id: table.id, created_by: session.user.id })
      .select("id, created_at")
      .single();

    if (!insertError) {
      setActiveGame(data);
      setGameStatus("idle");
      return;
    }

    if (insertError.code === UNIQUE_VIOLATION) {
      // Someone else's "New Game" click won the race -- pick up their game
      // instead of showing an error.
      const { data: existing } = await supabase
        .from("games")
        .select("id, created_at")
        .eq("table_id", table.id)
        .eq("status", "active")
        .maybeSingle();
      setActiveGame(existing ?? null);
      setGameStatus("idle");
      return;
    }

    setGameStatus("error");
    setGameMessage(insertError.message);
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
          const newGame = payload.new as { id: string; created_at: string; status: string };
          if (newGame.status === "active") {
            setActiveGame({ id: newGame.id, created_at: newGame.created_at });
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
          const updatedTable = payload.new as { status: string };
          if (updatedTable.status !== "open") {
            setError("This table has been ended by an admin.");
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
  }, [table]);

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

  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-6 p-8">
      <h1 className="text-2xl font-semibold">Table {code}</h1>

      {realtimeStatus === "disconnected" && (
        <p className="text-sm text-amber-600 dark:text-amber-500">Reconnecting...</p>
      )}

      {activeGame ? (
        <p className="rounded border border-green-600 px-4 py-2 text-green-700 dark:text-green-500">
          Game in progress
        </p>
      ) : (
        <div className="flex flex-col items-center gap-2">
          <button
            onClick={handleStartNewGame}
            disabled={gameStatus === "creating"}
            className="rounded bg-foreground px-4 py-2 text-background disabled:opacity-50"
          >
            {gameStatus === "creating" ? "Starting..." : "New Game"}
          </button>
          {gameStatus === "error" && gameMessage && (
            <p className="text-sm text-red-600">{gameMessage}</p>
          )}
        </div>
      )}

      <div className="flex w-full max-w-sm flex-col gap-2">
        <p className="text-sm font-medium text-zinc-600 dark:text-zinc-400">
          Players ({members.length})
        </p>
        <ul className="flex flex-col gap-2">
          {members.map((m) => (
            <li
              key={m.user_id}
              className="rounded border border-zinc-300 px-3 py-2 dark:border-zinc-700"
            >
              {m.nickname || "Unnamed player"}
              {m.user_id === session.user.id && (
                <span className="text-zinc-500"> (you)</span>
              )}
            </li>
          ))}
        </ul>
      </div>

      <Link href="/" className="text-sm underline">
        Back home
      </Link>
    </main>
  );
}
