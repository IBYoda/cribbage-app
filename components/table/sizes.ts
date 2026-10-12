// Card sizes for the table, as Tailwind classes over the CSS variables set on
// .table-shell (app/globals.css). Fixed widths, never flex: a card keeps its
// size for the whole hand no matter how many cards share its row -- which is
// what stops the table from reflowing as cards are played.

// A full-size card in MY hand. Only my hand gets this size.
export const HAND_CARD = "w-[var(--hand-w)] shrink-0 aspect-[5/7]";

// Everything else on the table: played cards, the crib and starter piles,
// opponents' cards. 0.7 of a hand card.
export const SMALL_CARD = "w-[var(--small-w)] shrink-0 aspect-[5/7]";
