// START A TABLE (app/tables/new/page.tsx): which options a host can pick, and
// the tables row it creates. Pure; tested by scripts/test-phase3.ts.

export type PlayerCount = 2 | 3 | 4;

// With 4 players: Teams (partners sit opposite and share one score) or Solo
// (everyone for themselves). The engine plays both
// (docs/sql/phase3-solo-verification.sql proves Solo end to end).
export type FourPlayerMode = "teams" | "solo";

// Team or Solo can be chosen only with 4 players, and never with
// Self-Scoring: a Self-Scoring table has no Team/Solo at all, just a shared
// deck (2, 3 or 4 players).
export function fourPlayerModeOffered(maxPlayers: PlayerCount, isMuggins: boolean): boolean {
  return maxPlayers === 4 && !isMuggins;
}

// WHAT START A TABLE SHOWS for the current picks: Self-Scoring and every
// player count can be picked whatever the other choice is (nothing is
// greyed out between them); the Team/Solo pair is shown with Regular play
// only -- greyed out unless 4 players (fourPlayerModeOffered) -- and not at
// all with Self-Scoring.
export function startTableOptions(
  maxPlayers: PlayerCount,
  isMuggins: boolean
): { mugginsOffered: boolean; playerCounts: PlayerCount[]; fourPlayerModeShown: boolean; fourPlayerModeOffered: boolean } {
  return {
    mugginsOffered: true,
    playerCounts: [2, 3, 4],
    fourPlayerModeShown: !isMuggins,
    fourPlayerModeOffered: fourPlayerModeOffered(maxPlayers, isMuggins),
  };
}

// The row's options, as Start a Table sends them (with the code and creator).
// team_mode only for 4 players -- 2- and 3-player tables keep the database
// default, exactly as before. SELF-SCORING with 3 or 4 players sends 'solo'
// whatever the (hidden) Team/Solo choice says: the database requires it for
// 4 (tables_muggins_no_teams, docs/sql/phase3-muggins-multiplayer.sql), and
// 'solo' keeps award_points and the leaderboard snapshot off their Teams
// branch. 2-player Self-Scoring is sent exactly as before.
export function newTableFields(input: {
  isPublic: boolean;
  isMuggins: boolean;
  maxPlayers: PlayerCount;
  fourPlayerMode: FourPlayerMode;
}): { is_public: boolean; is_muggins: boolean; max_players: PlayerCount; team_mode?: FourPlayerMode } {
  return {
    is_public: input.isPublic,
    is_muggins: input.isMuggins,
    max_players: input.maxPlayers,
    ...(input.isMuggins
      ? input.maxPlayers === 2
        ? {}
        : { team_mode: "solo" as const }
      : input.maxPlayers === 4
        ? { team_mode: input.fourPlayerMode }
        : {}),
  };
}
