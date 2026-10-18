// PEGGING, the pure part: which run is on the table, and who said Go in it.
// Moved here unchanged from components/PlayArea.tsx (which re-exports them),
// so scripts/test-phase3.ts can check them for 2, 3 and 4 players without
// React. Used by the play area and the table page (the Go labels by seat).

export type PlayEvent = {
  seq: number;
  segment: number;
  user_id: string;
  kind: "play" | "go";
  card: string | null;
  count_after: number;
};

// WHICH RUN IS ON THE TABLE -- shared by the play area (which draws it) and
// the table page (which puts each player's "Go" label by their seat).
//
// The current run once it has a card; between runs, the run that just
// finished; in the hold after the last card, the newest run with any plays.
export function displayedRun(
  plays: PlayEvent[],
  playSegment: number,
  handOver: boolean
): { events: PlayEvent[]; finished: boolean } {
  const currentCards = plays.filter((p) => p.segment === playSegment && p.kind === "play");
  const finished = currentCards.length === 0 || handOver;
  const lastFinishedSegment = Math.max(
    -1,
    ...plays.filter((p) => p.segment < playSegment).map((p) => p.segment)
  );
  // At the end of the hand the last run may be the current segment (the last
  // card didn't reset the count) or the one before it (it made 31): either
  // way, the newest segment that has any plays.
  const lastSegmentWithPlays = Math.max(-1, ...plays.map((p) => p.segment));
  const segment = handOver ? lastSegmentWithPlays : finished ? lastFinishedSegment : playSegment;
  return { events: plays.filter((p) => p.segment === segment), finished };
}

// WHO SAID GO in the run on the table: the user ids of its go events.
//
// A go event's user_id is the player who could NOT play (play_card logs one
// for the opponent who can't answer, while they still hold cards) -- exactly
// "who said go". A player stuck for several plays in a row gets a go event
// each time; the Set makes that one label. The player who plays the last card
// of a deadlocked run never gets one, which matches the rules: they peg the
// point, they don't say go. DISPLAY ONLY -- the go POINT is awarded inside
// play_card from control flow, never from these rows.
export function goSayers(events: PlayEvent[]): Set<string> {
  return new Set(events.filter((p) => p.kind === "go").map((p) => p.user_id));
}
