// TABLE EVENTS (moderation M5a, docs/sql/moderation-m5a-part1.sql): the
// server pushes a private Realtime broadcast on table:<table_id> whenever
// the table's people change (a seat taken, left, kicked or moved; a
// spectator added, removed, deleted or back after going stale) or the table
// row changes (it ended, ...). Database triggers send it through
// realtime.send; no client can send there.
//
// The payload is ids and a version only: { event, table_id, roster_version }
// (Realtime may add its own "id": ignored). event is "members",
// "spectators" or "table". Nothing in it is shown: an event only makes the
// screen re-read what the safety poll already reads.
//
// THE VERSION RULE (acceptTableEvent): tables.roster_version goes up by 1
// with every members or spectators event, so each of those carries a NEW
// number -- one at or below the highest already seen is a duplicate or
// arrived out of order, and is dropped. A "table" event does NOT bump the
// version: it carries the current one, which can EQUAL the last roster
// event's (or be the very first number seen), so it is dropped only when it
// is strictly older. A dropped event costs nothing: the safety poll still
// repairs anything missed.
//
// Pure rules here (no React, no Supabase); the channel is
// components/table/useTableEvents.ts. Tested by scripts/test-phase3.ts.

export type TableEventKind = "members" | "spectators" | "table";

export type TableEvent = { kind: TableEventKind; tableId: string; rosterVersion: number };

export const TABLE_EVENT_KINDS: readonly TableEventKind[] = ["members", "spectators", "table"];

// The topic for a table, lowercase (the server's rule refuses any other
// shape).
export function tableEventTopic(tableId: string): string {
  return `table:${tableId.toLowerCase()}`;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// A broadcast's payload as an event for THIS table, or null when it isn't
// one (another table, an unknown kind, a missing or bad version).
export function parseTableEvent(payload: unknown, tableId: string): TableEvent | null {
  if (!payload || typeof payload !== "object") return null;
  const p = payload as { event?: unknown; table_id?: unknown; roster_version?: unknown };
  if (typeof p.event !== "string" || !(TABLE_EVENT_KINDS as readonly string[]).includes(p.event)) return null;
  if (typeof p.table_id !== "string" || !UUID.test(p.table_id) || p.table_id !== tableId.toLowerCase()) return null;
  const v = typeof p.roster_version === "number" ? p.roster_version : typeof p.roster_version === "string" ? Number(p.roster_version) : NaN;
  if (!Number.isSafeInteger(v) || v < 0) return null;
  return { kind: p.event as TableEventKind, tableId: p.table_id, rosterVersion: v };
}

// Whether to act on an event, given the highest version already seen for
// this table (null: none yet), and the highest version after it.
export function acceptTableEvent(lastSeen: number | null, event: TableEvent): { accept: boolean; lastSeen: number } {
  if (lastSeen === null) return { accept: true, lastSeen: event.rosterVersion };
  const accept = event.kind === "table" ? event.rosterVersion >= lastSeen : event.rosterVersion > lastSeen;
  return { accept, lastSeen: Math.max(lastSeen, event.rosterVersion) };
}

// WHO LISTENS: only once my place is confirmed -- my seat in the roster
// read, or my row in the spectator list read -- because Realtime checks the
// right to listen only when the channel is joined. The role is part of the
// channel's key, so watching -> seated (or the reverse) joins again under
// the new place. null: don't listen.
export type TableEventRole = "player" | "spectator";

export function tableEventRole(input: {
  // An open human table I'm signed in at, not leaving, no error (chat's
  // rule: lib/tableChat.ts and TableView's chatOn).
  available: boolean;
  spectating: boolean;
}): TableEventRole | null {
  if (!input.available) return null;
  return input.spectating ? "spectator" : "player";
}

// GAME EVENTS (moderation M5b1, docs/sql/moderation-m5b1-part1.sql): one
// 'game' event per game per committed transaction on the same topic:
//   { event: 'game', game_id, hand_no, state_version, last_play_seq }
// (Realtime adds its own "id": ignored). state_version is per game and
// only moves up -- by several per action, on every update -- so it is only
// ever COMPARED, never counted with. It means "this game changed": the
// screen re-reads the game itself, exactly as the safety poll does.
export type GameEvent = { gameId: string; handNo: number; stateVersion: number; lastPlaySeq: number };

const isWholeNumber = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0;

// A broadcast's payload as a game event, or null when it isn't exactly one.
export function parseGameEvent(payload: unknown): GameEvent | null {
  if (!payload || typeof payload !== "object") return null;
  const p = payload as { event?: unknown; game_id?: unknown; hand_no?: unknown; state_version?: unknown; last_play_seq?: unknown };
  if (p.event !== "game") return null;
  if (typeof p.game_id !== "string" || !UUID.test(p.game_id)) return null;
  // hand_no: a game's row always has one; null is read as 0 (before any hand).
  const handNo = p.hand_no === null ? 0 : p.hand_no;
  if (!isWholeNumber(handNo) || !isWholeNumber(p.state_version) || !isWholeNumber(p.last_play_seq)) return null;
  return { gameId: p.game_id, handNo, stateVersion: p.state_version, lastPlaySeq: p.last_play_seq };
}

// THE GAME VERSION RULE, per game id: accept only an event NEWER than the
// newest seen for that game -- a later hand, or the same hand with a higher
// state_version. An equal or older one is a duplicate or arrived out of
// order: dropped. The first event seen for a game id is always accepted,
// and flagged firstForGame (the caller compares it with the game on screen:
// a different game is a new game -- the poll's full refresh).
export type GameSeen = { handNo: number; stateVersion: number };

export function acceptGameEvent(
  last: GameSeen | undefined,
  event: GameEvent
): { accept: boolean; firstForGame: boolean; last: GameSeen } {
  if (!last) return { accept: true, firstForGame: true, last: { handNo: event.handNo, stateVersion: event.stateVersion } };
  const newer = event.handNo > last.handNo || (event.handNo === last.handNo && event.stateVersion > last.stateVersion);
  return { accept: newer, firstForGame: false, last: newer ? { handNo: event.handNo, stateVersion: event.stateVersion } : last };
}

// What an accepted game event asks of the screen: the game on screen ->
// re-read it ("reconcile"), plus the play log when the event is ahead of
// the plays shown; another game -> the full refresh.
export function gameEventStep(input: {
  event: GameEvent;
  shownGameId: string | null;
  shownHandKey: string | null;
  shownMaxSeq: number;
}): { kind: "refresh" } | { kind: "reconcile"; readPlays: boolean } {
  if (input.event.gameId !== input.shownGameId) return { kind: "refresh" };
  const sameHand = input.shownHandKey === `${input.event.gameId}:${input.event.handNo}`;
  return { kind: "reconcile", readPlays: sameHand && input.event.lastPlaySeq > input.shownMaxSeq };
}
