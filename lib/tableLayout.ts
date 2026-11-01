// THE SQUARE TABLE (PRD item 31, docs/mockups/table-redesign/): the pure
// rules its layout is built on. Everyone sits around a square table facing
// the centre, each player's played cards lie in front of them, turned to face
// them, and the dealer's crib and deck sit beside the dealer's hand. Tested
// by scripts/test-phase3.ts. Nothing here touches the live table yet.

import { displayedRun, type PlayEvent } from "@/lib/pegging";
import { seatPlaces } from "@/lib/phase3";

// Where a seat is on MY screen: me at the bottom, then clockwise -- the next
// player on my left, the one across at the top, the last on my right.
export type SeatPosition = "bottom" | "left" | "top" | "right";

export const SEAT_POSITIONS: readonly SeatPosition[] = ["bottom", "left", "top", "right"];

// An edge of the seat's own area on screen, for its crib and deck.
export type ScreenSide = "top" | "right" | "bottom" | "left";

export type SeatGeometry = {
  // How far that seat's played cards are turned (degrees, clockwise), so they
  // face the player sitting there.
  rotation: 0 | 90 | 180 | -90;
  // Where the dealer's piles go when this seat deals. From the player's own
  // point of view the crib is on the left of their hand and the deck (the
  // starter, once cut) on the right; these are those places on MY screen.
  crib: ScreenSide;
  deck: ScreenSide;
};

const GEOMETRY: Record<SeatPosition, SeatGeometry> = {
  bottom: { rotation: 0, crib: "left", deck: "right" },
  left: { rotation: 90, crib: "top", deck: "bottom" },
  top: { rotation: 180, crib: "right", deck: "left" },
  right: { rotation: -90, crib: "bottom", deck: "top" },
};

export function seatGeometry(position: SeatPosition): SeatGeometry {
  return GEOMETRY[position];
}

// Who sits where on my screen, from games.players (seat order, clockwise).
// The bottom is me -- or nobody, for a viewer who isn't a player. The others
// follow seatPlaces (lib/phase3.ts): 2 players, the other across the top; 3,
// left and right; 4, left, top and right.
export function seatsOnScreen(players: string[], myId: string): Record<SeatPosition, string | null> {
  const places = seatPlaces(players, myId);
  return {
    bottom: players.includes(myId) ? myId : null,
    left: places.left,
    top: places.top,
    right: places.right,
  };
}

export type SeatPlayed = {
  userId: string | null;
  // That player's cards in the run on show, in play order (oldest first).
  cards: string[];
};

// EACH SEAT'S PLAYED CARDS, for the run on show: the same run the shared play
// area shows (displayedRun) -- the current one; between runs, the run that
// just finished; in the hold after the last card (or on the final board),
// the newest run with any cards. Earlier runs are not shown. Gos are not
// cards, so they're left out (the "Go" label marks them).
//
// finished: the run on show is over (between runs, the hold, the final
// board) -- the table dims it between runs, as the shared row does.
export function playedBySeat(input: {
  plays: PlayEvent[];
  playSegment: number;
  // The hold after the last card, or the final board: show the newest run.
  handOver: boolean;
  players: string[];
  myId: string;
}): { seats: Record<SeatPosition, SeatPlayed>; finished: boolean } {
  const { events, finished } = displayedRun(input.plays, input.playSegment, input.handOver);
  const ordered = events.filter((p) => p.kind === "play" && p.card).sort((a, b) => a.seq - b.seq);
  const onScreen = seatsOnScreen(input.players, input.myId);

  const seat = (userId: string | null): SeatPlayed => ({
    userId,
    cards: userId ? ordered.filter((p) => p.user_id === userId).map((p) => p.card!) : [],
  });

  return {
    seats: {
      bottom: seat(onScreen.bottom),
      left: seat(onScreen.left),
      top: seat(onScreen.top),
      right: seat(onScreen.right),
    },
    finished,
  };
}
