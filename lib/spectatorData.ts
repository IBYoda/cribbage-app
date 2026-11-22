import { supabase } from "@/lib/supabase";

// THE SPECTATOR'S CALLS (PRD item 40): the ONLY five RPCs a spectator's
// screen makes (docs/sql/spectators.sql, spectator-chat.sql). Nothing here
// writes a table; the functions decide everything on the server. Used by
// the watch page (app/watch/[code]) and the shared table view
// (components/table/TableView.tsx: get_spectator_reveals while spectating,
// and get_table_spectators for players and spectators alike -- the eye,
// the spectators list and the chat roster).
// scripts/test-phase3.ts scans this file and the watch page for any other
// .rpc(...) name or a table write.

// gameId: the live game, or null -- the table's waiting room or between
// games (the new watch_table, spectators-join-or-watch.sql, lets a
// spectator in with no game; the old one refused instead).
export type WatchTicket = { tableId: string; code: string; gameId: string | null };

// watch_table(code): become (or stay) a spectator. The table, its code and
// the live game (null when none is live) -- or the server's refusal
// message, word for word.
export async function callWatchTable(code: string): Promise<{ ok: WatchTicket } | { refused: string }> {
  const { data, error } = await supabase.rpc("watch_table", { p_code: code });
  if (error) return { refused: error.message };
  const row = (Array.isArray(data) ? data[0] : data) as { table_id?: string; code?: string; game_id?: string | null } | null;
  if (!row?.table_id) return { refused: "Couldn't start watching. Please try again." };
  return { ok: { tableId: row.table_id, code: row.code ?? code, gameId: row.game_id ?? null } };
}

export async function callStopWatching(tableId: string): Promise<void> {
  await supabase.rpc("stop_watching", { p_table_id: tableId });
}

export type HeartbeatStatus = "ok" | "removed" | "table_ended" | "game_ended" | "not_watching";

// spectator_heartbeat(table): null when the call itself failed (the network,
// not an answer) -- the next poll tries again.
export async function callSpectatorHeartbeat(tableId: string): Promise<HeartbeatStatus | null> {
  const { data, error } = await supabase.rpc("spectator_heartbeat", { p_table_id: tableId });
  if (error) return null;
  const known: HeartbeatStatus[] = ["ok", "removed", "table_ended", "game_ended", "not_watching"];
  return known.includes(data as HeartbeatStatus) ? (data as HeartbeatStatus) : null;
}

// WHO IS WATCHING (get_table_spectators, docs/sql/spectator-chat.sql): the
// table's CURRENT spectators (not removed, seen in the last 90 s, judged on
// the server), oldest first, with their names and avatars from profiles.
// The server answers only a player seated there or a current spectator of
// it (anyone else: no rows). null when a read failed: the caller keeps what
// it had (a failed poll never empties the list).
export type TableSpectator = { userId: string; joinedAt: string; nickname: string | null; avatarUrl: string | null };

export async function readTableSpectators(tableId: string): Promise<TableSpectator[] | null> {
  const { data, error } = await supabase.rpc("get_table_spectators", { p_table_id: tableId });
  if (error || !Array.isArray(data)) return null;
  const rows = (data as { user_id?: unknown; joined_at?: unknown }[]).filter(
    (r): r is { user_id: string; joined_at: string } => typeof r.user_id === "string" && typeof r.joined_at === "string"
  );
  if (rows.length === 0) return [];
  const { data: profiles, error: profilesError } = await supabase
    .from("profiles")
    .select("id, nickname, avatar_url")
    .in(
      "id",
      rows.map((r) => r.user_id)
    );
  // Names are display only: without them the rows still count (the eye and
  // the chat roster), shown as "A spectator".
  const byId = new Map((profilesError ? [] : (profiles ?? [])).map((p) => [p.id as string, p]));
  return rows.map((r) => ({
    userId: r.user_id,
    joinedAt: r.joined_at,
    nickname: (byId.get(r.user_id)?.nickname as string | null | undefined) ?? null,
    avatarUrl: (byId.get(r.user_id)?.avatar_url as string | null | undefined) ?? null,
  }));
}

export type SpectatorReveals = { hands: Record<string, string[]>; crib: string[] | null };

// get_spectator_reveals(game): the hands from the start of counting and the
// crib from its step -- the only hidden cards a spectator ever receives.
// null when there is nothing to show (or the call failed).
export async function readSpectatorReveals(gameId: string): Promise<SpectatorReveals | null> {
  // Only ever a real game: nothing to read in the waiting room.
  if (!gameId) return null;
  const { data, error } = await supabase.rpc("get_spectator_reveals", { p_game_id: gameId });
  if (error || !data || typeof data !== "object") return null;
  const d = data as { hands?: unknown; crib?: unknown };
  const hands: Record<string, string[]> = {};
  if (d.hands && typeof d.hands === "object") {
    for (const [id, cards] of Object.entries(d.hands as Record<string, unknown>)) {
      if (Array.isArray(cards)) hands[id] = cards.filter((c): c is string => typeof c === "string");
    }
  }
  const crib = Array.isArray(d.crib) ? d.crib.filter((c): c is string => typeof c === "string") : null;
  return { hands, crib };
}
