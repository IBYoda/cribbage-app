"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { supabase } from "@/lib/supabase";

type TableRow = {
  id: string;
  code: string;
  created_at: string;
  memberCount: number;
  activeGame: { id: string; created_at: string } | null;
};

export default function AdminPage() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [isAdmin, setIsAdmin] = useState<boolean | null>(null);
  const [tables, setTables] = useState<TableRow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [actionInFlight, setActionInFlight] = useState<string | null>(null);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });
  }, []);

  useEffect(() => {
    if (!session) return;

    let cancelled = false;

    async function loadAdminData() {
      const { data: adminRow } = await supabase
        .from("admin_users")
        .select("user_id")
        .eq("user_id", session!.user.id)
        .maybeSingle();

      if (cancelled) return;

      if (!adminRow) {
        setIsAdmin(false);
        return;
      }

      setIsAdmin(true);

      const { data: openTables, error: tablesError } = await supabase
        .from("tables")
        .select("id, code, created_at")
        .eq("status", "open")
        .order("created_at", { ascending: false });

      if (cancelled) return;
      if (tablesError) {
        setError(tablesError.message);
        return;
      }

      const tableIds = (openTables ?? []).map((t) => t.id);

      const [{ data: activeGames }, { data: memberRows }] = await Promise.all([
        supabase
          .from("games")
          .select("id, table_id, created_at")
          .eq("status", "active")
          .in("table_id", tableIds.length > 0 ? tableIds : [""]),
        supabase
          .from("table_members")
          .select("table_id")
          .in("table_id", tableIds.length > 0 ? tableIds : [""]),
      ]);

      if (cancelled) return;

      const gameByTableId = new Map(
        (activeGames ?? []).map((g) => [g.table_id, { id: g.id, created_at: g.created_at }])
      );

      const memberCountByTableId = new Map<string, number>();
      for (const row of memberRows ?? []) {
        memberCountByTableId.set(row.table_id, (memberCountByTableId.get(row.table_id) ?? 0) + 1);
      }

      setTables(
        (openTables ?? []).map((t) => ({
          id: t.id,
          code: t.code,
          created_at: t.created_at,
          memberCount: memberCountByTableId.get(t.id) ?? 0,
          activeGame: gameByTableId.get(t.id) ?? null,
        }))
      );
    }

    loadAdminData();

    return () => {
      cancelled = true;
    };
  }, [session]);

  async function handleForceEndGame(tableId: string, gameId: string) {
    setActionInFlight(gameId);

    const { error: updateError } = await supabase
      .from("games")
      .update({ status: "ended", ended_reason: "admin" })
      .eq("id", gameId);

    setActionInFlight(null);

    if (updateError) {
      setError(updateError.message);
      return;
    }

    setTables((current) =>
      current.map((t) => (t.id === tableId ? { ...t, activeGame: null } : t))
    );
  }

  async function handleForceEndTable(tableId: string) {
    setActionInFlight(tableId);

    // End any active game at this table too, so nothing is left "active"
    // pointing at a table that's no longer open.
    await supabase
      .from("games")
      .update({ status: "ended", ended_reason: "admin" })
      .eq("table_id", tableId)
      .eq("status", "active");

    const { error: updateError } = await supabase
      .from("tables")
      .update({ status: "ended", ended_reason: "admin" })
      .eq("id", tableId);

    setActionInFlight(null);

    if (updateError) {
      setError(updateError.message);
      return;
    }

    setTables((current) => current.filter((t) => t.id !== tableId));
  }

  if (loading || (session && isAdmin === null)) {
    return (
      <main className="flex flex-1 items-center justify-center">
        <p>Loading...</p>
      </main>
    );
  }

  if (!session) {
    return (
      <main className="flex flex-1 flex-col items-center justify-center gap-4 p-8">
        <p>You need to be logged in to view this page.</p>
        <Link href="/login" className="underline">
          Log in
        </Link>
      </main>
    );
  }

  if (!isAdmin) {
    return (
      <main className="flex flex-1 flex-col items-center justify-center gap-4 p-8">
        <p>You are not authorized to view this page.</p>
        <Link href="/" className="underline">
          Back home
        </Link>
      </main>
    );
  }

  return (
    <main className="flex flex-1 flex-col items-center gap-6 p-8">
      <h1 className="text-2xl font-semibold">Admin: Active Tables</h1>

      {error && <p className="text-sm text-red-600">{error}</p>}

      {tables.length === 0 ? (
        <p className="text-sm text-zinc-600 dark:text-zinc-400">No open tables right now.</p>
      ) : (
        <ul className="flex w-full max-w-lg flex-col gap-3">
          {tables.map((t) => (
            <li
              key={t.id}
              className="flex flex-col gap-2 rounded border border-zinc-300 p-4 dark:border-zinc-700"
            >
              <div className="flex items-center justify-between">
                <span className="text-xl font-bold tracking-widest">{t.code}</span>
                <button
                  onClick={() => handleForceEndTable(t.id)}
                  disabled={actionInFlight === t.id}
                  className="rounded border border-red-600 px-3 py-1 text-sm text-red-600 disabled:opacity-50"
                >
                  {actionInFlight === t.id ? "Ending..." : "Force-End Table"}
                </button>
              </div>
              <p className="text-sm text-zinc-600 dark:text-zinc-400">
                {t.memberCount} member{t.memberCount === 1 ? "" : "s"} · created{" "}
                {new Date(t.created_at).toLocaleString()}
              </p>
              {t.activeGame && (
                <div className="flex items-center justify-between rounded bg-zinc-100 px-3 py-2 dark:bg-zinc-800">
                  <span className="text-sm text-green-700 dark:text-green-500">
                    Game in progress since {new Date(t.activeGame.created_at).toLocaleTimeString()}
                  </span>
                  <button
                    onClick={() => handleForceEndGame(t.id, t.activeGame!.id)}
                    disabled={actionInFlight === t.activeGame.id}
                    className="rounded border border-red-600 px-3 py-1 text-sm text-red-600 disabled:opacity-50"
                  >
                    {actionInFlight === t.activeGame.id ? "Ending..." : "Force-End Game"}
                  </button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}

      <Link href="/" className="text-sm underline">
        Back home
      </Link>
    </main>
  );
}
