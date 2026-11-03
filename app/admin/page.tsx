"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { supabase } from "@/lib/supabase";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { AdminTableRow, type AdminTable } from "@/components/brand/AdminTableRow";
import { adminTableLabel, seatedNames } from "@/lib/tableListing";

// A game is "live" while it is either cutting for deal or being played. Both
// occupy the table's one-live-game slot, so both must be listed and killable.
const LIVE_GAME_STATUSES = ["cutting", "active"];

export default function AdminPage() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [isAdmin, setIsAdmin] = useState<boolean | null>(null);
  const [tables, setTables] = useState<AdminTable[]>([]);
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
        .select("id, code, created_at, computer_level, max_players, team_mode, is_muggins")
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
          // Must include 'cutting': a game still cutting for deal is live and
          // holds the table's one-live-game slot, so it has to be visible here
          // and force-endable. Filtering to 'active' alone made a game
          // abandoned mid-cut invisible to admin and impossible to kill.
          .select("id, table_id, created_at, status")
          .in("status", LIVE_GAME_STATUSES)
          .in("table_id", tableIds.length > 0 ? tableIds : [""]),
        supabase
          .from("table_members")
          .select("table_id, user_id, seat")
          .in("table_id", tableIds.length > 0 ? tableIds : [""]),
      ]);

      if (cancelled) return;

      // The seated players' names (any signed-in user can read profiles). If
      // this read fails, the rows still come back, each name as "A player".
      const memberIds = [...new Set((memberRows ?? []).map((m) => m.user_id))];
      const { data: profiles } = memberIds.length
        ? await supabase.from("profiles").select("id, nickname").in("id", memberIds)
        : { data: [] as { id: string; nickname: string | null }[] };

      if (cancelled) return;

      const nicknameOf = new Map((profiles ?? []).map((p) => [p.id, p.nickname]));

      const gameByTableId = new Map(
        (activeGames ?? []).map((g) => [
          g.table_id,
          { id: g.id, created_at: g.created_at, status: g.status },
        ])
      );

      setTables(
        (openTables ?? []).map((t) => {
          const seated = (memberRows ?? []).filter((m) => m.table_id === t.id);
          return {
            id: t.id,
            code: t.code,
            created_at: t.created_at,
            computerLevel: t.computer_level ?? null,
            label: adminTableLabel({
              seated: seated.length,
              maxPlayers: t.max_players ?? 2,
              teamMode: t.team_mode ?? null,
              isMuggins: t.is_muggins === true,
            }),
            names: seatedNames(seated.map((m) => ({ seat: m.seat, nickname: nicknameOf.get(m.user_id) }))),
            activeGame: gameByTableId.get(t.id) ?? null,
          };
        })
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

    // End any LIVE game at this table too, so nothing is left running against
    // a table that's no longer open. Must include 'cutting' -- filtering to
    // 'active' alone would end the table but leave a cutting game orphaned.
    await supabase
      .from("games")
      .update({ status: "ended", ended_reason: "admin" })
      .eq("table_id", tableId)
      .in("status", LIVE_GAME_STATUSES);

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
      <CardRoomFrame backHome={false}>
        <p className="text-center">Loading...</p>
      </CardRoomFrame>
    );
  }

  if (!session) {
    return (
      <CardRoomFrame backHome={false}>
        <p>You need to be logged in to view this page.</p>
        <Link href="/login" className="peg-btn peg-btn--brass">
          Log in
        </Link>
      </CardRoomFrame>
    );
  }

  if (!isAdmin) {
    return (
      <CardRoomFrame>
        <p>You are not authorized to view this page.</p>
      </CardRoomFrame>
    );
  }

  return (
    <CardRoomFrame title="Admin: Active Tables">
      {error && <p className="text-sm text-[var(--error-on-felt)]">{error}</p>}

      {tables.length === 0 ? (
        <p className="text-sm">No open tables right now.</p>
      ) : (
        <ul className="flex w-full flex-col gap-3">
          {tables.map((t) => (
            <AdminTableRow
              key={t.id}
              table={t}
              actionInFlight={actionInFlight}
              onForceEndTable={() => handleForceEndTable(t.id)}
              onForceEndGame={(gameId) => handleForceEndGame(t.id, gameId)}
            />
          ))}
        </ul>
      )}
    </CardRoomFrame>
  );
}
