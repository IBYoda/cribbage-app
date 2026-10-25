// THE COMPUTER OPPONENT'S LEVELS -- one place to tune them.
//
//   mistakeRate  per decision, the chance of ignoring the best option and
//                choosing uniformly at random among the legal options
//                (a "mistake" can still land on the best one by chance).
//   peek         may read the human's remaining hand -- during pegging ONLY.
//                Hard only.
//   peekDiscard  may read the human's kept four-card hand when discarding
//                (so it discards after the human); Hard only. Nothing else
//                is ever visible to the brain (see brain.ts).
//   search       pegging by searching every line to the end of the hand
//                (and playing for the win near 121). A level without it
//                plays the best card one move ahead (with exact replies if
//                it peeks -- no level does that now -- else estimated from
//                the unseen cards).
//
// Every level plays to win; they differ in what they may read, how far they
// look and how often they err. Easy and Medium are the same fair player
// (no peeking); Easy errs 55% of the time, Medium never.
//
// Pure data, no React, no database: read by lib/computer/brain.ts.

export type ComputerLevel = "easy" | "medium" | "hard";

export type LevelSettings = {
  mistakeRate: number;
  peek: boolean;
  peekDiscard: boolean;
  search: boolean;
  // How many random (starter, two unknown cards) samples estimate the crib's
  // value for each discard (see CRIB_SAMPLES).
  cribSamples: number;
};

// How many random (starter, two unknown cards) samples estimate the crib's
// value for each discard, by default. The same samples are reused for all 15
// discards, so the comparison between them is fair even with few samples.
// Easy and Medium use this; Hard uses more (measured: see LEVELS).
export const CRIB_SAMPLES = 60;

export const LEVELS: Record<ComputerLevel, LevelSettings> = {
  // Easy: Medium with 55% of its decisions replaced by a random legal
  // choice. A learner.
  easy: { mistakeRate: 0.55, peek: false, peekDiscard: false, search: false, cribSamples: CRIB_SAMPLES },
  // Medium: a mistake-free fair player -- never reads the human's cards; the
  // best card one move ahead, estimated from the unseen cards; discards
  // from 60 crib samples.
  medium: { mistakeRate: 0, peek: false, peekDiscard: false, search: false, cribSamples: CRIB_SAMPLES },
  // Hard: 500 crib samples. Measured over 300 hands against a 3000-sample
  // reference: 60 agree 86.7%, 300 93.7%, 500 97.0%, 1000 97.3%, 3000 97.0%
  // (two 3000 runs differ on near-ties, so ~97% is the ceiling); 500 costs
  // about 6 ms per discard.
  hard: { mistakeRate: 0, peek: true, peekDiscard: true, search: true, cribSamples: 500 },
};

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

// HOW EACH LEVEL IS SHOWN (Start a Table's level picker): the computer's
// name, the level's label and a tagline. The name is also the computer
// account's nickname (docs/sql/computer-accounts-setup.sql).
export const LEVEL_INFO: Record<ComputerLevel, { name: string; label: string; tagline: string }> = {
  easy: { name: "Shortbus", label: "Easy", tagline: "Just Learning" },
  medium: { name: "Normie", label: "Medium", tagline: "Don't Suck!" },
  hard: { name: "God", label: "Hard", tagline: "Start Praying" },
};

export function isComputerLevel(value: unknown): value is ComputerLevel {
  return value === "easy" || value === "medium" || value === "hard";
}
