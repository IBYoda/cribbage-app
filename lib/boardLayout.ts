// THE CRIBBAGE BOARD (PRD item 31, step 1b): the pure geometry the board strip
// (components/table/CribbageBoard.tsx) is drawn from, and where each peg goes.
// No React. Tested by scripts/test-phase3.ts.
//
// THE LAYOUT: a classic 3-lane board, laid out out-and-back. Every lane is two
// rows of 60 holes in twelve groups of five:
//
//   [s s]  1  2  3  4  5   6 ... 60 )   the outbound row, left to right
//    [g] 120 119 ...                61 )   the return row, right to left
//
// Position 0 is a lane's two start holes (one per peg, so two pegs at 0 never
// share a hole), 1-120 the holes, 121 the lane's game hole -- at the home end,
// beside hole 120, under the start holes. Lanes top to bottom: 0, 1, 2.
//
// The board is laid out for its actual size in px (the strip's width and
// height), not scaled from a fixed picture: the hole pitch comes from the
// width, the row spacing from the height, so a shorter strip (a short phone)
// only brings the rows closer together and never shrinks the pitch.

export const BOARD_LANES = 3;
export const HOLES_PER_ROW = 60;
export const GROUP = 5;
export const GAME_HOLE = 121;

// Horizontal spacing, in hole pitches (p): the extra gap between groups of
// five, and from the second start hole to hole 1 (a pitch plus a group gap).
export const GROUP_GAP = 0.4;
// Across a row: 2 start holes, then hole 1 one pitch and a group gap after
// the second, then 59 pitches and 11 group gaps to hole 60.
const ROW_PITCHES = 1 + (1 + GROUP_GAP) + (HOLES_PER_ROW - 1) + ((HOLES_PER_ROW / GROUP) - 1) * GROUP_GAP;
// Vertical spacing: the gap between two lanes, in row gaps (the space between
// a lane's two rows).
export const LANE_GAP = 1.9;
// The smallest peg radius, in px: a 9.8px peg (outline included), readable
// on a phone. It was 5.7px at 375px wide and 7.7px at 502px before this
// floor (pitch * 0.52).
export const PEG_MIN_R = 4.9;

export type Point = { x: number; y: number };

export type BoardGeometry = {
  width: number;
  height: number;
  // The wood rim's thickness, and the board's corner radius.
  rim: number;
  corner: number;
  // The distance between two hole centres in a group, and the extra space
  // between groups.
  pitch: number;
  groupGap: number;
  // x of the two start holes, of the game hole, and of hole 1 .. 60 (index
  // 0 .. 59) along a row.
  startX: readonly [number, number];
  gameX: number;
  columnX: readonly number[];
  // y of each lane's outbound and return rows.
  rows: readonly { out: number; back: number }[];
  holeR: number;
  pegR: number;
};

const clampNum = (n: number, lo: number, hi: number) => Math.min(Math.max(n, lo), hi);

// The board for a strip `width` x `height` px.
export function boardGeometry(width: number, height: number): BoardGeometry {
  const rim = clampNum(height * 0.05, 3, 6);
  const corner = clampNum(height * 0.12, 4, 12);
  const padX = 3.5;
  const left = rim + padX;
  const right = width - rim - padX;
  const pitch = Math.max(right - left, 0) / ROW_PITCHES;
  const groupGap = pitch * GROUP_GAP;
  const startX: [number, number] = [left, left + pitch];
  const gameX = left + pitch / 2;
  const hole1 = startX[1] + pitch + groupGap;
  const columnX = Array.from(
    { length: HOLES_PER_ROW },
    (_, i) => hole1 + i * pitch + Math.floor(i / GROUP) * groupGap
  );
  // Rows: out, back | lane gap | out, back | lane gap | out, back -- three
  // row gaps and two lane gaps, centred in the rim with room for a peg.
  const padY = Math.max(4, height * 0.06);
  const span = Math.max(height - 2 * (rim + padY), 0);
  const rowGap = span / (BOARD_LANES + (BOARD_LANES - 1) * LANE_GAP);
  const top = rim + padY;
  const rows = Array.from({ length: BOARD_LANES }, (_, lane) => {
    const out = top + lane * rowGap * (1 + LANE_GAP);
    return { out, back: out + rowGap };
  });
  const tight = Math.min(pitch, rowGap);
  // The peg: bigger than a hole, and never under PEG_MIN_R on a phone (it
  // may cover the neighbouring holes; it sits on top of the board). At most
  // what keeps it clear of the next lane's pegs and inside the board.
  const pegR = Math.min(
    Math.max(Math.min(pitch * 0.6, rowGap * 0.55), PEG_MIN_R),
    rowGap * 0.85,
    rim + padY - 0.5,
    rim + padX - 0.5
  );
  return {
    width,
    height,
    rim,
    corner,
    pitch,
    groupGap,
    startX,
    gameX,
    columnX,
    rows,
    holeR: tight * 0.3,
    pegR,
  };
}

