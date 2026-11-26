// KICK (moderation M3, docs/sql/moderation-m3-part1.sql and part2.sql): the
// host removes someone from THIS table for good -- a player (the live game
// ends for everyone) or a spectator. The kicked person can never join or
// watch that table again and is told only "You can't join this table."
// (M1's refusal, REFUSED_TEXT); while being removed they see "The host
// removed you from this table." (REMOVED_TEXT, the spectator wording, now
// for players too).
//
// Everyone else at the table hears of it at once: kick_player sends a
// private Realtime broadcast on kicks:<table_id> (event "kick", payload
// { kicked_id, nickname, at }), which only people seated at the table or
// watching it may receive (kick_topic_allows). Broadcasts are never
// replayed, so a reload never shows an old kick.
//
// Pure rules plus the one RPC call (writeKick). No component calls the
// server for kicks itself. Tested by scripts/test-phase3.ts.

import { REFUSED_TEXT } from "@/lib/oneTable";

// THE HOST'S CONFIRM, before every kick (the popup's Kick, the spectator
// list's Kick, a spectator's chat-card eye): "Kick <name>?", and the game
// line only when the person is a PLAYER in a live game (kicking a spectator
// ends nothing).
export const KICK_GAME_LINE = "This ends the current game for everyone.";

export function kickConfirm(name: string, opts: { playerInLiveGame: boolean }) {
  return {
    title: `Kick ${name}?`,
    body: opts.playerInLiveGame ? KICK_GAME_LINE : "",
    yesLabel: "Kick",
    noLabel: "Cancel",
  };
}

// THE NOTICE to everyone else at the table (not the host, not the kicked
// person, not anyone who already blocks them): Walt's words, as one
// sentence pair over the dialog's title and body.
export function kickedNotice(name: string) {
  return {
    title: `${name} was kicked from the table.`,
    body: "Would you like to add them to your Block list?",
    yesLabel: "Yes, block",
    noLabel: "No, thanks",
  };
}

// The kick topic for a table, lowercase (the server's rule refuses any
// other shape).
export function kickTopic(tableId: string): string {
  return `kicks:${tableId.toLowerCase()}`;
}

export const KICK_EVENT = "kick";

export type KickNotice = { kickedId: string; nickname: string; at: number };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// A broadcast's payload as a notice, or null when it isn't one. Only the
// kicked person's id, nickname and time are read; anything else is ignored.
export function parseKickNotice(payload: unknown): KickNotice | null {
  if (!payload || typeof payload !== "object") return null;
  const p = payload as { kicked_id?: unknown; nickname?: unknown; at?: unknown };
  if (typeof p.kicked_id !== "string" || !UUID.test(p.kicked_id)) return null;
  const nickname = typeof p.nickname === "string" ? p.nickname.trim() : "";
  const at = typeof p.at === "number" && Number.isFinite(p.at) ? p.at : 0;
  return { kickedId: p.kicked_id, nickname: nickname || "A player", at };
}

// What a notice does on MY screen:
//   "self"   I was kicked: "The host removed you from this table." and home.
//   "ask"    ask whether to block them.
//   "ignore" the host (who kicked: they get their own "Also block?"),
//            someone who already blocks them, a notice already shown, or
//            one from before this screen opened (never replayed anyway).
export function kickNoticeAction(input: {
  notice: KickNotice;
  myUserId: string | null;
  iAmHost: boolean;
  blocked: boolean;
  alreadyShown: boolean;
  openedAt: number;
}): "self" | "ask" | "ignore" {
  if (!input.myUserId) return "ignore";
  if (input.notice.kickedId === input.myUserId) return "self";
  if (input.iAmHost || input.blocked || input.alreadyShown) return "ignore";
  // A generous margin for clock differences: only a notice that is clearly
  // older than this screen is skipped.
  if (input.notice.at > 0 && input.notice.at < input.openedAt - 5 * 60 * 1000) return "ignore";
  return "ask";
}

