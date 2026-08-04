import { isRedSuit, rankLabel, suitSymbol } from "@/lib/cards";

// Cards size themselves to whatever the parent flex row gives them, so a row
// of 6 fits a phone screen without horizontal scrolling. aspect-[5/7] keeps
// them card-shaped at any width.
const CARD_SHELL =
  "flex-1 min-w-0 aspect-[5/7] rounded-lg border shadow-sm select-none transition-transform";

export function FaceDownCard() {
  return (
    <div
      className={`${CARD_SHELL} border-red-900/40 bg-red-900`}
      // Diagonal stripes so a face-down card reads as "a card" at a glance
      // rather than a plain coloured rectangle.
      style={{
        backgroundImage:
          "repeating-linear-gradient(45deg, rgba(255,255,255,0.16) 0 4px, transparent 4px 8px)",
      }}
      aria-label="Face-down card"
    />
  );
}

export function PlayingCard({
  card,
  selected = false,
  onSelect,
}: {
  card: string;
  selected?: boolean;
  // Omitted when the hand isn't selectable (e.g. after discarding), which also
  // renders the card as a plain div rather than a button -- so there's nothing
  // to tab to or click when selection isn't allowed.
  onSelect?: () => void;
}) {
  const red = isRedSuit(card);
  const textColor = red ? "text-red-600" : "text-zinc-900";

  // Selected cards lift out of the row, matching the reference app. The ring
  // is there because lift alone is easy to miss on a small screen, and colour
  // alone wouldn't survive a colourblind user.
  const className = [
    CARD_SHELL,
    "flex flex-col justify-between border-zinc-300 bg-white p-1 dark:border-zinc-600",
    selected ? "-translate-y-4 ring-2 ring-blue-500" : "",
  ]
    .filter(Boolean)
    .join(" ");

  const content = (
    <>
      <span className={`text-sm font-bold leading-none sm:text-base ${textColor}`}>
        {rankLabel(card)}
      </span>
      <span className={`self-center text-xl leading-none sm:text-3xl ${textColor}`}>
        {suitSymbol(card)}
      </span>
      {/* Mirrored corner, like a real card. */}
      <span
        className={`self-end rotate-180 text-sm font-bold leading-none sm:text-base ${textColor}`}
      >
        {rankLabel(card)}
      </span>
    </>
  );

  const label = `${rankLabel(card)} ${suitSymbol(card)}`;

  if (!onSelect) {
    return (
      <div className={className} aria-label={label}>
        {content}
      </div>
    );
  }

  return (
    <button type="button" onClick={onSelect} aria-pressed={selected} aria-label={label} className={className}>
      {content}
    </button>
  );
}
