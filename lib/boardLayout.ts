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

// THE BOARD'S PATTERN: a board is a pattern (the track's shape) in a skin's
// colours (lib/boardSkins.ts). "straight": the out-and-back board above;
// "s": the S board below. Both have three lanes, positions 0 .. 121.
export type BoardPattern = "straight" | "s";

export const BOARD_PATTERNS: readonly BoardPattern[] = ["straight", "s"];

// THE S BOARD (our own drawing): one continuous lane per player, not out and
// back -- a start hole, holes 1-120 in groups of five, and a game hole. Drawn
// in "view units" on a board 1000 wide, then scaled to the strip.
//
// The track's centreline (YC the board's middle, x0 = 212.2 - R): the start
// strip, heading east inside the left hairpin; a small turn (radius R/2) up
// and back; the top row heading west; a big turn (radius R) round the start
// strip; the bottom row heading east, to E. That is the left half. Then a
// short steep S (a cubic) across the middle to E2, E rotated 180 degrees
// about the board's centre; then the left half backwards, rotated the same
// way, ending at the finish inside the right hairpin. The three lanes are
// that line moved -LS, 0 and +LS along its right-hand normal, so they are
// always LS apart. Holes go by distance along each lane.
export type SVariant = {
  id: "sflat" | "sflat2";
  // The board's height, the lane spacing, the big turn's radius and a hole's
  // radius (view units).
  H: number;
  LS: number;
  R: number;
  holeR: number;
};

// The normal strip (about 4.65:1) and a short phone's (about 5.6:1).
export const S_VARIANTS: Record<SVariant["id"], SVariant> = {
  sflat: { id: "sflat", H: 215, LS: 19, R: 61, holeR: 3.3 },
  sflat2: { id: "sflat2", H: 190, LS: 17.5, R: 56, holeR: 3.2 },
};

// Which one a strip uses: half way between the two strips' shapes.
const S_SHORT_ASPECT = 5.1;

export function sVariantFor(width: number, height: number): SVariant {
  return height > 0 && width / height >= S_SHORT_ASPECT ? S_VARIANTS.sflat2 : S_VARIANTS.sflat;
}

// Hole spacing along a lane, in units of U = laneLength / (T + 2M): the
// start hole at U, hole k at (q_k + M) U, the game hole at laneLength - U,
// where q_k counts one per hole plus GR per gap between groups of five.
const S_GR = 6 / 13.2;
const S_M = 2.4;
const S_T = HOLES_PER_ROW * 2 - 1 + 23 * S_GR;
// The centreline is sampled every S_STEP view units.
const S_STEP = 0.25;

export type STrackLane = {
  // The lane as a polyline (view units), and each point's distance along it.
  points: Point[];
  along: number[];
  length: number;
  // Positions 0 .. 121: where each hole is, and its distance along the lane.
  holes: Point[];
  holeAlong: number[];
};

export type STrack = {
  variant: SVariant;
  lanes: STrackLane[];
  // The board: the track's width plus (LS/2 + 14) each side, H tall.
  board: { x: number; y: number; width: number; height: number };
  // A plate every five holes on the middle lane, in the gap after hole 5k
  // (k = 1 .. 23): its centre, its angle along the lane (degrees) and number.
  plates: { x: number; y: number; angle: number; label: number }[];
  // A plate's half-sizes: along the lane and across it.
  plateRx: number;
  plateRy: number;
};

// The S centreline as a dense polyline (view units).
function sCenterline(v: SVariant): Point[] {
  const YC = v.H / 2;
  const R = v.R;
  // 212.2 rather than 211: the start strip's bare tip (before the start
  // hole) then clears the big turn's nearest lane by LS - 0.5 too.
  const x0 = 212.2 - R;
  const pts: Point[] = [];
  const push = (p: Point) => {
    const last = pts[pts.length - 1];
    if (!last || Math.hypot(p.x - last.x, p.y - last.y) > 1e-9) pts.push(p);
  };
  const line = (a: Point, b: Point) => {
    const n = Math.max(1, Math.ceil(Math.hypot(b.x - a.x, b.y - a.y) / S_STEP));
    for (let i = 0; i <= n; i++) push({ x: a.x + ((b.x - a.x) * i) / n, y: a.y + ((b.y - a.y) * i) / n });
  };
  const arc = (c: Point, r: number, fromDeg: number, toDeg: number) => {
    const a0 = (fromDeg * Math.PI) / 180;
    const a1 = (toDeg * Math.PI) / 180;
    const n = Math.max(1, Math.ceil((r * Math.abs(a1 - a0)) / S_STEP));
    for (let i = 0; i <= n; i++) {
      const a = a0 + ((a1 - a0) * i) / n;
      push({ x: c.x + r * Math.cos(a), y: c.y + r * Math.sin(a) });
    }
  };
  line({ x: x0, y: YC }, { x: 346, y: YC });
  arc({ x: 346, y: YC - R / 2 }, R / 2, 90, -90);
  line({ x: 346, y: YC - R }, { x: 165, y: YC - R });
  arc({ x: 165, y: YC }, R, -90, -270);
  line({ x: 165, y: YC + R }, { x: 330, y: YC + R });
  const left = pts.slice();
  const E = left[left.length - 1];
  const turn = (p: Point): Point => ({ x: 1000 - p.x, y: 2 * YC - p.y });
  const E2 = turn(E);
  const dx = 0.55 * (E2.x - E.x);
  const c1 = { x: E.x + dx, y: E.y };
  const c2 = { x: E2.x - dx, y: E2.y };
  const n = Math.ceil((2 * Math.hypot(E2.x - E.x, E2.y - E.y)) / S_STEP);
  for (let i = 0; i <= n; i++) {
    const t = i / n;
    const u = 1 - t;
    push({
      x: u * u * u * E.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * E2.x,
      y: u * u * u * E.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * E2.y,
    });
  }
  for (let i = left.length - 1; i >= 0; i--) push(turn(left[i]));
  return pts;
}

