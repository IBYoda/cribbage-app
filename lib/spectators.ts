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
// spectators, is a human table (computer_level null), has someone seated,
// the viewer is NOT seated there (their own table shows as "Your table"),
// and there is no seat to offer them as a Join row: its game has started,
// or every seat is taken (a full table that has not started yet -- the row
// says "Not started"). A table that allows spectators and still has a free
// seat before its game is a Join row whose Join asks Play or Watch
// (joinRowAction). The joinable list's age filter (isStaleWaitingTable)
// applies too -- it never hides a table with a live game.
export function isWatchableTable(
  t: {
    status: string | null;
    isPublic: boolean | null;
    allowSpectators: boolean | null;
    computerLevel: string | null;
    seatedIds: readonly string[];
    capacity: number;
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
    (t.gameLive || t.seatedIds.length >= t.capacity) &&
    t.seatedIds.length >= 1 &&
    !t.seatedIds.includes(viewerId) &&
    !isStaleWaitingTable({ createdAt: t.createdAt, gameLive: t.gameLive }, now)
  );
}

// A Watch row's state line: the game is on, or the table is full and has
// not started.
export function watchRowState(gameLive: boolean): string {
  return gameLive ? "Game in progress" : "Not started";
}

// ONE ROW PER TABLE (HomeMenu): the viewer's own tables first (never listed
// again below), then Join rows, then Watch rows. A table the viewer could
// watch (a live game, or full and not started) is a Watch row even when the
// joinable read also lists it (a free seat at a live game): there is no
// seat to offer before the next game.
export function splitOpenTableRows<J extends { code: string }, W extends { code: string }>(
  mineCodes: ReadonlySet<string>,
  joinable: readonly J[],
  watchable: readonly W[]
): { joinRows: J[]; watchRows: W[] } {
  const watchRows = watchable.filter((t) => !mineCodes.has(t.code));
  const watchCodes = new Set(watchRows.map((t) => t.code));
  const joinRows = joinable.filter((t) => !mineCodes.has(t.code) && !watchCodes.has(t.code));
  return { joinRows, watchRows };
}

// A JOIN ROW's button: straight to the seat ("join", exactly as before), or
// -- at a human table that allows spectators -- a small choice first, Play
// or Watch ("choose"). Join rows only ever list tables with a free seat.
// The table's CREATOR is never asked (joinOrWatch): their own table, back
// to their seat -- e.g. a creator who left and finds it listed again.
export function joinRowAction(t: {
  allowSpectators: boolean | null;
  computerLevel?: string | null;
  isCreator?: boolean;
}): "join" | "choose" {
  if (t.isCreator === true) return "join";
  return t.allowSpectators === true && t.computerLevel == null ? "choose" : "join";
}

// JOIN BY CODE (and a Join row's choice): take a seat, offer "Watch
// instead", or ask Play or Watch first.
//   seat   -- exactly today's path: already seated there, a table that
//             doesn't allow spectators or a computer table (which still
//             answers "This table is full." when the seat is refused), the
//             newcomer already chose Play, or the viewer is the table's
//             CREATOR (tables.created_by): the creator never gets the
//             choice -- Start a Table lands them on the table page before
//             their seat exists, and they always take it.
//   watch  -- no seat for them: the table is full, or its game has started
//             ("Watch instead"). Even after choosing Play: the seat is gone.
//   choose -- a free seat before the game, at a human table that allows
//             spectators, for anyone but its creator: Play or Watch, before
//             anyone is seated.
// A creator who finds their table full or started (they left and came back)
// follows the same rules as anyone: watch.
export type JoinChoice = "seat" | "watch" | "choose";

export function joinOrWatch(t: {
  isMember: boolean;
  seated: number;
  capacity: number;
  gameLive: boolean;
  allowSpectators: boolean | null;
  computerLevel: string | null;
  playChosen?: boolean;
  isCreator?: boolean;
}): JoinChoice {
  if (t.isMember) return "seat";
  if (t.allowSpectators !== true || t.computerLevel != null) return "seat";
  if (t.seated >= t.capacity || t.gameLive) return "watch";
  return t.playChosen === true || t.isCreator === true ? "seat" : "choose";
}

// CHOOSING PLAY never asks again: the choice's Play goes to the table page
// with ?play=1 (playHref), and the table page's own choice screen sets the
// same flag in memory and re-runs its setup. Either way joinOrWatch gets
// playChosen and answers "seat" (unless the seat has gone meanwhile).
export const PLAY_PARAM = "play";

export function playHref(code: string): string {
  return `/tables/${code}?${PLAY_PARAM}=1`;
}

