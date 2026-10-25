// THE COMPUTER OPPONENT'S LEVELS -- one place to tune them.
//
//   mistakeRate  per decision, the chance of ignoring the best option and
//                choosing uniformly at random among the legal options
//                (a "mistake" can still land on the best one by chance).
//   peek         may read the human's remaining hand -- during pegging ONLY.
//                Nothing else is ever visible to the brain (see brain.ts).
//   style        "normal": play to win (with mistakeRate). "dumb": play to
//                lose on purpose -- discards its worst-valued cards (and
//                always gives the opponent's crib its 5s), leads 5s, avoids
//                scoring in pegging and gives the opponent the best reply
//                (see brain.ts).
//
// Pure data, no React, no database: read by lib/computer/brain.ts.

export type ComputerLevel = "easy" | "medium" | "hard";

export type LevelSettings = {
  mistakeRate: number;
  peek: boolean;
  style: "normal" | "dumb";
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
  easy: { mistakeRate: 0, peek: false, style: "dumb", cribSamples: CRIB_SAMPLES },
  medium: { mistakeRate: 0.35, peek: false, style: "normal", cribSamples: CRIB_SAMPLES },
  // Hard: 500 crib samples. Measured over 300 hands against a 3000-sample
  // reference: 60 agree 86.7%, 300 93.7%, 500 97.0%, 1000 97.3%, 3000 97.0%
  // (two 3000 runs differ on near-ties, so ~97% is the ceiling); 500 costs
  // about 6 ms per discard.
  hard: { mistakeRate: 0, peek: true, style: "normal", cribSamples: 500 },
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