// A point at distance d along a polyline.
function pointAlong(points: Point[], along: number[], d: number): Point {
  let lo = 0;
  let hi = along.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (along[mid] <= d) lo = mid;
    else hi = mid;
  }
  const span = along[hi] - along[lo] || 1;
  const f = Math.min(Math.max((d - along[lo]) / span, 0), 1);
  return { x: points[lo].x + (points[hi].x - points[lo].x) * f, y: points[lo].y + (points[hi].y - points[lo].y) * f };
}

// The distance of position 0 .. 121 along a lane of this length.
export function sHoleDistance(length: number, score: number): number {
  const U = length / (S_T + 2 * S_M);
  const s = clampScore(score);
  if (s === 0) return U;
  if (s === GAME_HOLE) return length - U;
  const q = s - 1 + Math.floor((s - 1) / GROUP) * S_GR;
  return (q + S_M) * U;
}

const sTracks: Partial<Record<SVariant["id"], STrack>> = {};

// The S track for a variant, in view units (worked out once, then kept).
export function sTrack(v: SVariant): STrack {
  const kept = sTracks[v.id];
  if (kept) return kept;
  const centre = sCenterline(v);
  const lanes = [-v.LS, 0, v.LS].map((offset): STrackLane => {
    const points = centre.map((p, i) => {
      const a = centre[Math.max(i - 1, 0)];
      const b = centre[Math.min(i + 1, centre.length - 1)];
      const len = Math.hypot(b.x - a.x, b.y - a.y) || 1;
      // The right-hand normal (y down): (-ty, tx).
      return { x: p.x - ((b.y - a.y) / len) * offset, y: p.y + ((b.x - a.x) / len) * offset };
    });
    const along = [0];
    for (let i = 1; i < points.length; i++) {
      along.push(along[i - 1] + Math.hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y));
    }
    const length = along[along.length - 1];
    const holeAlong = Array.from({ length: GAME_HOLE + 1 }, (_, s) => sHoleDistance(length, s));
    return { points, along, length, holes: holeAlong.map((d) => pointAlong(points, along, d)), holeAlong };
  });
  const xs = lanes.flatMap((l) => l.points.map((p) => p.x));
  const pad = v.LS / 2 + 14;
  const left = Math.min(...xs) - pad;
  const board = { x: left, y: 0, width: Math.max(...xs) + pad - left, height: v.H };
  const mid = lanes[1];
  const U = mid.length / (S_T + 2 * S_M);
  const plates = Array.from({ length: 23 }, (_, i) => {
    const k = (i + 1) * GROUP;
    const d = (mid.holeAlong[k] + mid.holeAlong[k + 1]) / 2;
    const p = pointAlong(mid.points, mid.along, d);
    const a = pointAlong(mid.points, mid.along, d - 1);
    const b = pointAlong(mid.points, mid.along, d + 1);
    return { x: p.x, y: p.y, angle: (Math.atan2(b.y - a.y, b.x - a.x) * 180) / Math.PI, label: k };
  });
  const track: STrack = {
    variant: v,
    lanes,
    board,
    plates,
    // In the gap between two holes, clear of both; across, inside the ribbon.
    plateRx: ((1 + S_GR) * U) / 2 - v.holeR - 0.6,
    plateRy: (v.LS - 1.2) / 2 - 0.8,
  };
  sTracks[v.id] = track;
  return track;
}

export type SBoardGeometry = {
  kind: "s";
  width: number;
  height: number;
  variant: SVariant;
  // View units to px, and where the view's origin lands in the strip.
  scale: number;
  offsetX: number;
  offsetY: number;
  // The board, in px: as big as fits the strip at the track's own shape,
  // centred.
  board: { x: number; y: number; width: number; height: number };
  rim: number;
  corner: number;
  laneGap: number;
  ribbonWidth: number;
  holeR: number;
  pegR: number;
  // Each lane's line (px; every 2 view units) and its holes 0 .. 121 (px).
  lanes: { path: Point[]; holes: Point[] }[];
  plates: { x: number; y: number; angle: number; label: number }[];
  plateRx: number;
  plateRy: number;
  // A plate's number size (px); numbers show only when big enough to read.
  plateFont: number;
};

