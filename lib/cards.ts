// Cards are 2-character codes matching what start_game_with_deal() stores:
// rank (A,2-9,T,J,Q,K) + suit (S,H,D,C). e.g. 'AS', 'TD', '7H', 'KC'.
//
// Pure helpers, no React -- later slices (pegging, hand scoring) need the same
// rank/suit parsing, so this lives apart from any component.

export const RANKS = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K"] as const;
export const SUITS = ["S", "H", "D", "C"] as const;

export type Rank = (typeof RANKS)[number];
export type Suit = (typeof SUITS)[number];

const SUIT_SYMBOLS: Record<string, string> = { S: "♠", H: "♥", D: "♦", C: "♣" };

export function rankOf(card: string) {
  return card.slice(0, 1);
}

export function suitOf(card: string) {
  return card.slice(1);
}

export function suitSymbol(card: string) {
  return SUIT_SYMBOLS[suitOf(card)] ?? "?";
}

export function isRedSuit(card: string) {
  const suit = suitOf(card);
  return suit === "H" || suit === "D";
}

// 'T' is stored as a single character so every card code is 2 chars, but it
// should read as "10" on screen.
export function rankLabel(card: string) {
  const rank = rankOf(card);
  return rank === "T" ? "10" : rank;
}

// Ascending by rank, then by suit so the order is stable and predictable.
export function sortHand(cards: string[]) {
  return [...cards].sort((a, b) => {
    const rankDiff = RANKS.indexOf(rankOf(a) as Rank) - RANKS.indexOf(rankOf(b) as Rank);
    if (rankDiff !== 0) return rankDiff;
    return SUITS.indexOf(suitOf(a) as Suit) - SUITS.indexOf(suitOf(b) as Suit);
  });
}