// A score as a board position: 0 (start) .. 121 (the game hole). Anything
// past 121 is the game hole; anything below 0 (or not a number) the start.
export function clampScore(score: number): number {
  if (!Number.isFinite(score)) return 0;
  return clampNum(Math.floor(score), 0, GAME_HOLE);
}

// Which row and column a position is in: "start" / "game", or the row (out:
// 1-60 left to right; back: 61-120 right to left) and its column 0 .. 59.
export type HoleSpot =
  | { kind: "start" }
  | { kind: "game" }
  | { kind: "hole"; row: "out" | "back"; column: number };

export function holeSpot(score: number): HoleSpot {
  const s = clampScore(score);
  if (s === 0) return { kind: "start" };
  if (s === GAME_HOLE) return { kind: "game" };
  if (s <= HOLES_PER_ROW) return { kind: "hole", row: "out", column: s - 1 };
  return { kind: "hole", row: "back", column: 2 * HOLES_PER_ROW - s };
}

// Where a score's hole is, in a lane. startSlot picks which of the two start
// holes (0 or 1) position 0 uses -- each peg has its own.
export function holePosition(g: BoardGeometry, lane: number, score: number, startSlot: 0 | 1 = 0): Point {
  const row = g.rows[clampNum(lane, 0, BOARD_LANES - 1)];
  const spot = holeSpot(score);
  if (spot.kind === "start") return { x: g.startX[startSlot], y: row.out };
  if (spot.kind === "game") return { x: g.gameX, y: row.back };
  return { x: g.columnX[spot.column], y: spot.row === "out" ? row.out : row.back };
}

// Every hole on the board: per lane, the two start holes, 1-120 and the game
// hole (123 a lane).
export type BoardHole = Point & { lane: number; score: number };

export function boardHoles(g: BoardGeometry): BoardHole[] {
  const holes: BoardHole[] = [];
  for (let lane = 0; lane < BOARD_LANES; lane++) {
    holes.push({ lane, score: 0, ...holePosition(g, lane, 0, 0) });
    holes.push({ lane, score: 0, ...holePosition(g, lane, 0, 1) });
    for (let s = 1; s <= GAME_HOLE; s++) holes.push({ lane, score: s, ...holePosition(g, lane, s) });
  }
  return holes;
}

// A player's two pegs, as positions: [peg A, peg B]. Which is in front
// changes as they leapfrog; peg A uses start hole 0, peg B start hole 1.
export type PegPair = readonly [number, number];

// THE PEGS after a score change. The front peg is the score; the back peg the
// score before the last scoring:
//   * last award > 0: score - last award (exact, and survives a reload: both
//     are on the player's row);
//   * last award 0 ("hand: nothing") or none: the pegs don't move -- the back
//     peg stays where it was (prev), while the front still matches the score;
//   * otherwise (a page loaded after a 0 award, or no award at all yet): not
//     knowable here, so the back peg waits on the start hole.
// Then the leapfrog: the peg already on the new back position stays put and
// the other one moves to the front, so only one peg moves per award.
export function nextPegs(prev: PegPair | null, score: number, lastPoints: number | null): PegPair {
  const front = clampScore(score);
  let back: number;
  if (lastPoints !== null && lastPoints > 0) back = clampScore(score - lastPoints);
  else if (prev && Math.max(prev[0], prev[1]) === front) back = Math.min(prev[0], prev[1]);
  else back = 0;
  if (back > front) back = front;
  return leapfrog(prev, front, back);
}

// Which peg goes where: keep a peg that's already on one of the new places.
export function leapfrog(prev: PegPair | null, front: number, back: number): PegPair {
  if (!prev) return [back, front];
  const [a, b] = prev;
  if (a === back) return [back, front];
  if (b === back) return [front, back];
  if (a === front) return [front, back];
  if (b === front) return [back, front];
  return [back, front];
}

// Each player's lane, by the game's seat order (games.players, the same array
// on every screen): the first seat lane 0, the second lane 1, the third lane
// 2. Never "me first", so every screen shows the same colours.
export function laneOf(seatOrder: readonly string[], userId: string): number | null {
  const i = seatOrder.indexOf(userId);
  return i >= 0 && i < BOARD_LANES ? i : null;
}
