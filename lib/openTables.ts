import { supabase } from "@/lib/supabase";
import { PHASE3_TABLES } from "@/lib/featureFlags";

// OPEN TABLES -- the reads behind the home page's "Open Tables" list
// (components/brand/HomeView.tsx). Two independent reads, each returning
// null when it fails, so one can fail without hiding the other. Read-only,
// through the existing policies (any signed-in user can read tables,
// table_members, games and profiles).

const LIVE_GAME_STATUSES = ["cutting", "active"];

// An open table the viewer is seated at (any visibility).
export type MyTable = {
  code: string;
  isMuggins: boolean; // a Muggins table: listed with the "Muggins · no scoring" tag
  others: string[]; // the other players' names
  gameLive: boolean; // a game is being cut for or played
  capacity: number; // tables.max_players: 2, 3 or 4
};

// A public table the viewer could join.
export type JoinableTable = {
  code: string;
  isMuggins: boolean; // likewise
  hostName: string; // the first seated player
  hostAvatar: string | null;
  createdAt: string;
  seated: number; // how many are seated now
  capacity: number; // tables.max_players: 2, 3 or 4
};

// The open tables the viewer is seated at, newest seat first, with who else
// is there and whether a game is live. If the names or games read fails,
// the rows still come back -- just without those labels.
export async function loadMyTables(userId: string): Promise<MyTable[] | null> {
  const { data: seats, error } = await supabase
    .from("table_members")
    .select("table_id, joined_at, tables!inner(id, code, status, is_muggins, max_players)")
    .eq("user_id", userId)
    .eq("tables.status", "open")
    .order("joined_at", { ascending: false });
  if (error) return null;

  const open = (seats ?? []).flatMap((s) => {
    type Row = { id: string; code: string; is_muggins: boolean | null; max_players: number | null };
    const t = s.tables as unknown as Row | Row[] | null;
    const table = Array.isArray(t) ? t[0] : t;
    return table
      ? [{ id: table.id, code: table.code, isMuggins: table.is_muggins === true, capacity: table.max_players ?? 2 }]
      : [];
  });
  if (open.length === 0) return [];
  const ids = open.map((t) => t.id);

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

  return open.map((t) => ({
    code: t.code,
    isMuggins: t.isMuggins,
    others: (members ?? [])
      .filter((m) => m.table_id === t.id)
      .map((m) => nameOf.get(m.user_id) ?? "A player"),
    gameLive: live.has(t.id),
    capacity: t.capacity,
  }));
}

// The public tables the viewer could join, newest first. The rule is
// SEAT-based: a table is listed when it is open, public, the viewer is not
// seated there, and at least 1 but fewer than max_players are seated -- at
// least one, so a table everyone has left (open until the 12-hour timeout)
// or a new one whose creator isn't seated yet is never listed; fewer than
// its size, so it has a free seat. With the Phase 3 flag off
// (lib/featureFlags.ts) only 2-player tables are listed at all, so a 3- or
// 4-player table made on a flagged build never reaches an unflagged one.
// Who created it doesn't matter: a table the viewer created but left is
// listed for them like for anyone else, and the tables they ARE seated at
// show only as "Your table" (loadMyTables), never twice. The row shows the
// first seated player (the earliest seat) and, for 3 and 4 players, how
// full it is. A failed profiles read only loses the names ("A player").
export async function loadJoinableTables(userId: string): Promise<JoinableTable[] | null> {
  const { data, error } = await supabase
    .from("tables")
    .select("code, status, is_public, is_muggins, max_players, created_at, table_members(user_id, seat)")
    .eq("status", "open")
    .eq("is_public", true)
    .order("created_at", { ascending: false });
  if (error || !data) return null;

  const joinable = data.flatMap((t) => {
    const capacity = t.max_players ?? 2;
    const seated = [...(t.table_members ?? [])]
      .sort((a, b) => (a.seat ?? 0) - (b.seat ?? 0))
      .map((m) => m.user_id);
    const listed =
      t.status === "open" &&
      t.is_public === true &&
      (PHASE3_TABLES || capacity === 2) &&
      !seated.includes(userId) &&
      seated.length >= 1 &&
      seated.length < capacity;
    if (!listed) return [];
    return [
      {
        code: t.code,
        isMuggins: t.is_muggins === true,
        createdAt: t.created_at,
        host: seated[0],
        seated: seated.length,
        capacity,
      },
    ];
  });
  if (joinable.length === 0) return [];

  const hostIds = [...new Set(joinable.map((t) => t.host))];
  const { data: profiles } = await supabase
    .from("profiles")
    .select("id, nickname, avatar_url")
    .in("id", hostIds);
  const byId = new Map((profiles ?? []).map((p) => [p.id, p]));

  return joinable.map((t) => {
    const host = byId.get(t.host);
    return {
      code: t.code,
      isMuggins: t.isMuggins,
      hostName: host?.nickname?.trim() || "A player",
      hostAvatar: host?.avatar_url ?? null,
      createdAt: t.createdAt,
      seated: t.seated,
      capacity: t.capacity,
    };
  });
}
