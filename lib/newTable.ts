// START A TABLE (app/tables/new/page.tsx): which options a host can pick, and
// the tables row it creates. Pure; tested by scripts/test-phase3.ts.

export type PlayerCount = 2 | 3 | 4;

// With 4 players: Teams (partners sit opposite and share one score) or Solo
// (everyone for themselves). The engine plays both
// (docs/sql/phase3-solo-verification.sql proves Solo end to end).
export type FourPlayerMode = "teams" | "solo";

// Team or Solo can be chosen only with 4 players (and 4 players never come
// with Self-Scoring, which is 2-player only).
export function fourPlayerModeOffered(maxPlayers: PlayerCount, isMuggins: boolean): boolean {
  return maxPlayers === 4 && !isMuggins;
}

// The row's options, as Start a Table sends them (with the code and creator).
// team_mode only for 4 players -- 2- and 3-player tables keep the database
// default, exactly as before.
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
    ...(input.maxPlayers === 4 ? { team_mode: input.fourPlayerMode } : {}),
  };
}
