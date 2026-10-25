// THE COMPUTER OPPONENT'S LEVELS -- one place to tune them.
//
//   mistakeRate  per decision, the chance of ignoring the best option and
//                choosing uniformly at random among the legal options
//                (a "mistake" can still land on the best one by chance).
//   peek         may read the human's remaining hand -- during pegging ONLY.
//                Nothing else is ever visible to the brain (see brain.ts).
//
// Pure data, no React, no database: read by lib/computer/brain.ts.

export type ComputerLevel = "easy" | "medium" | "hard";

export type LevelSettings = {
  mistakeRate: number;
  peek: boolean;
};

export const LEVELS: Record<ComputerLevel, LevelSettings> = {
  easy: { mistakeRate: 0.9, peek: false },
  medium: { mistakeRate: 0.35, peek: false },
  hard: { mistakeRate: 0, peek: true },
};

// How many random (starter, two unknown cards) samples estimate the crib's
// value for each discard. The same samples are reused for all 15 discards,
// so the comparison between them is fair even with few samples.
export const CRIB_SAMPLES = 60;

// PACING: how long the computer "thinks" before each kind of action, as
// [min, max] milliseconds -- a random delay in that range, so its moves are
// visible and don't feel instant. Read by components/table/useComputerDriver.ts.
export const THINK_MS = {
  cut: [700, 1400], // draw a cut card, acknowledge the cut
  discard: [1500, 2800],
  play: [900, 1800],
  count: [2000, 3200], // show the crib / confirm a count
  ready: [800, 1500], // Next Hand, New Game (rematch)
} as const satisfies Record<string, readonly [number, number]>;

export function isComputerLevel(value: unknown): value is ComputerLevel {
  return value === "easy" || value === "medium" || value === "hard";
}
