import type { ScorePlate } from "@/components/table/ScoreStrip";

// THE RESULT OF A WON GAME, AFTER A REJOIN. Scores live on the seat
// (table_members), and leave_table deletes the seat, so a player who leaves
// and comes back before New Game sits on a NEW seat with score 0. The result
// screen reads scores from the seats, so it would show that 0 -- "Walt wins!
// 0" -- on every screen. A seat joined after the won game was created can't
// hold that game's score, so the result hides it instead of showing it
// wrong. Tested by scripts/test-phase3.ts.

// Whether a seat's score belongs to the game: true unless the seat was
// joined strictly AFTER the game was created. Equal times count as the
// game's, and a missing or unreadable time never hides anything. A rematch
// is safe: its game is created after everyone already sits there.
export function scoreFromThisGame(joinedAt: string | null | undefined, gameCreatedAt: string | null | undefined): boolean {
  const joined = joinedAt ? Date.parse(joinedAt) : NaN;
  const created = gameCreatedAt ? Date.parse(gameCreatedAt) : NaN;
  if (!Number.isFinite(joined) || !Number.isFinite(created)) return true;
  return joined <= created;
}

// The plates with a rejoined player's score hidden (scoreHidden). A plate is
// hidden only when EVERY member's seat is new: a Teams plate shows the
// higher partner score, which a partner who stayed still holds.
export function hideRejoinedScores(plates: ScorePlate[], rejoined: ReadonlySet<string>): ScorePlate[] {
  if (rejoined.size === 0) return plates;
  return plates.map((p) =>
    p.members.length > 0 && p.members.every((m) => rejoined.has(m.userId)) ? { ...p, scoreHidden: true } : p
  );
}