// Is this join refusal the one a kicked (or blocked) person gets? On the
// table screen, after my seat went while the table is still open, it means
// I was kicked.
export function isKickRefusal(error: { message?: string | null } | null | undefined): boolean {
  return error?.message === REFUSED_TEXT;
}

export type KickResult = { ok: true; outcome: "kicked" | "already_kicked" } | { ok: false; text: string };

export const KICK_FAILED_TEXT = "Couldn't kick them. Please try again.";

// The server's plain refusals, shown as they are; anything else is the
// generic line.
const KICK_SERVER_TEXTS = new Set([
  "Only the host can kick.",
  "You can't kick yourself.",
  "This table has ended.",
  "Table not found.",
  "That player was not found.",
  "You can't kick a computer player.",
  "You can't kick anyone at a computer table.",
  "You have kicked 20 people in the last hour. Please try again a little later.",
]);

export function kickFailureText(error: { message?: string | null } | null | undefined): string {
  const message = error?.message ?? "";
  return KICK_SERVER_TEXTS.has(message) ? message : KICK_FAILED_TEXT;
}

// THE KICK: kick_player(table, person). The only place the app calls it.
export async function writeKick(tableId: string, userId: string): Promise<KickResult> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc("kick_player", { p_table_id: tableId, p_target: userId });
    if (error) return { ok: false, text: kickFailureText(error) };
    if (data === "kicked" || data === "already_kicked") return { ok: true, outcome: data };
    return { ok: false, text: KICK_FAILED_TEXT };
  } catch {
    return { ok: false, text: KICK_FAILED_TEXT };
  }
}

// THE ADMIN PAGE'S RECENT KICKS (admin_recent_kicks: admins only; anyone
// else is refused "Admins only."). Newest first.
export type RecentKick = {
  kickedAt: string;
  tableId: string;
  tableCode: string;
  hostNickname: string | null;
  kickedNickname: string | null;
  kickedRole: "player" | "spectator" | "absent";
  gameLive: boolean;
};

export function recentKicksFromRows(rows: unknown): RecentKick[] {
  if (!Array.isArray(rows)) return [];
  return rows.flatMap((r) => {
    const row = r as Record<string, unknown> | null;
    if (!row || typeof row.kicked_at !== "string" || typeof row.table_id !== "string") return [];
    const role = row.kicked_role === "player" || row.kicked_role === "spectator" ? row.kicked_role : "absent";
    return [
      {
        kickedAt: row.kicked_at,
        tableId: row.table_id,
        tableCode: typeof row.table_code === "string" ? row.table_code : "",
        hostNickname: typeof row.host_nickname === "string" ? row.host_nickname : null,
        kickedNickname: typeof row.kicked_nickname === "string" ? row.kicked_nickname : null,
        kickedRole: role,
        gameLive: row.game_live === true,
      },
    ];
  });
}

// One line for a kick, e.g. "Table 0412: Ann kicked Bo (player, game ended)".
export function recentKickLine(k: RecentKick): string {
  const host = k.hostNickname?.trim() || "A deleted account";
  const who = k.kickedNickname?.trim() || "Unnamed player";
  const what = k.kickedRole === "player" ? (k.gameLive ? "player, game ended" : "player") : k.kickedRole === "spectator" ? "spectator" : "had just left";
  return `Table ${k.tableCode}: ${host} kicked ${who} (${what})`;
}

export async function readRecentKicks(limit = 50): Promise<{ ok: true; data: RecentKick[] } | { ok: false; text: string }> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc("admin_recent_kicks", { p_limit: limit });
    if (error) return { ok: false, text: error.message === "Admins only." ? error.message : "Couldn't load the recent kicks." };
    return { ok: true, data: recentKicksFromRows(data) };
  } catch {
    return { ok: false, text: "Couldn't load the recent kicks." };
  }
}
