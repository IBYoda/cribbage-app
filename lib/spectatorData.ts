import { supabase } from "@/lib/supabase";

// THE SPECTATOR'S CALLS (PRD item 40): the ONLY four RPCs a spectator's
// screen makes (docs/sql/spectators.sql). Nothing here writes a table; the
// functions decide everything on the server. Used only by the watch page
// (app/watch/[code]) and the shared table view's spectating mode
// (components/table/TableView.tsx, for get_spectator_reveals).
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
