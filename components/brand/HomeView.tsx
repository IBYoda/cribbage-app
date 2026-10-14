"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import { HomeMenu, type YourTable, type YourTablesState } from "@/components/brand/HomeMenu";

const LIVE_GAME_STATUSES = ["cutting", "active"];

// THE SIGNED-IN HOME: reads what the main menu shows, then renders HomeMenu.
// Read-only, through the existing RLS, and each part can fail on its own:
//   * the profile (nickname, avatar) -- falls back to the email's name;
//   * admin_users, the player's own row only -- the Admin link shows only if
//     that read succeeds and finds the row;
//   * "Your tables": the open tables the player is seated at
//     (table_members + tables), with who else is there (table_members +
//     profiles) and whether a game is live (games).
// Nothing here touches the Appearance settings or the game tables' data.
export function HomeView({ session, onLogout }: { session: Session; onLogout: () => void }) {
  const userId = session.user.id;
  const emailName = session.user.email?.split("@")[0] ?? "player";

  const [nickname, setNickname] = useState<string | null>(null);
  const [avatarUrl, setAvatarUrl] = useState<string | null>(null);
  const [isAdmin, setIsAdmin] = useState(false);
  const [tables, setTables] = useState<YourTablesState>({ status: "loading" });

  useEffect(() => {
    let cancelled = false;

    supabase
      .from("profiles")
      .select("nickname, avatar_url")
      .eq("id", userId)
      .maybeSingle()
      .then(({ data }) => {
        if (cancelled || !data) return;
        setNickname(data.nickname?.trim() || null);
        setAvatarUrl(data.avatar_url ?? null);
      });

    supabase
      .from("admin_users")
      .select("user_id")
      .eq("user_id", userId)
      .maybeSingle()
      .then(({ data, error }) => {
        if (!cancelled) setIsAdmin(!error && !!data);
      });

    loadYourTables(userId).then((state) => {
      if (!cancelled) setTables(state);
    });

    return () => {
      cancelled = true;
    };
  }, [userId]);

  return (
    <HomeMenu
      name={nickname ?? emailName}
      avatarUrl={avatarUrl}
      isAdmin={isAdmin}
      tables={tables}
      onLogout={onLogout}
    />
  );
}

async function loadYourTables(userId: string): Promise<YourTablesState> {
  // The open tables this player is seated at, newest seat first.
  const { data: seats, error } = await supabase
    .from("table_members")
    .select("table_id, joined_at, tables!inner(id, code, status)")
    .eq("user_id", userId)
    .eq("tables.status", "open")
    .order("joined_at", { ascending: false });
  if (error) return { status: "error" };

  const open = (seats ?? []).flatMap((s) => {
    const t = s.tables as unknown as { id: string; code: string } | { id: string; code: string }[] | null;
    const table = Array.isArray(t) ? t[0] : t;
    return table ? [{ id: table.id, code: table.code }] : [];
  });
  if (open.length === 0) return { status: "ready", tables: [] };
  const ids = open.map((t) => t.id);

  // Who else is seated, and whether a game is live. If either read fails, the
  // rows still show -- just without those labels.
  const [{ data: members }, { data: games }] = await Promise.all([
    supabase.from("table_members").select("table_id, user_id").in("table_id", ids).neq("user_id", userId),
    supabase.from("games").select("table_id").in("table_id", ids).in("status", LIVE_GAME_STATUSES),
  ]);
  const otherIds = [...new Set((members ?? []).map((m) => m.user_id))];
  const { data: profiles } = otherIds.length
    ? await supabase.from("profiles").select("id, nickname").in("id", otherIds)
    : { data: [] as { id: string; nickname: string | null }[] };
  const nameOf = new Map((profiles ?? []).map((p) => [p.id, p.nickname?.trim() || "A player"]));
  const live = new Set((games ?? []).map((g) => g.table_id));

  const rows: YourTable[] = open.map((t) => ({
    code: t.code,
    others: (members ?? [])
      .filter((m) => m.table_id === t.id)
      .map((m) => nameOf.get(m.user_id) ?? "A player"),
    gameLive: live.has(t.id),
  }));
  return { status: "ready", tables: rows };
}
