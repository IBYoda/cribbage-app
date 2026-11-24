// ONE TABLE AT A TIME (step 3, slice A: docs/sql/join-create.sql). What a
// refusal from create_table, join_table_by_code, watch_table or
// create_computer_table means on screen. Pure (no Supabase import), tested by
// scripts/test-phase3.ts.
//
// The server marks each refusal of its own in the error's DETAIL:
//   already_at_table  seated at another table (with other humans); HINT is
//                     that table's code. Shown with "Go to table NNNN".
//   locked_out        too many wrong table codes; the message says how many
//                     minutes are left ("Please wait N minutes ...").
//   rate_limited      too many creates / joins / watches / computer games in
//                     the last hour.
// A wrong code is NOT an error: join_table_by_code answers outcome
// 'not_found' and watch_table answers no row (an exception would undo the
// count of wrong guesses).
//
// NEVER RAW SQL TEXT: anything not recognised here is "unknown" and shows
// GENERIC_ERROR_TEXT; the caller logs the details with logUnexpectedError.

// The fields a PostgREST error carries (supabase-js's PostgrestError).
export type RpcErrorLike = {
  message?: string | null;
  details?: string | null;
  hint?: string | null;
  code?: string | null;
};

export type Refusal =
  | { kind: "already_at_table"; text: string; tableCode: string }
  | { kind: "ended"; text: string }
  | { kind: "locked_out"; text: string }
  | { kind: "rate_limited"; text: string }
  | { kind: "not_found"; text: string }
  | { kind: "full"; text: string }
  | { kind: "unknown"; text: string };

export const GENERIC_ERROR_TEXT = "Something went wrong. Please try again.";
export const TABLE_FULL_TEXT = "This table is full.";
// The "table must be open" trigger's refusal (docs/sql/end-empty-tables.sql):
// a seat taken just as the table ended (the last player leaving at the same
// moment, or the empty-table sweep).
export const TABLE_ENDED_TEXT = "This table has ended.";
export const RATE_LIMITED_TEXT = "You've done that too many times in the last hour. Please try again later.";

// The one-line note where a start can quietly end a single-player game.
export const QUIET_CLOSE_NOTE = "Starting or joining another table ends any single-player game you have open.";

export function alreadyAtTableText(tableCode: string): string {
  return `You're already at table ${tableCode}. Rejoin it or leave it first.`;
}

export function notFoundText(code: string): string {
  return `No table found with code ${code}.`;
}

// "Go to table NNNN": the route that opens a table by its code.
export function tableHref(tableCode: string): string {
  return `/tables/${tableCode}`;
}

export function lockedOutText(minutes: number | null): string {
  if (minutes === null || !Number.isFinite(minutes) || minutes < 1) {
    return "Too many wrong table codes. Please wait a few minutes and try again.";
  }
  return `Too many wrong table codes. You can try again in ${minutes} minute${minutes === 1 ? "" : "s"}.`;
}

// The limit messages join-create.sql writes, word for word: friendly as they
// are, and they name the limit. Anything else marked rate_limited gets the
// plain RATE_LIMITED_TEXT.
const KNOWN_LIMIT_MESSAGE = /^You can (?:start|join|start watching) at most \d+ [a-z -]+ an hour\. Please try again later\.$/;

// What a refusal means. The seat trigger's "This table is full." is the one
// plain server message shown as it is.
export function rpcRefusal(error: RpcErrorLike | null | undefined): Refusal {
  const message = (error?.message ?? "").trim();
  const details = (error?.details ?? "").trim();
  const hint = (error?.hint ?? "").trim();

  if (details === "already_at_table") {
    const tableCode = /^[0-9]{4}$/.test(hint) ? hint : (message.match(/already at table ([0-9]{4})/)?.[1] ?? null);
    if (tableCode) return { kind: "already_at_table", text: alreadyAtTableText(tableCode), tableCode };
    return { kind: "unknown", text: GENERIC_ERROR_TEXT };
  }
  if (details === "locked_out") {
    const m = message.match(/wait (\d+) minute/);
    return { kind: "locked_out", text: lockedOutText(m ? Number(m[1]) : null) };
  }
  if (details === "rate_limited") {
    return { kind: "rate_limited", text: KNOWN_LIMIT_MESSAGE.test(message) ? message : RATE_LIMITED_TEXT };
  }
  if (message === TABLE_FULL_TEXT) return { kind: "full", text: TABLE_FULL_TEXT };
  if (message === TABLE_ENDED_TEXT) return { kind: "ended", text: TABLE_ENDED_TEXT };
  return { kind: "unknown", text: GENERIC_ERROR_TEXT };
}

// WHY A TABLE ENDED, for a player's screen (components/table/TableView.tsx:
// the realtime tables UPDATE, the stale-tab check, a reloaded old URL --
// the same account's second tab lands on one of these). tables.ended_reason:
//   NULL with a computer level  a single-player game closed by its player
//                               (Leave, or the one-table rule's quiet close)
//   'empty'                     everyone left (step 3 slice C: the last
//                               seat's delete, or the empty-table sweep;
//                               docs/sql/end-empty-tables.sql)
//   'timeout'                   the 12-hour sweep
//   anything else ('admin')     an admin's Force-End
// Spectators never see these: their screen is "This table has closed."
export const TABLE_EMPTY_ENDED_TEXT = "Everyone left, so this table has closed.";

export function tableEndedMessage(endedReason: string | null | undefined, computerLevel?: string | null): string {
  if (computerLevel && endedReason == null) return "This single-player game has ended.";
  if (endedReason === "empty") return TABLE_EMPTY_ENDED_TEXT;
  return endedReason === "timeout"
    ? "This table was automatically ended after being open for 12 hours."
    : "This table has been ended by an admin.";
}

// join_table_by_code's answer (one row). outcome: joined / already_seated /
// preview / not_found. Anything else (no row, an unknown outcome) is treated
// as unexpected.
export type JoinOutcome = "joined" | "already_seated" | "preview" | "not_found";

export function joinOutcome(data: unknown): JoinOutcome | null {
  const row = (Array.isArray(data) ? data[0] : data) as { outcome?: unknown } | null | undefined;
  const outcome = row?.outcome;
  return outcome === "joined" || outcome === "already_seated" || outcome === "preview" || outcome === "not_found"
    ? outcome
    : null;
}

// create_table's answer (one row): the new table's code, or null.
export function createdTableCode(data: unknown): string | null {
  const row = (Array.isArray(data) ? data[0] : data) as { code?: unknown } | null | undefined;
  return typeof row?.code === "string" && /^[0-9]{4}$/.test(row.code) ? row.code : null;
}

// The details of anything shown as GENERIC_ERROR_TEXT, for the console.
export function logUnexpectedError(context: string, error: unknown): void {
  console.error(`[${context}] unexpected error:`, error);
}
