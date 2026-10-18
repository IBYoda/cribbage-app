import type { ScorePlate } from "@/components/table/ScoreStrip";

// PHASE 3 (3 and 4 players): the pure rules the table screen builds on, in
// one place, with no React and no database -- scripts/test-phase3.ts checks
// them, including that every 2-player answer is exactly what the screen
// used before Phase 3.

// HAND SIZES by the number of players (PRD item 23; the server's
// deal_cards_for_game and discard_to_crib): 2 players are dealt 6 and
// discard 2; 3 and 4 are dealt 5 and discard 1. Everyone keeps 4, and the
// crib is always 4 (with 3 players one card goes to it from the deck).
export type HandSizes = { dealt: number; discard: number; kept: number };

export function handSizes(playerCount: number): HandSizes {
  return playerCount === 2 ? { dealt: 6, discard: 2, kept: 4 } : { dealt: 5, discard: 1, kept: 4 };
}

// The crib's face-down cards while players discard: everyone's discards so
// far, plus, with 3 players, the card dealt to it from the deck.
export function cribCountDuringDiscard(playerCount: number, discardedCount: number) {
  return discardedCount * handSizes(playerCount).discard + (playerCount === 3 ? 1 : 0);
}

// CARDS STILL HELD during pegging, from the public play log: the kept four
// minus the cards this player has played (never below 0). The same for 2, 3
// and 4 players -- go rows are not cards.
export function cardsLeft(kept: number, plays: { user_id: string; kind: string }[], userId: string) {
  const played = plays.filter((p) => p.kind === "play" && p.user_id === userId).length;
  return Math.max(kept - played, 0);
}

// SEAT ORDER: games.players is a snapshot in seat order (clockwise). From my
// point of view the table starts with me and goes clockwise. A viewer who
// isn't a player sees the list as it is.
export function seatOrderFrom(players: string[], myId: string): string[] {
  const i = players.indexOf(myId);
  if (i < 0) return [...players];
  return [...players.slice(i), ...players.slice(0, i)];
}

// WHERE EACH OTHER PLAYER SITS on my screen: the next player clockwise on my
// LEFT, then across the TOP, then on my RIGHT. 2 players: the other player
// across the top (as always). 3 players: left and right, nobody across the
// top. 4 players: left, top (my partner, in Teams), right.
export type SeatPlaces = { left: string | null; top: string | null; right: string | null };

export function seatPlaces(players: string[], myId: string): SeatPlaces {
  const others = seatOrderFrom(players, myId).filter((id) => id !== myId);
  if (others.length === 1) return { left: null, top: others[0], right: null };
  if (others.length === 2) return { left: others[0], top: null, right: others[1] };
  if (others.length === 3) return { left: others[0], top: others[1], right: others[2] };
  return { left: null, top: null, right: null };
}

// TEAMS (4 players, team_mode 'teams'): the positions in games.players are
// the seats, so positions 1 and 3 are one team and 2 and 4 the other --
// "team 1" and "team 2", by 0-based index parity. Read from the game's own
// players list, never from live seats (which can change after a game).
export function teamOfPosition(players: string[], userId: string): 1 | 2 | null {
  const i = players.indexOf(userId);
  if (i < 0) return null;
  return i % 2 === 0 ? 1 : 2;
}

// SCORE PLATES. One builder for every table size.
//   * Per player (2 and 3 players, 4-player Solo): one plate per row, in
//     the order given -- for 2 players exactly the list the screen always
//     built (me first, then the other player).
//   * Teams (4 players): one plate per TEAM, my team first. Both partners'
//     rows hold the team total (award_points), so the score is either row's
//     (the higher, in case one row's update is still on its way); the newest
//     award -- and the flash's name -- is the scorer's, the only row whose
//     last_* moved.
export type PlateRow = {
  user_id: string;
  name: string;
  avatar_url: string | null;
  score: number;
  last_points: number | null;
  last_reason: string | null;
  last_awarded_at: string | null;
};

const timeOf = (t: string | null) => (t ? Date.parse(t) || 0 : 0);

export function buildPlates(input: {
  rows: PlateRow[]; // in plate order: me first
  myId: string;
  dealerId: string | null;
  // Teams: the game's players (seat order). Null for per-player plates.
  teamsPlayers: string[] | null;
}): ScorePlate[] {
  const { rows, myId, dealerId, teamsPlayers } = input;
  if (!teamsPlayers) {
    return rows.map((m) => ({
      key: m.user_id,
      members: [{ userId: m.user_id, name: m.name, avatarUrl: m.avatar_url }],
      score: m.score,
      isMine: m.user_id === myId,
      hasDealer: dealerId === m.user_id,
      lastPoints: m.last_points,
      lastReason: m.last_reason,
      lastAwardedAt: m.last_awarded_at,
    }));
  }

  const myTeam = teamOfPosition(teamsPlayers, myId) ?? 1;
  const teams: (1 | 2)[] = myTeam === 1 ? [1, 2] : [2, 1];
  return teams.flatMap((team) => {
    const teamRows = rows.filter((m) => teamOfPosition(teamsPlayers, m.user_id) === team);
    if (teamRows.length === 0) return [];
    // Me first on my plate.
    teamRows.sort((a, b) => (a.user_id === myId ? -1 : b.user_id === myId ? 1 : 0));
    const latest = teamRows.reduce((best, m) => (timeOf(m.last_awarded_at) > timeOf(best.last_awarded_at) ? m : best));
    return [
      {
        key: `team-${team}`,
        members: teamRows.map((m) => ({ userId: m.user_id, name: m.name, avatarUrl: m.avatar_url })),
        score: Math.max(...teamRows.map((m) => m.score)),
        isMine: teamRows.some((m) => m.user_id === myId),
        hasDealer: teamRows.some((m) => m.user_id === dealerId),
        lastPoints: latest.last_points,
        lastReason: latest.last_reason,
        lastAwardedAt: latest.last_awarded_at,
        flashName: latest.last_awarded_at ? latest.name : undefined,
      },
    ];
  });
}
