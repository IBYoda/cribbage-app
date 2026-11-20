// SPECTATORS (PRD item 40): the pure rules the app uses before anyone
// watches -- which tables Open Tables offers to watch, and whether a code
// typed in Join leads to a seat or to "Watch instead". The database decides
// for real (watch_table, docs/sql/spectators.sql); these only choose what to
// show. Tested by scripts/test-phase3.ts.

import { isStaleWaitingTable } from "@/lib/tableListing";

// Where watching happens (the watch page, part B of the spectator UI).
export function watchHref(code: string): string {
  return `/watch/${code}`;
}

// A game is live while it is being cut for or played -- what watch_table
// calls a live game.
export const LIVE_GAME_STATUSES = ["cutting", "active"] as const;

export function isLiveGameStatus(status: string | null | undefined): boolean {
  return status === "cutting" || status === "active";
}

// OPEN TABLES' WATCH ROWS: a table is offered to watch when it is open,
// PUBLIC (a private table is never listed, whatever it allows), allows
// spectators, is a human table (computer_level null), has a live game, has
// someone seated, and the viewer is NOT seated there (their own table shows
// as "Your table"). The joinable list's age filter (isStaleWaitingTable)
// applies too -- it never hides a table with a live game, so in practice it
// changes nothing, but both lists keep the one rule.
export function isWatchableTable(
  t: {
    status: string | null;
    isPublic: boolean | null;
    allowSpectators: boolean | null;
    computerLevel: string | null;
    seatedIds: readonly string[];
    gameLive: boolean;
    createdAt: string;
  },
  viewerId: string,
  now: number
): boolean {
  return (
    t.status === "open" &&
    t.isPublic === true &&
    t.allowSpectators === true &&
    t.computerLevel == null &&
    t.gameLive &&
    t.seatedIds.length >= 1 &&
    !t.seatedIds.includes(viewerId) &&
    !isStaleWaitingTable({ createdAt: t.createdAt, gameLive: t.gameLive }, now)
  );
}

// JOIN BY CODE: take a seat (as always) or offer "Watch instead". Watch only
// for someone not seated there, at a human table that allows spectators,
// when there is no seat for them: the table is full, or its game has
// started. Everything else is "seat" -- exactly today's path, so a table
// that doesn't allow spectators still answers "This table is full." when
// the seat is refused.
export type JoinChoice = "seat" | "watch";

export function joinOrWatch(t: {
  isMember: boolean;
  seated: number;
  capacity: number;
  gameLive: boolean;
  allowSpectators: boolean | null;
  computerLevel: string | null;
}): JoinChoice {
  if (t.isMember) return "seat";
  if (t.allowSpectators !== true || t.computerLevel != null) return "seat";
  return t.seated >= t.capacity || t.gameLive ? "watch" : "seat";
}

// WHO "YOU" IS ON A SPECTATOR'S SCREEN: nobody at the table. Used where the
// table page asks "is this mine?" ("(you)", "Your turn", "You deal", ready
// lists): it matches no player id (a uuid), so nothing reads as theirs.
export const NOBODY_SEATED = "spectator:nobody-seated";

// WHOSE SEAT IS AT THE BOTTOM of a spectator's screen: Seat 1 -- the game's
// players list (seat order), else the roster's seat 1, else nobody yet.
export function spectatorViewerId(input: {
  gamePlayers: readonly string[] | null | undefined;
  roster: readonly { user_id: string; seat: number | null }[];
}): string {
  return input.gamePlayers?.[0] ?? input.roster.find((m) => m.seat === 1)?.user_id ?? NOBODY_SEATED;
}

// ---------------------------------------------------------------------------
// THE WATCH PAGE'S RULES (app/watch/[code]/page.tsx), pure.

// "No game yet": watch_table is asked again, quietly, this often until a game
// starts (or the player leaves the page).
export const WATCH_RETRY_MS = 5_000;

