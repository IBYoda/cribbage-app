// THE DERBY'S TRACK (lib/customBoards.ts): one lap of the racetrack in
// public/boards/derby.webp, and where a player's horse is for a score. Pure,
// no React, no browser APIs. Tested by scripts/test-phase3.ts.
//
// All the track's numbers are in the art's own pixels (1525 x 427), so a score
// is at the same spot on the art at every strip size: the art is stretched to
// fill the strip, and a point just scales with it. Facing and tilt come from
// the stretched (screen) direction of travel; the horse itself isn't stretched.
//
// The track is a stadium, run counter-clockwise on screen: the near (bottom)
// straight left to right, up the right end, the far straight right to left,
// down the left end. The numbers were measured against the art's rails, so
// that every lane stays on the dirt.

import { GAME_HOLE, clampScore, type Point } from "@/lib/boardLayout";

export const DERBY_ART = { width: 1525, height: 427 };

// The centres of the two ends, and the centre line's radius.
const LEFT_X = 246;
const RIGHT_X = 1282;
const MID_Y = 201.5;
const RADIUS = 124.5;
const STRAIGHT = RIGHT_X - LEFT_X;

// The white finish line on the near straight, and the start mark just past it
// in the direction of travel. Score 0 is on the start mark, 121 on the finish.
export const DERBY_FINISH_X = 717;
export const DERBY_START_X = 792;
const START_TO_FINISH_GAP = DERBY_START_X - DERBY_FINISH_X;

// How far each lane is from the centre line, outermost first (positive is
// outward). Lane 0 is the outermost, as lane 0 is the top lane on the other
// boards, so the lane colours and rings are the same.
const LANE_OFFSETS: Record<2 | 3 | 4, readonly number[]> = {
  2: [13, -13],
  3: [26, 0, -26],
  4: [33, 11, -11, -33],
};

export type DerbyLaneCount = keyof typeof LANE_OFFSETS;

// How many lanes the track is laid out for: 4 on a 4-lane board (a 4-player
// Solo game), else enough for the lanes in use, never under 2. Going by the
// highest lane, not the head count, keeps a player in a real lane even if the
// player in a lower lane has left.
export function derbyLaneCount(lanes: 3 | 4, playerLanes: readonly number[]): DerbyLaneCount {
  if (lanes === 4) return 4;
  return Math.max(...playerLanes, 1) >= 2 ? 3 : 2;
}

export function derbyLaneOffset(laneCount: DerbyLaneCount, lane: number): number {
  const offsets = LANE_OFFSETS[laneCount];
  return offsets[Math.min(Math.max(lane, 0), offsets.length - 1)];
}

// One lap of a lane.
export function derbyLaneLength(offset: number): number {
  return 2 * STRAIGHT + 2 * Math.PI * (RADIUS + offset);
}

// How far along a lane a score is, from the near straight's left end, in art
// px. May be over a lap: derbyPointAt wraps it.
export function derbyDistance(offset: number, score: number): number {
  const lap = derbyLaneLength(offset) - START_TO_FINISH_GAP;
  return DERBY_START_X - LEFT_X + (clampScore(score) / GAME_HOLE) * lap;
}

// A point on a lane, in art px, and the direction of travel there.
export function derbyPointAt(offset: number, distance: number): Point & { dx: number; dy: number } {
  const radius = RADIUS + offset;
  const lap = derbyLaneLength(offset);
  const s = ((distance % lap) + lap) % lap;
  const end = Math.PI * radius;
  if (s < STRAIGHT) return { x: LEFT_X + s, y: MID_Y + radius, dx: 1, dy: 0 };
  if (s < STRAIGHT + end) {
    const p = (s - STRAIGHT) / radius;
    return { x: RIGHT_X + radius * Math.sin(p), y: MID_Y + radius * Math.cos(p), dx: Math.cos(p), dy: -Math.sin(p) };
  }
  if (s < 2 * STRAIGHT + end) return { x: RIGHT_X - (s - STRAIGHT - end), y: MID_Y - radius, dx: -1, dy: 0 };
  const p = (s - 2 * STRAIGHT - end) / radius;
  return { x: LEFT_X - radius * Math.sin(p), y: MID_Y - radius * Math.cos(p), dx: -Math.cos(p), dy: Math.sin(p) };
}

// A horse on the strip: where its hooves are (px), which way it faces (the art
// faces right: -1 flips it) and its tilt (degrees, clockwise).
export type DerbyPose = Point & { flip: 1 | -1; tilt: number };

export const DERBY_MAX_TILT = 26;

function poseAt(width: number, height: number, offset: number, distance: number): DerbyPose {
  const scaleX = width / DERBY_ART.width;
  const scaleY = height / DERBY_ART.height;
  const point = derbyPointAt(offset, distance);
  const dx = point.dx * scaleX;
  const dy = point.dy * scaleY;
  const flip = dx < 0 ? -1 : 1;
  // A flipped horse leans along the reversed vector: its nose still leads.
  const angle = (Math.atan2(dy * flip, dx * flip) * 180) / Math.PI;
  return {
    x: point.x * scaleX,
    y: point.y * scaleY,
    flip,
    tilt: Math.min(Math.max(angle, -DERBY_MAX_TILT), DERBY_MAX_TILT),
  };
}

export function derbyPose(width: number, height: number, laneCount: DerbyLaneCount, lane: number, score: number): DerbyPose {
  const offset = derbyLaneOffset(laneCount, lane);
  return poseAt(width, height, offset, derbyDistance(offset, score));
}

// The horse's scale: the art is HORSE_WIDTH wide, drawn at 2.4% of the strip's
// width, or 2.1% with four lanes.
const HORSE_WIDTH = 117;

export function derbyHorseScale(width: number, laneCount: DerbyLaneCount): number {
  return (width * (laneCount === 4 ? 0.021 : 0.024)) / HORSE_WIDTH;
}

// The art's ground point (between the hooves): what sits on the lane.
const HORSE_GROUND = { x: 55, y: 60 };

// A horse's CSS transform, for rest and for each frame of a slide alike.
export function derbyHorseTransform(pose: DerbyPose, scale: number): string {
  return (
    `translate(${pose.x}px, ${pose.y}px) rotate(${pose.tilt}deg) scale(${scale * pose.flip}, ${scale}) ` +
    `translate(${-HORSE_GROUND.x}px, ${-HORSE_GROUND.y}px)`
  );
}

// The longest slide. Anything longer, and any move backward (a New Game's
// reset to 0, which would otherwise run a whole lap the wrong way), snaps.
export const DERBY_MAX_SLIDE = 60;
const FRAME_ART_PX = 6;
const MAX_FRAMES = 120;

// A SLIDE: the poses along the lane from one score to the next, about one every
// 6 art px, each with its own facing and tilt so they change during the slide.
// null: it snaps.
export function derbySlideFrames(
  width: number,
  height: number,
  laneCount: DerbyLaneCount,
  lane: number,
  from: number,
  to: number
): DerbyPose[] | null {
  const start = clampScore(from);
  const end = clampScore(to);
  if (end <= start || end - start > DERBY_MAX_SLIDE) return null;
  const offset = derbyLaneOffset(laneCount, lane);
  const d0 = derbyDistance(offset, start);
  const d1 = derbyDistance(offset, end);
  const frames = Math.min(Math.max(Math.ceil((d1 - d0) / FRAME_ART_PX), 1), MAX_FRAMES);
  return Array.from({ length: frames + 1 }, (_, i) => poseAt(width, height, offset, d0 + ((d1 - d0) * i) / frames));
}
