import { supabase } from "@/lib/supabase";
import { idBatches, tierForCount, type GodWinsTier } from "@/lib/wings";

// HOW MANY TIMES EACH PLAYER HAS BEATEN GOD, from get_god_wins()
// (docs/sql/god-wins.sql), for their wings. Read with the member and profile
// reads, so wings arrive with the avatar. Cached for the session; no realtime:
// a God table has one human, so nobody can earn a tier in front of another
// player, and they see it at their next table.
//
// Never throws, and never breaks a screen. Until the SQL has been run (or if a
// read fails) the answer just has no entry, which means no wings. A failed read
// holds off for a while: the browser logs every failed request, and the safety
// poll would otherwise repeat it.

// tier: what the count earned. The creator's wings aren't here: they need no
// read (displayTier, lib/wings.ts).
export type GodWins = { count: number; tier: GodWinsTier | null };

const RETRY_AFTER_MS = 5 * 60 * 1000;

const cache = new Map<string, number>();
let heldUntil = 0;

// fresh: past the cache, for the signed-in player's own win.
export async function getGodWins(
  ids: readonly string[],
  options: { fresh?: boolean } = {}
): Promise<Map<string, GodWins>> {
  const wanted = [...new Set(ids)];
  const missing = options.fresh ? wanted : wanted.filter((id) => !cache.has(id));
  if (missing.length > 0 && (options.fresh || Date.now() >= heldUntil)) {
    await Promise.all(idBatches(missing).map(readBatch));
  }
  const found = new Map<string, GodWins>();
  for (const id of wanted) {
    const count = cache.get(id);
    if (count !== undefined) found.set(id, { count, tier: tierForCount(count) });
  }
  return found;
}

async function readBatch(ids: string[]) {
  try {
    const { data, error } = await supabase.rpc("get_god_wins", { p_user_ids: ids });
    if (error) {
      heldUntil = Date.now() + RETRY_AFTER_MS;
      return;
    }
    // A player with no wins has no row.
    for (const id of ids) cache.set(id, 0);
    for (const row of (data ?? []) as { user_id: string; god_wins: number }[]) cache.set(row.user_id, row.god_wins);
  } catch {
    heldUntil = Date.now() + RETRY_AFTER_MS;
  }
}
