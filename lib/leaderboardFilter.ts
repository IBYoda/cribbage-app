import { isComputerLevel, LEVEL_INFO, type ComputerLevel } from "@/lib/computer/config";
import { PROFILE_SOLO_ORDER, type ComputerFace } from "@/lib/soloStats";

// THE LEADERBOARD'S FILTERS (PRD item 35, slice S4): which board is on screen,
// kept in the URL as ?vs=<level>, and the chips that pick it.
//
//   Multiplayer      get_leaderboard(), the main board, exactly as before
//   vs a computer    get_solo_leaderboard(level): the players ranked by ONLY
//                    their record against that computer
//
// Pure, apart from readSoloLeaderboard at the bottom (tested in
// scripts/test-phase3.ts). The chips are DATA -- one list -- so a "Friends"
// chip can be added at the end later: a new LeaderboardFilter kind, one more
// entry in leaderboardChips(), and its read.

export type LeaderboardFilter = { kind: "all" } | { kind: "computer"; level: ComputerLevel };

export const ALL_PLAYERS: LeaderboardFilter = { kind: "all" };

// THE URL. ?vs=<level> -- easy, casual, medium or hard -- is a computer
// board; no ?vs, or any other value, is Multiplayer. Read loosely (trimmed,
// any case, the FIRST ?vs when repeated), written canonically (lowercase,
// one ?vs, removed for Multiplayer).
export const VS_PARAM = "vs";

export function filterFromSearch(search: string | URLSearchParams): LeaderboardFilter {
  const params = typeof search === "string" ? new URLSearchParams(search) : search;
  const value = params.get(VS_PARAM)?.trim().toLowerCase();
  return isComputerLevel(value) ? { kind: "computer", level: value } : ALL_PLAYERS;
}

// The query string for a filter, keeping any other params: "" or "?vs=hard".
export function searchForFilter(current: string, filter: LeaderboardFilter): string {
  const params = new URLSearchParams(current);
  params.delete(VS_PARAM);
  if (filter.kind === "computer") params.set(VS_PARAM, filter.level);
  const text = params.toString();
  return text ? `?${text}` : "";
}

export function sameFilter(a: LeaderboardFilter, b: LeaderboardFilter): boolean {
  return a.kind === b.kind && (a.kind !== "computer" || (b.kind === "computer" && a.level === b.level));
}

// THE CHIPS, in order: Multiplayer, then the computers hardest first, as the
// Profile's Solo Play section (PROFILE_SOLO_ORDER). Each computer chip has
// its live name and avatar (faces, from get_computer_profiles(), falling back
// to LEVEL_INFO's name and initials).
export type LeaderboardChip = {
  id: string;
  label: string;
  // A computer chip's avatar; undefined for a chip with none.
  avatar?: { name: string; url: string | null };
  filter: LeaderboardFilter;
};

export function leaderboardChips(faces: Partial<Record<ComputerLevel, ComputerFace>>): LeaderboardChip[] {
  return [
    { id: "all", label: "Multiplayer", filter: ALL_PLAYERS },
    ...PROFILE_SOLO_ORDER.map((level): LeaderboardChip => {
      const face = faces[level] ?? { name: LEVEL_INFO[level].name, url: null };
      return { id: level, label: face.name, avatar: face, filter: { kind: "computer", level } };
    }),
  ];
}

// The words for a computer board: its heading, its empty state and its
// failed read.
export function computerBoardText(name: string) {
  return {
    heading: `Against ${name}`,
    empty: `Nobody has finished a game against ${name} yet.`,
    failed: "Couldn't load this leaderboard. Try Refresh.",
  };
}

// ---------------------------------------------------------------------------
// The read: one level's board. Resolves, never rejects. Supabase is imported
// inside, so the pure helpers above load without it (the Node tests).
// ---------------------------------------------------------------------------
export async function readSoloLeaderboard(level: ComputerLevel): Promise<{ ok: true; data: unknown[] } | { ok: false }> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc("get_solo_leaderboard", { p_level: level });
    if (error || !Array.isArray(data)) return { ok: false };
    return { ok: true, data };
  } catch {
    return { ok: false };
  }
}
