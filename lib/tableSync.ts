// TABLE SYNC: the pure rules that decide how often the table page re-reads
// the database and what it can skip (app/tables/[code]/page.tsx). Tested by
// scripts/test-phase3.ts.

import type { PlayEvent } from "@/lib/pegging";

// THE SAFETY POLL: a light read (the live game row and the roster) that
// repairs anything a missed realtime event left wrong. Every 30 s while
// realtime is connected, when events already keep the screen current. While
// it is NOT confirmed connected -- at startup, and after any disconnect or
// error until the channel reports SUBSCRIBED again -- it BACKS OFF instead of
// tightening: 12 s, then 24 s, then 60 s from then on, so a Realtime outage
// doesn't turn every open table into a request storm. Back to 30 s the moment
// the channel is connected again. Every wait is randomised by +/-25%
// (POLL_JITTER), so thousands of screens opened together never poll in step.
// The longest wait (60 s + 25% = 75 s) stays under the 90 s spectator cutoff
// the heartbeat (which rides this poll) must beat.
export const SAFETY_POLL_MS = 12_000;
export const SAFETY_POLL_CONNECTED_MS = 30_000;
export const SAFETY_POLL_BACKOFF_MS = [SAFETY_POLL_MS, 24_000, 60_000] as const;
export const POLL_JITTER = 0.25;

// The wait before the next poll. `disconnectedPolls`: how many polls have
// been scheduled since the channel was last connected (0 for the first);
// `random`: a number in [0, 1) (Math.random), so tests can pin it.
export function nextPollDelayMs(t: { connected: boolean; disconnectedPolls: number; random: number }): number {
  const steps = SAFETY_POLL_BACKOFF_MS;
  const base = t.connected
    ? SAFETY_POLL_CONNECTED_MS
    : steps[Math.min(Math.max(0, Math.floor(t.disconnectedPolls)), steps.length - 1)];
  const r = Math.min(Math.max(t.random, 0), 1);
  return Math.round(base * (1 - POLL_JITTER + 2 * POLL_JITTER * r));
}

// THE PLAY LOG, MERGED (the game_plays listener and its catch-up read): the
// plays on screen plus `incoming`, one per seq (a seq already shown is never
// added twice -- the screen's copy is kept), in seq order. The same array
// back when nothing is new, so a duplicate event or an overlapping read
// re-renders nothing.
export function mergePlays<P extends Pick<PlayEvent, "seq">>(current: P[], incoming: readonly P[]): P[] {
  const have = new Set(current.map((p) => p.seq));
  const added: P[] = [];
  for (const p of incoming) {
    if (have.has(p.seq)) continue;
    have.add(p.seq);
    added.push(p);
  }
  if (added.length === 0) return current;
  return [...current, ...added].sort((a, b) => a.seq - b.seq);
}

// WHETHER A PLAYS CATCH-UP READ MAY BE APPLIED: only to the same game AND the
// same hand it was issued for. game_plays is emptied at each next hand and
// its seq starts again, so a read issued before a Next Hand that answers
// after it would otherwise put the old hand's plays into the new one.
export function playsCatchUpApplies(
  issued: { gameId: string; handNo: number | null | undefined },
  now: { gameId: string | null; handNo: number | null | undefined }
): boolean {
  return issued.gameId === now.gameId && (issued.handNo ?? null) === (now.handNo ?? null);
}

// NAME AND AVATAR EDITS reach a table through the safety poll (there is no
// profiles listener: an unfiltered one sent every profile edit anywhere to
// every open table). Every PROFILE_REFRESH_POLLS-th poll re-reads the
// profiles of everyone on screen, not only new seats: about every 2 minutes
// at the connected pace. One small read of at most 8 ids.
export const PROFILE_REFRESH_POLLS = 4;
export function pollRefreshesProfiles(pollNumber: number): boolean {
  return pollNumber > 0 && pollNumber % PROFILE_REFRESH_POLLS === 0;
}

// WHICH PROFILES A ROSTER READ FETCHES (loadMembers). A player not on screen
// yet always does (a new seat, a rejoin, the first load). The poll fetches
// only those -- except every PROFILE_REFRESH_POLLS-th poll (refreshAll),
// which re-reads everyone's, so name and avatar edits arrive. A full refresh
// also re-reads a player whose seat changed or whose profile never loaded
// (no name on screen); a player already shown with their name, in the same
// seat, is skipped.
export function profilesToFetch(
  rows: readonly { user_id: string; seat: number | null }[],
  shown: readonly { user_id: string; seat: number | null; nickname: string | null }[],
  poll: boolean,
  refreshAll = false
): string[] {
  const shownById = new Map(shown.map((m) => [m.user_id, m]));
  return rows
    .filter((row) => {
      const onScreen = shownById.get(row.user_id);
      if (!onScreen) return true;
      if (refreshAll) return true;
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
