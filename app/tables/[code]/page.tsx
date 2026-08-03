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

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });
  }, []);

  // Look up the table, join it (idempotent), then load the current roster.
  useEffect(() => {
    if (!session) return;

    let cancelled = false;

    async function setup() {
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

      const { data: existingGame } = await supabase
        .from("games")
        .select("id, created_at")
        .eq("table_id", tableRow.id)
        .eq("status", "active")
        .maybeSingle();

      if (cancelled) return;
      setActiveGame(existingGame ?? null);

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

      const { data: memberRows, error: membersError } = await supabase
        .from("table_members")
        .select("user_id, joined_at")
        .eq("table_id", tableRow.id)
        .order("joined_at", { ascending: true });

      if (cancelled) return;
      if (membersError) {
        setError(membersError.message);
        return;
      }

      const userIds = (memberRows ?? []).map((m) => m.user_id);
      const { data: profileRows } = await supabase
        .from("profiles")
        .select("id, nickname")
        .in("id", userIds.length > 0 ? userIds : [""]);

      if (cancelled) return;

      const nicknameById = new Map((profileRows ?? []).map((p) => [p.id, p.nickname]));

      setMembers(
        (memberRows ?? []).map((m) => ({
          user_id: m.user_id,
          joined_at: m.joined_at,
          nickname: nicknameById.get(m.user_id) ?? null,
        }))
      );
    }

    setup();

    return () => {
      cancelled = true;
    };
  }, [session, code]);

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
      .subscribe();

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
        <Link href="/tables/join" className="underline">
          Try a different code
        </Link>
      </main>
    );
  }

  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-6 p-8">
      <h1 className="text-2xl font-semibold">Table {code}</h1>

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