export const REMOVED_TEXT = "The host removed you from this table.";
export const NOT_ALLOWED_TEXT = "This table doesn't allow spectators.";
export const FULL_TEXT = "Spectators full: this table already has 4 spectators.";

// What a watch_table refusal (the server's message, word for word) means on
// screen. "seated" sends the player to their own seat; "waiting" keeps
// asking (WATCH_RETRY_MS); "login" offers Log in; everything else is a
// screen with the text and Back to home.
export type WatchRefusal = {
  kind: "login" | "seated" | "waiting" | "full" | "removed" | "ended" | "not_allowed" | "not_found" | "other";
  text: string;
};

export function watchRefusal(message: string): WatchRefusal {
  if (message.startsWith("You must be logged in")) return { kind: "login", text: "You need to be logged in to watch a table." };
  if (message === "You are seated at this table.") return { kind: "seated", text: message };
  if (message === "There is no game to watch at this table yet.") return { kind: "waiting", text: "Waiting for the next game..." };
  if (message.startsWith("Spectators full")) return { kind: "full", text: FULL_TEXT };
  if (message === "You were removed from watching this table.") return { kind: "removed", text: REMOVED_TEXT };
  if (message === "This table has ended.") return { kind: "ended", text: "This table has ended." };
  if (message === "This table does not allow spectators." || message === "Computer tables cannot be watched.")
    return { kind: "not_allowed", text: NOT_ALLOWED_TEXT };
  if (message.startsWith("No table found")) return { kind: "not_found", text: message };
  return { kind: "other", text: message };
}

// THE HEARTBEAT (spectator_heartbeat), what each answer does (part C):
//   ok           -> keep watching.
//   game_ended   -> STAY: the table shows the same game-over or waiting
//                   screen the players see; keep heartbeating, and follow
//                   the next game when one starts (followGame).
//   table_ended  -> "This table has closed": a calm screen with Back home,
//                   no redirect, no more heartbeats.
//   removed      -> home: "The host removed you from this table."
//   not_watching -> ask watch_table once, quietly (rewatchOutcome).
//   null         -> the call failed (the network): keep watching; the next
//                   poll asks again.
export type HeartbeatAnswer = "ok" | "removed" | "table_ended" | "game_ended" | "not_watching";
export type HeartbeatStep =
  | { kind: "continue" }
  | { kind: "rewatch" }
  | { kind: "closed" }
  | { kind: "home"; text: string };

export function heartbeatStep(answer: HeartbeatAnswer | null): HeartbeatStep {
  switch (answer) {
    case "removed":
      return { kind: "home", text: REMOVED_TEXT };
    case "table_ended":
      return { kind: "closed" };
    case "not_watching":
      return { kind: "rewatch" };
    default:
      // ok, game_ended (stay), or a failed call.
      return { kind: "continue" };
  }
}

// A QUIET watch_table (after not_watching, or to follow a new game) that was
// refused: "no game yet" is the table between games -- stay; removed -> home
// with its message; the table ended -> the closed screen; anything else
// (full, not allowed, ...) -> its screen, with Back home (no redirect).
export type RewatchOutcome =
  | { kind: "continue" }
  | { kind: "closed" }
  | { kind: "home"; text: string }
  | { kind: "screen"; text: string };

export function rewatchOutcome(message: string): RewatchOutcome {
  const r = watchRefusal(message);
  if (r.kind === "waiting") return { kind: "continue" };
  if (r.kind === "removed") return { kind: "home", text: REMOVED_TEXT };
  if (r.kind === "ended") return { kind: "closed" };
  return { kind: "screen", text: r.text };
}

// FOLLOWING THE TABLE'S GAME: the table view reports each live game on
// screen; a different one from the game being watched is a NEW game (a
// rematch, the next game after the table waited) -- watch_table is asked
// again quietly and the ticket moves to it. The same id, or none, is not.
export function followGame(watchedGameId: string | null, liveGameId: string | null): boolean {
  return liveGameId !== null && liveGameId !== watchedGameId;
}

export const TABLE_CLOSED_TEXT = "This table has closed.";
