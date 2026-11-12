// FRIENDS (PRD item 36, F2 and F3): who the signed-in player follows, for the
// leaderboard's stars and its "Friends only" switch. The data is
// docs/sql/follows.sql (live): follow_user, unfollow_user and get_my_follows,
// security definer, the signed-in player's own list only.
//
// The pure helpers are tested in scripts/test-phase3.ts. The reads and
// writes never throw: a failure is { ok: false } or the outcome "error".
// Supabase is imported inside each call, so the pure helpers load without it
// (the Node tests have no Supabase environment).

// What follow_user / unfollow_user answered, or "error" for a failed call.
export type FollowOutcome = "following" | "not_following" | "limit" | "not_allowed" | "error";

export const FOLLOW_LIMIT = 50;

export const FOLLOW_LIMIT_MESSAGE = `You can follow up to ${FOLLOW_LIMIT} players. Unfollow someone first.`;
export const FOLLOW_FAILED_MESSAGE = "Couldn't update that just now.";

// Did the call do what the tap asked? (Following when following was asked
// for; not following when unfollowing was.)
export function followSucceeded(wantFollowing: boolean, outcome: FollowOutcome): boolean {
  return wantFollowing ? outcome === "following" : outcome === "not_following";
}

// The short message under the filter row after a refused or failed tap, or
// null when the tap worked.
export function followMessage(wantFollowing: boolean, outcome: FollowOutcome): string | null {
  if (followSucceeded(wantFollowing, outcome)) return null;
  return outcome === "limit" ? FOLLOW_LIMIT_MESSAGE : FOLLOW_FAILED_MESSAGE;
}

// A copy of the set with the id added (on) or removed (off).
export function toggledSet(set: ReadonlySet<string>, id: string, on: boolean): Set<string> {
  const next = new Set(set);
  if (on) next.add(id);
  else next.delete(id);
  return next;
}

// THE FRIENDS VIEW: the board's rows (already in its order) kept to the
// players in the SNAPSHOT of the follow list -- taken when the switch turns
// on and on Refresh, so a card unfollowed meanwhile stays -- plus the signed-in
// player. Order kept; the panel ranks what's left (rankWithTies) and shows
// them all (no top-20 cut: at most 51).
export function friendsView<T extends { user_id: string }>(
  rows: readonly T[],
  snapshot: ReadonlySet<string>,
  meId: string | null
): T[] {
  return rows.filter((r) => r.user_id === meId || snapshot.has(r.user_id));
}

// Friends only, following nobody: the stars are on the full board, so say how
// to get there.
export const FOLLOW_NOBODY_HINT =
  "You aren't following anyone yet. Turn Friends only off, then tap the star on a player's card to follow them.";

// The hint the Friends view shows (null: none):
//   following nobody                  how to follow someone (FOLLOW_NOBODY_HINT)
//   nobody followed is on this board  "None of the players you follow have
//                                     finished <a multiplayer game | a game
//                                     against God> yet."
// It shows under the player's own card when they have one, or alone.
export function friendsHint(
  viewRows: readonly { user_id: string }[],
  snapshot: ReadonlySet<string>,
  meId: string | null,
  computerName: string | null
): string | null {
  if (snapshot.size === 0) return FOLLOW_NOBODY_HINT;
  if (viewRows.some((r) => r.user_id !== meId)) return null;
  return computerName
    ? `None of the players you follow have finished a game against ${computerName} yet.`
    : "None of the players you follow have finished a multiplayer game yet.";
}

// RANKS WITH TIES (moved here from components/brand/Leaderboard.tsx, the same
// rule): the same wins AND losses as the row above share its rank; otherwise
// the rank is the position (1, 2, 2, 4). The rows arrive sorted.
export function rankWithTies<T extends { wins: number; losses: number }>(rows: readonly T[]): { row: T; rank: number }[] {
  const out: { row: T; rank: number }[] = [];
  rows.forEach((row, i) => {
    const prev = out[i - 1];
    const tied = prev && prev.row.wins === row.wins && prev.row.losses === row.losses;
    out.push({ row, rank: tied ? prev.rank : i + 1 });
  });
  return out;
}

// ---------------------------------------------------------------------------
// The reads and writes. Each resolves, never rejects.
// ---------------------------------------------------------------------------

export async function readMyFollows(): Promise<{ ok: true; data: string[] } | { ok: false }> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc("get_my_follows");
    if (error || !Array.isArray(data)) return { ok: false };
    return { ok: true, data: (data as { user_id: string }[]).map((r) => r.user_id) };
  } catch {
    return { ok: false };
  }
}

export async function writeFollow(userId: string, follow: boolean): Promise<FollowOutcome> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc(follow ? "follow_user" : "unfollow_user", { p_target: userId });
    if (error) return "error";
    return data === "following" || data === "not_following" || data === "limit" || data === "not_allowed"
      ? data
      : "error";
  } catch {
    return "error";
  }
}
