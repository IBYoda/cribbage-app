import { COMPUTER_LEVEL_ORDER, LEVEL_INFO, isComputerLevel, type ComputerLevel } from "@/lib/computer/config";

// A PLAYER'S OWN STATS, for the Profile page (PRD item 35, slice S3):
//   * the multiplayer record -- the player's own row of get_leaderboard()
//     (docs/sql/leaderboard-l3-hidden-accounts.sql), the same numbers the
//     leaderboard shows;
//   * the record against each computer -- get_solo_stats()
//     (docs/sql/solo-stats.sql), one row per level the player has FINISHED a
//     game at. Skunks are per opponent only: nothing here adds them up across
//     levels.
//
// The shaping helpers are pure (tested in scripts/test-phase3.ts). The reads
// never throw: a failed read is { ok: false }, and the page then says the
// stats are unavailable, the way lib/godWins.ts fails quietly. Supabase is
// imported inside each read, so the pure helpers load without it (the Node
// tests have no Supabase environment).

// One player's record against one opponent (or the multiplayer record).
export type StatRecord = {
  wins: number;
  losses: number;
  games: number;
  // Rounded whole percent; null with no games (shown as a dash).
  winPct: number | null;
  skunks: number;
  doubleSkunks: number;
  timesSkunked: number;
};

// A get_solo_stats() row, as the function returns it.
export type SoloStatsRow = {
  user_id: string;
  level: string;
  wins: number;
  losses: number;
  skunks: number;
  double_skunks: number;
  times_skunked: number;
  skunk_tracking_since: string | null;
};

// The columns of a get_leaderboard() row this file reads.
export type LeaderboardRecordRow = {
  user_id: string;
  wins: number;
  losses: number;
  skunks: number;
  double_skunks: number;
  times_skunked: number;
  skunk_tracking_since: string | null;
};

// One of the four ladder rows. played: at least one finished game.
export type SoloEntry = StatRecord & { level: ComputerLevel; played: boolean };

// Win percent, rounded; null when there are no games.
export function winPercent(wins: number, losses: number): number | null {
  const games = wins + losses;
  return games > 0 ? Math.round((100 * wins) / games) : null;
}

// "67%", or a dash with no games.
export function formatWinPercent(pct: number | null): string {
  return pct === null ? "–" : `${pct}%`;
}

function toRecord(r: {
  wins: number;
  losses: number;
  skunks: number;
  double_skunks: number;
  times_skunked: number;
}): StatRecord {
  const wins = r.wins ?? 0;
  const losses = r.losses ?? 0;
  return {
    wins,
    losses,
    games: wins + losses,
    winPct: winPercent(wins, losses),
    skunks: r.skunks ?? 0,
    doubleSkunks: r.double_skunks ?? 0,
    timesSkunked: r.times_skunked ?? 0,
  };
}

const EMPTY: StatRecord = toRecord({ wins: 0, losses: 0, skunks: 0, double_skunks: 0, times_skunked: 0 });

// THE PROFILE'S ORDER for its Solo Play section: hardest first -- God,
// Rainman, Normie, Shortbus. Display only: the ladder itself
// (COMPUTER_LEVEL_ORDER, easiest first) is what the opponent chooser and
// everything else use, and it doesn't change.
export const PROFILE_SOLO_ORDER: readonly ComputerLevel[] = [...COMPUTER_LEVEL_ORDER].reverse();

// Exactly four entries, one per level, in the given order (by default the
// ladder, COMPUTER_LEVEL_ORDER: Shortbus, Normie, Rainman, God), each from
// that level's own row only. A level with no row (never finished) is all
// zeros with played false. Rows for another player or an unknown level are
// ignored; a repeated level keeps its first row. Nothing is summed across
// levels.
export function shapeSoloStats(
  rows: readonly SoloStatsRow[],
  userId?: string,
  order: readonly ComputerLevel[] = COMPUTER_LEVEL_ORDER
): SoloEntry[] {
  const byLevel = new Map<ComputerLevel, SoloStatsRow>();
  for (const row of rows) {
    if (userId && row.user_id !== userId) continue;
    if (!isComputerLevel(row.level) || byLevel.has(row.level)) continue;
    byLevel.set(row.level, row);
  }
  return order.map((level) => {
    const row = byLevel.get(level);
    const record = row ? toRecord(row) : EMPTY;
    return { ...record, level, played: record.games > 0 };
  });
}

// The player's own multiplayer record from get_leaderboard()'s rows, or null
// when they have no human games (no row -- also for a hidden account -- or a
// row that is only there for Beat God).
export function multiplayerRecord(rows: readonly LeaderboardRecordRow[], userId: string): StatRecord | null {
  const mine = rows.find((r) => r.user_id === userId);
  if (!mine) return null;
  const record = toRecord(mine);
  return record.games > 0 ? record : null;
}

// The skunk chips, with the leaderboard's wording; a 0 is left out.
export function skunkChips(record: StatRecord): { label: string; value: number }[] {
  return [
    { label: "Skunks", value: record.skunks },
    { label: "Double Skunks", value: record.doubleSkunks },
    { label: "Skunked", value: record.timesSkunked },
  ].filter((c) => c.value > 0);
}

// Each computer's name and avatar, from get_computer_profiles(), with
// LEVEL_INFO's name as the fallback and no avatar (initials).
export type ComputerFace = { name: string; url: string | null };

export function computerFaces(
  rows: readonly { level: string; nickname: string | null; avatar_url: string | null }[]
): Record<ComputerLevel, ComputerFace> {
  const faces = Object.fromEntries(
    COMPUTER_LEVEL_ORDER.map((level) => [level, { name: LEVEL_INFO[level].name, url: null }])
  ) as Record<ComputerLevel, ComputerFace>;
  for (const row of rows) {
    if (!isComputerLevel(row.level)) continue;
    faces[row.level] = { name: row.nickname?.trim() || LEVEL_INFO[row.level].name, url: row.avatar_url ?? null };
  }
  return faces;
}

// ---------------------------------------------------------------------------
// The reads. Each resolves, never rejects.
// ---------------------------------------------------------------------------

export type Read<T> = { ok: true; data: T } | { ok: false };

export async function readSoloStats(userId: string): Promise<Read<SoloStatsRow[]>> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc("get_solo_stats", { p_user_ids: [userId] });
    if (error || !Array.isArray(data)) return { ok: false };
    return { ok: true, data: data as SoloStatsRow[] };
  } catch {
    return { ok: false };
  }
}

export async function readLeaderboardRows(): Promise<Read<LeaderboardRecordRow[]>> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc("get_leaderboard");
    if (error || !Array.isArray(data)) return { ok: false };
    return { ok: true, data: data as LeaderboardRecordRow[] };
  } catch {
    return { ok: false };
  }
}

// A failed read just means the fallback names and initials.
export async function readComputerFaces(): Promise<Record<ComputerLevel, ComputerFace>> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc("get_computer_profiles");
    if (error || !Array.isArray(data)) return computerFaces([]);
    return computerFaces(data as { level: string; nickname: string | null; avatar_url: string | null }[]);
  } catch {
    return computerFaces([]);
  }
}
