import { isRedSuit, rankLabel, suitSymbol } from "@/lib/cards";

// Cards size themselves to whatever the parent flex row gives them, so a row
// of 6 fits a phone screen without horizontal scrolling. aspect-[5/7] keeps
// them card-shaped at any width.
const SHARED = "flex-1 min-w-0 aspect-[5/7] rounded-lg border shadow-sm select-none";

export function FaceDownCard() {
  return (
    <div
      className={`${SHARED} border-red-900/40 bg-red-900`}
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

export function PlayingCard({ card }: { card: string }) {
  const red = isRedSuit(card);

  return (
    <div
      className={`${SHARED} flex flex-col justify-between border-zinc-300 bg-white p-1 dark:border-zinc-600`}
      aria-label={`${rankLabel(card)} ${suitSymbol(card)}`}
    >
      <span
        className={`text-sm font-bold leading-none sm:text-base ${
          red ? "text-red-600" : "text-zinc-900"
        }`}
      >
        {rankLabel(card)}
      </span>
      <span
        className={`self-center text-xl leading-none sm:text-3xl ${
          red ? "text-red-600" : "text-zinc-900"
        }`}
      >
        {suitSymbol(card)}
      </span>
      {/* Mirrored corner, like a real card -- also keeps the rank readable
          when cards are overlapped in a later slice. */}
      <span
        className={`self-end text-sm font-bold leading-none rotate-180 sm:text-base ${
          red ? "text-red-600" : "text-zinc-900"
        }`}
      >
        {rankLabel(card)}
      </span>
    </div>
  );
}
