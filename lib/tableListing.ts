// TABLE LISTS: the pure rules behind the admin page's table rows
// (app/admin/page.tsx) and the home page's Open Tables (lib/openTables.ts).
// Tested by scripts/test-phase3.ts.

// The name shown for a player with no nickname, as Open Tables shows it.
export const NO_NAME = "A player";

// AN ADMIN ROW'S LABEL: how full the table is, then its mode -- Teams or
// Solo for a 4-player table (team_mode), Self-Scoring for a Muggins table.
// e.g. "1/4 seated · Solo · Self-Scoring", "2/2 seated".
export function adminTableLabel(input: {
  seated: number;
  maxPlayers: number;
  teamMode: string | null;
  isMuggins: boolean;
}): string {
  const parts = [`${input.seated}/${input.maxPlayers} seated`];
  if (input.maxPlayers === 4) parts.push(input.teamMode === "solo" ? "Solo" : "Teams");
  if (input.isMuggins) parts.push("Self-Scoring");
  return parts.join(" · ");
}

// WHO IS SEATED, in seat order: each player's nickname (computer players
// have one too), or NO_NAME -- never an id. A seat not yet numbered sorts
// last.
export function seatedNames(members: { seat: number | null; nickname: string | null | undefined }[]): string[] {
  return [...members]
    .sort((a, b) => (a.seat ?? 99) - (b.seat ?? 99))
    .map((m) => m.nickname?.trim() || NO_NAME);
}

// OPEN TABLES' AGE FILTER: a public table still waiting for players (no
// game being cut for or played) that was created more than this long ago
// is most likely abandoned -- its host closed the tab without leaving -- so
// the list stops showing it. Display only: the table stays open (until the
// 12-hour timeout) and anyone with its code can still join.
export const STALE_WAITING_TABLE_MS = 2 * 60 * 60 * 1000;

export function isStaleWaitingTable(table: { createdAt: string; gameLive: boolean }, now: number): boolean {
  if (table.gameLive) return false;
  const created = Date.parse(table.createdAt);
  return Number.isFinite(created) && now - created > STALE_WAITING_TABLE_MS;
}
