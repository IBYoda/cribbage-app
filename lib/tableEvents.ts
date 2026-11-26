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
