import { isRedSuit, rankLabel, suitSymbol } from "@/lib/cards";

// Appearance, independent of size.
const CARD_LOOK = "rounded-lg border shadow-sm select-none transition-transform";

// Default sizing: cards size themselves to whatever the parent flex row gives
// them, so a row of 6 fits a phone screen without horizontal scrolling.
// aspect-[5/7] keeps them card-shaped at any width. Overridable via `sizing`
// because the flip card below needs its faces to fill an absolute container
// instead of flexing within a row.
const DEFAULT_SIZING = "flex-1 min-w-0 aspect-[5/7]";

export function FaceDownCard({ sizing = DEFAULT_SIZING }: { sizing?: string }) {
  return (
    <div
      className={`${sizing} ${CARD_LOOK} border-red-900/40 bg-red-900`}
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
  sizing = DEFAULT_SIZING,
}: {
  card: string;
  selected?: boolean;
  // Omitted when the hand isn't selectable (e.g. after discarding), which also
  // renders the card as a plain div rather than a button -- so there's nothing
  // to tab to or click when selection isn't allowed.
  onSelect?: () => void;
  sizing?: string;
}) {
  const red = isRedSuit(card);
  const textColor = red ? "text-red-600" : "text-zinc-900";

  // Selected cards lift out of the row, matching the reference app. The ring
  // is there because lift alone is easy to miss on a small screen, and colour
  // alone wouldn't survive a colourblind user.
  const className = [
    sizing,
    CARD_LOOK,
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

// A card that physically turns over. Used for the cut-for-deal reveal, where
// the value is already decided server-side -- this is presentation only, never
// a draw.
//
// Built with a real 3D rotation rather than a crossfade because a flip is the
// gesture people actually associate with turning a card, and a fade would read
// as "data appeared" rather than "a card was turned".
export function FlipCard({
  card,
  revealed,
  onFlip,
  label,
}: {
  card: string;
  revealed: boolean;
  // Omitted for the opponent's card -- it isn't yours to turn over.
  onFlip?: () => void;
  label: string;
}) {
  const inner = (
    <div
      className="relative h-full w-full transition-transform duration-500"
      style={{
        transformStyle: "preserve-3d",
        transform: revealed ? "rotateY(180deg)" : "none",
      }}
    >
      {/* Back: what you see before the flip. */}
      <div className="absolute inset-0 flex" style={{ backfaceVisibility: "hidden" }}>
        <FaceDownCard sizing="h-full w-full" />
      </div>
      {/* Front: pre-rotated so it lands face-up at the end of the turn. */}
      <div
        className="absolute inset-0 flex"
        style={{ backfaceVisibility: "hidden", transform: "rotateY(180deg)" }}
      >
        <PlayingCard card={card} sizing="h-full w-full" />
      </div>
    </div>
  );

  // perspective on the wrapper is what makes the rotation read as depth rather
  // than a flat horizontal squash.
  const wrapperStyle = { perspective: "900px" };
  const wrapperClass = "aspect-[5/7] w-24";

  if (onFlip && !revealed) {
    return (
      <button
        type="button"
        onClick={onFlip}
        aria-label={`Turn over ${label}`}
        className={`${wrapperClass} rounded-lg ring-offset-2 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500`}
        style={wrapperStyle}
      >
        {inner}
      </button>
    );
  }

  return (
    <div className={wrapperClass} style={wrapperStyle} aria-label={label}>
      {inner}
    </div>
  );
}
