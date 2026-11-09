// THE COMPUTER OPPONENT'S LEVELS -- one place to tune them.
//
//   mistakeRate  per decision, the chance of ignoring the best option and
//                choosing uniformly at random among the legal options
//                (a "mistake" can still land on the best one by chance).
//   peek         may read the human's remaining hand -- during pegging ONLY.
//                Hard (God) only.
//   peekDiscard  may read the human's kept four-card hand when discarding
//                (so it discards after the human); Hard (God) only. Nothing
//                else is ever visible to the brain (see brain.ts).
//   search       pegging by searching every line to the end of the hand
//                (and playing for the win near 121). A level without it
//                plays the best card one move ahead (with exact replies if
//                it peeks -- no level does that now -- else estimated from
//                the unseen cards).
//
// THE LADDER, easiest first (the level value is the database's
// tables.computer_level / computer_accounts.level; the name is the
// computer's nickname):
//   easy    Shortbus  errs 55% of the time
//   casual  Normie    errs 25% of the time
//   medium  Rainman   never errs
//   hard    God       never errs, reads the human's cards, searches
// Every level plays to win; they differ in what they may read, how far they
// look and how often they err. Easy, Casual and Medium are the same fair
// player (no peeking), differing only in mistakeRate. The level values are
// internal and not in difficulty order by name: 'medium' was the second of
// three levels before Casual was added below it, and it keeps its value so
// no stored row changes.
//
// Pure data, no React, no database: read by lib/computer/brain.ts.

export type ComputerLevel = "easy" | "casual" | "medium" | "hard";

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
// Easy, Casual and Medium use this; Hard uses more (measured: see LEVELS).
export const CRIB_SAMPLES = 60;

export const LEVELS: Record<ComputerLevel, LevelSettings> = {
  // Easy (Shortbus): Medium with 55% of its decisions replaced by a random
  // legal choice. A learner.
  easy: { mistakeRate: 0.55, peek: false, peekDiscard: false, search: false, cribSamples: CRIB_SAMPLES },
  // Casual (Normie): Medium with 25% of its decisions replaced by a random
  // legal choice. Between Shortbus and Rainman (scripts/sim-computer.ts).
  casual: { mistakeRate: 0.25, peek: false, peekDiscard: false, search: false, cribSamples: CRIB_SAMPLES },
  // Medium (Rainman): a mistake-free fair player -- never reads the human's
  // cards; the best card one move ahead, estimated from the unseen cards;
  // discards from 60 crib samples.
  medium: { mistakeRate: 0, peek: false, peekDiscard: false, search: false, cribSamples: CRIB_SAMPLES },
  // Hard (God): 500 crib samples. Measured over 300 hands against a 3000-sample
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

// HOW EACH LEVEL IS SHOWN (the single-player screen's opponent chooser, and
// Admin's computer tag): the computer's name, the level's label and a
// tagline. The name is also the computer account's nickname
// (docs/sql/computer-accounts-setup.sql). Edit names, labels and taglines
// here only.
export const LEVEL_INFO: Record<ComputerLevel, { name: string; label: string; tagline: string }> = {
  easy: { name: "Shortbus", label: "Easy", tagline: "Just Learning" },
  casual: { name: "Normie", label: "Medium", tagline: "Plays like a regular person. Mostly." },
  medium: { name: "Rainman", label: "Hard", tagline: "Never misses. Never forgets." },
  hard: { name: "God", label: "Pray", tagline: "Start Praying" },
};

// The chooser's order, easiest first, and the level it starts on.
export const COMPUTER_LEVEL_ORDER: readonly ComputerLevel[] = ["easy", "casual", "medium", "hard"];
export const DEFAULT_COMPUTER_LEVEL: ComputerLevel = "casual";

export function isComputerLevel(value: unknown): value is ComputerLevel {
  return value === "easy" || value === "casual" || value === "medium" || value === "hard";
}

// A computer table's tag, for Admin: the computer's name, or the raw value
// if it is not a level this build knows.
export function computerLevelName(level: string): string {
  return isComputerLevel(level) ? LEVEL_INFO[level].name : level;
}
