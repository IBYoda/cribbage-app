// THE "19" SPLASH's phrases: one is picked at random each time a counted hand
// or crib scores 0 (see components/table/Splash.tsx). Edit freely -- add,
// remove or reword; the list just must not be empty.
export const ZERO_SPLASH_PHRASES = [
  "THAT'S A SHOT BITCH!",
  "DRINK UP SUCKA!",
  "SHOT!",
];

// The same, at a table against God (tables.computer_level === "hard"), when
// the human scores 0. Stored in capitals like the list above.
export const GOD_ZERO_SPLASH_PHRASES = [
  "THAT'S A SHOT MY CHILD",
  "DRINK UP MY CHILD",
  "SHOT! MY CHILD",
];

// What God's own 0 shows instead of a phrase: public/splashes/god-shot.webp.
export const GOD_ZERO_SPLASH_IMAGE = "/splashes/god-shot.webp";

// The computer level that is God.
export function isGodLevel(level: string | null | undefined): boolean {
  return level === "hard";
}

// The phrases to pick from.
export function zeroSplashPhrases(godTable: boolean): readonly string[] {
  return godTable ? GOD_ZERO_SPLASH_PHRASES : ZERO_SPLASH_PHRASES;
}

// What a 0 shows: God's own 0 is the image, with no phrase and no sub line;
// everyone else's is a phrase. Only a God table ever shows the image.
export function zeroSplashKind(godTable: boolean, humanScored: boolean): "phrase" | "image" {
  return godTable && !humanScored ? "image" : "phrase";
}