export function playChosenFromSearch(search: string): boolean {
  return new URLSearchParams(search).get(PLAY_PARAM) === "1";
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

// "No game yet" (the OLD watch_table only; the new one lets a spectator into
// the waiting room with a NULL game id): watch_table is asked again,
// quietly, this often until a game starts (or the player leaves the page).
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

// The quiet watch_table's whole answer: let in -> STAY, with or without a
// live game (the new SQL answers a NULL game id in the waiting room and
// between games); refused -> rewatchOutcome (the old SQL's "no game yet"
// stays too).
export function rewatchStep(result: { ok: { gameId: string | null } } | { refused: string }): RewatchOutcome {
  return "ok" in result ? { kind: "continue" } : rewatchOutcome(result.refused);
}

// FOLLOWING THE TABLE'S GAME: the table view reports each live game on
// screen; a different one from the game being watched is a NEW game (a
// rematch, the next game after the table waited) -- watch_table is asked
// again quietly and the ticket moves to it. The same id, or none, is not.
export function followGame(watchedGameId: string | null, liveGameId: string | null): boolean {
  return liveGameId !== null && liveGameId !== watchedGameId;
}

export const TABLE_CLOSED_TEXT = "This table has closed.";

// ---------------------------------------------------------------------------
// SPECTATOR CHAT AND THE HOST'S REMOVE (PRD items 39 and 40, spectator chat).

// THE EYE beside the table code (and its pill on a Muggins table's tag line):
// shown ONLY while at least one current spectator is watching, with the
// count. Unknown (the list not read yet, or the table doesn't allow
// spectators): nothing.
export function spectatorEyeCount(list: readonly unknown[] | null | undefined): number {
  return list ? list.length : 0;
}

export function showSpectatorsEye(count: number): boolean {
  return count > 0;
}

// THE CHAT ROSTER: the seated players, then the current spectators (flagged:
// their messages carry the eye). A message is shown only if its sender is in
// this roster, so a spectator who leaves the list -- removed, stopped, gone
// stale -- is dropped the moment the list no longer has them. Someone both
// seated and listed (only for an instant, while a spectator takes a seat)
// counts as a player.
export type ChatRosterPerson = { user_id: string; nickname: string | null; avatar_url: string | null; spectator?: boolean };

export function mergeChatRoster(
  players: readonly { user_id: string; nickname: string | null; avatar_url: string | null }[],
  spectators: readonly { userId: string; nickname: string | null; avatarUrl: string | null }[] | null | undefined
): ChatRosterPerson[] {
  const seated = new Set(players.map((p) => p.user_id));
  return [
    ...players.map((p) => ({ user_id: p.user_id, nickname: p.nickname, avatar_url: p.avatar_url, spectator: false })),
    ...(spectators ?? [])
      .filter((s) => !seated.has(s.userId))
      .map((s) => ({ user_id: s.userId, nickname: s.nickname, avatar_url: s.avatarUrl, spectator: true })),
  ];
}

// The host's Remove worked: that spectator leaves the list at once on the
// host's screen (and so the chat roster: their messages stop here now), not
// at the next poll.
export function withoutSpectator<T extends { userId: string }>(list: readonly T[] | null, userId: string): T[] | null {
  return list ? list.filter((s) => s.userId !== userId) : list;
}

// Who may remove a spectator: the HOST only (the server's remove_spectator
// checks table_host again), never a spectator, and only someone listed as
// a spectator.
export function canRemoveSpectator(t: { isHost: boolean; spectating: boolean; targetIsSpectator: boolean }): boolean {
  return t.isHost && !t.spectating && t.targetIsSpectator;
}

// WHOSE EARS a sound uses: a player's own seat; a spectator hears the table
// from Seat 1, the seat their screen is drawn from (spectatorViewerId) -- a
// win or a loss is Seat 1's.
export function soundSeatId(t: { spectating: boolean; viewerId: string; myId: string | null }): string | null {
  return t.spectating ? (t.viewerId === NOBODY_SEATED ? null : t.viewerId) : t.myId;
}

// A spectator never taps, so the sounds a player's own tap starts must come
// from the table's state on a spectator's screen. Cut cards, discards and
// plays already do (each screen but the tapper's plays them from the games
// row / the plays). The DEAL is the one sound only the deal animation starts,
// and a spectator has no deal animation: it plays when a hand is dealt live
// (the same moment a player's animation would start), keyed like the
// animation's, so it can never play twice.
export function spectatorDealSound(t: { spectating: boolean; liveKey: string | null; handKey: string | null }): string | null {
  return t.spectating && t.liveKey !== null && t.liveKey === t.handKey ? t.liveKey : null;
}

export const SPECTATOR_REMOVE_CONFIRM = "They can't watch this table again.";

// ---------------------------------------------------------------------------
// THE SPECTATOR'S WAITING ROOM (the table's own waiting screens, read-only).

// WaitingForPlayer's title: a 2-player table waits for "a second player" (a
// spectator with nobody seated yet: "Waiting for players"); 3 and 4 players
// say how many are here.
export function waitingForPlayerTitle(t: { seated: number; capacity: number; spectating: boolean }): string {
  if (t.capacity !== 2) return `Waiting for players (${t.seated} of ${t.capacity})`;
  return t.spectating && t.seated === 0 ? "Waiting for players" : "Waiting for a second player";
}

// The 3/4-player WaitingRoom's line for a spectator, under the seats: who
// the table waits on.
export function spectatorWaitingLine(t: { full: boolean; hostName: string | null }): string {
  return t.full
    ? `You're watching. Waiting for ${t.hostName ?? "the host"} to start.`
    : "You're watching. Waiting for players to sit down.";
}

// A full 2-player table with no game yet, on a spectator's screen: either
// player deals, so nobody is named.
export const SPECTATOR_NO_GAME_TEXT = "You're watching. Waiting for the players to start.";
