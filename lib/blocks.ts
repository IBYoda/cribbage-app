// THE BLOCK LIST (moderation M1): the Profile page's "Blocked players".
// The data is docs/sql/moderation-m1-part1.sql: block_player, unblock_player
// and get_my_blocks, security definer, the signed-in player's OWN list only
// (no client can read the table, and no function says who blocked whom).
// What a block does is on the server (moderation-m1-part2.sql): the blocked
// person can't join or watch any table the blocker created, and is only told
// "You can't join this table." (lib/oneTable.ts REFUSED_TEXT).
//
// In M1 a player is added by typing their EXACT nickname (case and the
// spaces around it don't matter); the answer says only whether it worked --
// nothing about the person. The pure helpers are tested in
// scripts/test-phase3.ts. The reads and writes never throw. Supabase is
// imported inside each call, so the pure helpers load without it.

export const BLOCK_LIMIT = 100;
export const BLOCK_CHANGES_PER_HOUR = 30;

// What block_player answered, plus "rate_limited" (the 31st real change in
// an hour: the server raises with detail rate_limited) and "error".
export type BlockOutcome = "blocked" | "already_blocked" | "not_found" | "not_allowed" | "limit" | "rate_limited" | "error";

// What unblock_player answered, plus "rate_limited" and "error".
export type UnblockOutcome = "unblocked" | "not_blocked" | "rate_limited" | "error";

export type BlockedPlayer = { userId: string; nickname: string; createdAt: string };

export const BLOCKED_TEXT = "Blocked.";
export const UNBLOCKED_TEXT = "Unblocked.";
export const ALREADY_BLOCKED_TEXT = "That player is already on your Block List.";
export const BLOCK_NOT_FOUND_TEXT = "No player has that nickname.";
export const BLOCK_NOT_ALLOWED_TEXT = "You can't block that player.";
export const BLOCK_LIMIT_TEXT = `Your Block List is full (${BLOCK_LIMIT} players). Unblock someone first.`;
export const BLOCK_RATE_TEXT = `You can block or unblock ${BLOCK_CHANGES_PER_HOUR} times an hour. Please try again a little later.`;
export const BLOCK_FAILED_TEXT = "Couldn't update your Block List just now.";
export const BLOCK_LIST_FAILED_TEXT = "Couldn't load your Block List.";
export const BLOCK_EMPTY_TEXT = "You haven't blocked anyone.";
export const BLOCK_ENTER_NAME_TEXT = "Type the player's exact nickname.";
// A blocked account with no nickname (it can't be added that way, but its
// nickname could be cleared later by an admin).
export const UNNAMED_PLAYER = "Unnamed player";

// The line under the box after Block: whether it worked, never anything
// about the person. ok: shown as a success.
export function blockMessage(outcome: BlockOutcome): { ok: boolean; text: string } {
  switch (outcome) {
    case "blocked":
      return { ok: true, text: BLOCKED_TEXT };
    case "already_blocked":
      return { ok: false, text: ALREADY_BLOCKED_TEXT };
    case "not_found":
      return { ok: false, text: BLOCK_NOT_FOUND_TEXT };
    case "not_allowed":
      return { ok: false, text: BLOCK_NOT_ALLOWED_TEXT };
    case "limit":
      return { ok: false, text: BLOCK_LIMIT_TEXT };
    case "rate_limited":
      return { ok: false, text: BLOCK_RATE_TEXT };
    default:
      return { ok: false, text: BLOCK_FAILED_TEXT };
  }
}

// The line after Unblock. Not on the list any more is what was asked for.
export function unblockMessage(outcome: UnblockOutcome): { ok: boolean; text: string } {
  if (outcome === "unblocked" || outcome === "not_blocked") return { ok: true, text: UNBLOCKED_TEXT };
  if (outcome === "rate_limited") return { ok: false, text: BLOCK_RATE_TEXT };
  return { ok: false, text: BLOCK_FAILED_TEXT };
}

// A refused call as an outcome: the hourly limit (detail rate_limited) has
// its own message; anything else is a failure.
export function blockErrorOutcome(error: { details?: string | null } | null | undefined): "rate_limited" | "error" {
  return error?.details === "rate_limited" ? "rate_limited" : "error";
}

// get_my_blocks' rows as the list shows them (newest first, as the server
// orders them); rows without an id are dropped.
export function blockedPlayersFromRows(data: unknown): BlockedPlayer[] | null {
  if (!Array.isArray(data)) return null;
  return data
    .filter((r): r is { user_id: string; nickname?: unknown; created_at?: unknown } => typeof r?.user_id === "string")
    .map((r) => ({
      userId: r.user_id,
      nickname: typeof r.nickname === "string" && r.nickname.trim() ? r.nickname.trim() : UNNAMED_PLAYER,
      createdAt: typeof r.created_at === "string" ? r.created_at : "",
    }));
}

// ---------------------------------------------------------------------------
// The reads and writes. Each resolves, never rejects.
// ---------------------------------------------------------------------------

export async function readMyBlocks(): Promise<{ ok: true; data: BlockedPlayer[] } | { ok: false }> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc("get_my_blocks");
    const rows = error ? null : blockedPlayersFromRows(data);
    return rows ? { ok: true, data: rows } : { ok: false };
  } catch {
    return { ok: false };
  }
}

export async function writeBlock(nickname: string): Promise<BlockOutcome> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc("block_player", { p_nickname: nickname });
    if (error) return blockErrorOutcome(error);
    return data === "blocked" || data === "already_blocked" || data === "not_found" || data === "not_allowed" || data === "limit"
      ? data
      : "error";
  } catch {
    return "error";
  }
}

// THE TABLE'S BLOCK (moderation M2, docs/sql/moderation-m2-part1.sql; since
// M2c only from "Also block <name>?" after a Mute):
// the sender's ACCOUNT ID, passed silently (nobody types or sees it), so a
// blank or look-alike nickname is still the right person. The same outcomes
// as writeBlock. The Profile page keeps writeBlock (by exact nickname).
export async function writeBlockById(userId: string): Promise<BlockOutcome> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc("block_player_by_id", { p_target: userId });
    if (error) return blockErrorOutcome(error);
    return data === "blocked" || data === "already_blocked" || data === "not_found" || data === "not_allowed" || data === "limit"
      ? data
      : "error";
  } catch {
    return "error";
  }
}

// The line a refused table Block ("Also block <name>?" after a Mute,
// moderation M2c) shows in the table's error line (null: it worked --
// blocked, or already on the list). No nickname wording: it goes by account
// id.
export function chatBlockFailureText(outcome: BlockOutcome): string | null {
  switch (outcome) {
    case "blocked":
    case "already_blocked":
      return null;
    case "limit":
      return BLOCK_LIMIT_TEXT;
    case "rate_limited":
      return BLOCK_RATE_TEXT;
    case "not_allowed":
      return BLOCK_NOT_ALLOWED_TEXT;
    default:
      return BLOCK_FAILED_TEXT;
  }
}

export async function writeUnblock(userId: string): Promise<UnblockOutcome> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc("unblock_player", { p_target: userId });
    if (error) return blockErrorOutcome(error);
    return data === "unblocked" || data === "not_blocked" ? data : "error";
  } catch {
    return "error";
  }
}
