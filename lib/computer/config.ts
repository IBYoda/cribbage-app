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

export function isComputerLevel(value: unknown): value is ComputerLevel {
  return value === "easy" || value === "medium" || value === "hard";
}
