import type { CSSProperties } from "react";
import { PlayingCard } from "@/components/PlayingCard";
import type { SeatGeometry } from "@/lib/tableLayout";

// THE SQUARE TABLE (PRD item 31; not on the live table yet): one player's
// played cards, lying in front of their seat. The run's cards overlap in play
// order, newest on top, and the whole row is turned to face the player
// (seatGeometry: you 0, left 90, across 180, right -90 degrees). A sideways
// row sits in a slot sized for the turned row, as SideSeat does for its
// cards, so it takes exactly the room it shows. Sizes are in .seat-played
// (app/globals.css).
//
// The slot keeps one card's room even with no cards, so the centre of the
// table doesn't jump when the first card lands.
export function SeatPlayedCards({
  cards,
  rotation,
  label,
  dimmed = false,
  scale = 1,
}: {
  // The run's cards for this seat, in play order (oldest first).
  cards: string[];
  rotation: SeatGeometry["rotation"];
  // For screen readers: "Elsa's played cards".
  label: string;
  // The run is finished (between runs): shown faded, as the shared row does.
  dimmed?: boolean;
  // Card size against my own played cards (1): the other players' played
  // cards are drawn a little smaller, as in the mockups.
  scale?: number;
}) {
  const sideways = rotation === 90 || rotation === -90;
  const style = {
    "--n": Math.max(cards.length, 1),
    "--spc-turn": `${rotation}deg`,
    "--spc-scale": scale,
  } as CSSProperties;

  return (
    <div
      className={`seat-played ${sideways ? "seat-played--side" : ""} ${dimmed ? "opacity-50" : ""}`}
      style={style}
      aria-label={label}
    >
      <div className="seat-played__row">
        {cards.map((card) => (
          <div key={card} className="seat-played__card">
            <PlayingCard card={card} sizing="w-full aspect-[5/7]" />
          </div>
        ))}
      </div>
    </div>
  );
}