// The smallest readable plate number, in px.
export const S_PLATE_FONT_MIN = 6;

// The S board for a strip `width` x `height` px: the variant that matches
// the strip's shape, scaled to fit it whole (the same scale both ways, so the
// lanes stay evenly spaced), centred.
export function sBoardGeometry(width: number, height: number): SBoardGeometry {
  const v = sVariantFor(width, height);
  const track = sTrack(v);
  const scale = Math.max(Math.min(width / track.board.width, height / track.board.height), 0);
  const offsetX = (width - track.board.width * scale) / 2 - track.board.x * scale;
  const offsetY = (height - track.board.height * scale) / 2 - track.board.y * scale;
  const px = (p: Point): Point => ({ x: offsetX + p.x * scale, y: offsetY + p.y * scale });
  const boardH = track.board.height * scale;
  const holeR = v.holeR * scale;
  const every = Math.max(1, Math.round(2 / S_STEP));
  return {
    kind: "s",
    width,
    height,
    variant: v,
    scale,
    offsetX,
    offsetY,
    board: { ...px(track.board), width: track.board.width * scale, height: boardH },
    rim: clampNum(boardH * 0.05, 3, 6),
    corner: clampNum(boardH * 0.12, 4, 12),
    laneGap: v.LS * scale,
    ribbonWidth: (v.LS - 1.2) * scale,
    holeR,
    // As on the straight board: never under PEG_MIN_R.
    pegR: Math.max(holeR * 1.8, PEG_MIN_R),
    lanes: track.lanes.map((l) => ({
      path: l.points.filter((_, i) => i % every === 0 || i === l.points.length - 1).map(px),
      holes: l.holes.map(px),
    })),
    plates: track.plates.map((p) => ({ ...px(p), angle: p.angle, label: p.label })),
    plateRx: track.plateRx * scale,
    plateRy: track.plateRy * scale,
    plateFont: Math.min(track.plateRx, track.plateRy) * 1.3 * scale,
  };
}

// Where position 0 .. 121 is in a lane of the S board (one start hole: both
// pegs start on it).
export function sHolePosition(g: SBoardGeometry, lane: number, score: number): Point {
  return g.lanes[clampNum(lane, 0, BOARD_LANES - 1)].holes[clampScore(score)];
}

export type AnyBoardGeometry = BoardGeometry | SBoardGeometry;

export function isSBoard(g: AnyBoardGeometry): g is SBoardGeometry {
  return "kind" in g && g.kind === "s";
}

// Either board for a strip, by pattern.
export function boardGeometryFor(pattern: BoardPattern, width: number, height: number): AnyBoardGeometry {
  return pattern === "s" ? sBoardGeometry(width, height) : boardGeometry(width, height);
}

// A PEG'S SLIDE on the S board: the points along its lane from position
// `from` to position `to`, evenly spaced by distance along the lane (view
// units), so a peg moving through them goes round the turns -- forward for
// a score, backward for a correction -- never across the board. A point
// every 2 view units or less (the whole lane is ~1,000), so even a long
// slide never cuts a corner on the tightest turn.
export function sSlidePoints(v: SVariant, lane: number, from: number, to: number, maxFrames = 1200): Point[] {
  const l = sTrack(v).lanes[clampNum(lane, 0, BOARD_LANES - 1)];
  const d0 = l.holeAlong[clampScore(from)];
  const d1 = l.holeAlong[clampScore(to)];
  const n = Math.min(Math.max(Math.ceil(Math.abs(d1 - d0) / 2), 1), maxFrames);
  return Array.from({ length: n + 1 }, (_, i) => pointAlong(l.points, l.along, d0 + ((d1 - d0) * i) / n));
}

// The same in px for a board: the S board's slide, or null for the straight
// board, whose pegs slide in a straight line by their CSS transition
// (app/globals.css, .board-peg) exactly as before.
export function pegSlideFrames(g: AnyBoardGeometry, lane: number, from: number, to: number): Point[] | null {
  if (!isSBoard(g)) return null;
  return sSlidePoints(g.variant, lane, from, to).map((p) => ({ x: g.offsetX + p.x * g.scale, y: g.offsetY + p.y * g.scale }));
}

// A peg's place on either board (startSlot: which start hole on the straight
// board; the S board has one).
export function pegPosition(g: AnyBoardGeometry, lane: number, score: number, startSlot: 0 | 1): Point {
  return isSBoard(g) ? sHolePosition(g, lane, score) : holePosition(g, lane, score, startSlot);
}
