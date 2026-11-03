// TABLE SYNC: the pure rules that decide how often the table page re-reads
// the database and what it can skip (app/tables/[code]/page.tsx). Tested by
// scripts/test-phase3.ts.

// THE SAFETY POLL: a light read (the live game row and the roster) that
// repairs anything a missed realtime event left wrong. Every 12 s while
// realtime is not confirmed connected -- at startup, and after any
// disconnect or error until the channel reports SUBSCRIBED again -- and
// every 30 s while it is, when events already keep the screen current.
export const SAFETY_POLL_MS = 12_000;
export const SAFETY_POLL_CONNECTED_MS = 30_000;

export function pollIntervalMs(realtimeConnected: boolean): number {
  return realtimeConnected ? SAFETY_POLL_CONNECTED_MS : SAFETY_POLL_MS;
}

// WHICH PROFILES A ROSTER READ FETCHES (loadMembers). A player not on screen
// yet always does (a new seat, a rejoin, the first load). The poll fetches
// only those. A full refresh also re-reads a player whose seat changed or
// whose profile never loaded (no name on screen); a player already shown
// with their name, in the same seat, is skipped -- profile edits arrive
// through realtime (the profiles UPDATE listener).
export function profilesToFetch(
  rows: readonly { user_id: string; seat: number | null }[],
  shown: readonly { user_id: string; seat: number | null; nickname: string | null }[],
  poll: boolean
): string[] {
  const shownById = new Map(shown.map((m) => [m.user_id, m]));
  return rows
    .filter((row) => {
      const onScreen = shownById.get(row.user_id);
      if (!onScreen) return true;
      if (poll) return false;
      return onScreen.seat !== row.seat || onScreen.nickname === null;
    })
    .map((row) => row.user_id);
}

// WHETHER A FULL REFRESH CAN KEEP THE WON BOARD ON SCREEN instead of
// reading it again (game_plays, game_hands, game_cribs): only when the same
// won game is on screen and its board came from a read that fully succeeded
// (complete). A different game, a board built from what was on screen when
// the game ended (not complete), a failed read, or nothing on screen (the
// first load, a reload, a rejoin) reads it as before.
export function wonBoardReusable(
  shown: { id: string; board: { complete?: boolean } } | null,
  gameId: string
): boolean {
  return !!shown && shown.id === gameId && shown.board.complete === true;
}
