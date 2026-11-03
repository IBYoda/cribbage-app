// THE SQUARE TABLE (PRD item 31, docs/mockups/table-redesign/): the pure
// rules its layout is built on. Everyone sits around a square table facing
// the centre, each player's played cards lie in front of them, turned to face
// them, and the dealer's crib and deck sit beside the dealer's hand. Tested
// by scripts/test-phase3.ts. The square layout is the default for 2-, 3- and
// 4-player tables (Teams and Solo), self-scoring (Muggins) ones included --
// they are 2-player only (chooseTableLayout, at the end).

import { laneOf } from "@/lib/boardLayout";
import { countingOrder } from "@/lib/countingN";
import { displayedRun, type PlayEvent } from "@/lib/pegging";
import { seatPlaces, teamOfPosition } from "@/lib/phase3";

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

// WHERE A PLAYER SITS on my screen (seatsOnScreen), or null if they aren't
// at the table.
export function seatPositionOf(players: string[], myId: string, userId: string): SeatPosition | null {
  const onScreen = seatsOnScreen(players, myId);
  return SEAT_POSITIONS.find((p) => onScreen[p] === userId) ?? null;
}

// THE COUNTING PHASE on the square table: which hands are face-up at their
// seats. Each hand turns over in place when its count comes up and stays
// up; the order is the server's (countingOrder: clockwise from the dealer's
// left, the dealer's own hand last), so with N players step k is the hand
// of the (k+1)-th player after the dealer. The crib turns over at the
// dealer's seat at step N, after every hand, and stays up through 'done'.
export function countingReveals(input: {
  players: string[];
  dealerId: string;
  step: number;
  done: boolean;
}): { hands: Record<string, boolean>; crib: boolean } {
  const { players, dealerId, step, done } = input;
  const order = countingOrder(players, dealerId);
  const hands: Record<string, boolean> = {};
  order.forEach((id, k) => {
    hands[id] = done || step >= k;
  });
  return { hands, crib: done || step >= players.length };
}

// EACH PLAYER'S BOARD LANE (CribbageBoard) and so their avatar ring colour,
// from the game's own players list (seat order), the same on every screen --
// never "me first":
//   * 2 and 3 players: by seat (laneOf) -- the first seat lane 0 (red), the
//     second lane 1 (blue), the third lane 2 (green);
//   * 4-player Teams: by team (teamOfPosition: seats 1 and 3 against 2 and
//     4) -- team 1 lane 0 (red), team 2 lane 1 (blue), both partners alike,
//     each team pegging its team score; the third lane stays drawn but empty;
//   * 4-player Solo: by seat, on the 4-lane board (boardLanesFor) -- the
//     fourth seat lane 3.
// null: not a player in that list.
export function laneForPlayer(input: { players: readonly string[]; userId: string; teams: boolean }): number | null {
  const { players, userId, teams } = input;
  if (teams && players.length === 4) {
    const team = teamOfPosition([...players], userId);
    return team === null ? null : team - 1;
  }
  return laneOf(players, userId, boardLanesFor(players.length, teams));
}

// How many lanes a game's board has: 4 for a 4-player Solo game (a lane each),
// else 3 (2 and 3 players, and 4-player Teams: a lane per team).
export function boardLanesFor(playerCount: number, teams: boolean): 3 | 4 {
  return playerCount === 4 && !teams ? 4 : 3;
}

// THE SQUARE TABLE'S SEATS AROUND THE MIDDLE, keyed on whether the top
// (across) seat is filled alongside the side seats (4 players):
//   * no top seat (3 players): the side players' name tags along the top of
//     the middle -- just under the header, as the 3-player layout has them;
//     the side columns stop above my played cards; the across dealer's piles
//     (2 players only) hang below their hand as in mockup 03;
//   * a top seat (4 players): the top player's hand row takes the row under
//     the header, so the side tags sit under that row, just above each side
//     column (mockups 04 and 05); the top dealer's piles sit level with
//     their hand, as big as their card backs, so nothing hangs into the tags;
//     and each side column runs the middle's full height (beside my played
//     cards), which keeps the side cards at the 3-player size.
export type RingLayout = {
  hasTop: boolean;
  sideTags: "under-header" | "under-top-row";
  sideColumns: "above-mine" | "full-height";
  acrossPiles: "hanging" | "level";
};

export function ringLayout(input: { top: boolean; sides: boolean }): RingLayout {
  const fourSeats = input.top && input.sides;
  return {
    hasTop: input.top,
    sideTags: fourSeats ? "under-top-row" : "under-header",
    sideColumns: fourSeats ? "full-height" : "above-mine",
    acrossPiles: fourSeats ? "level" : "hanging",
  };
}

// THE STARTER IN COUNTING (and on a final board's counting picture): where
// the cut starter sits, from the DEALER's seat on my screen -- not the player
// count, so any table size reads it the same way.
//   * "above-hand": I deal -- just above my hand, centred, right of my crib's
//     fan, upright: crib, starter and hand together to count.
//   * "middle": anyone else deals (across, left or right) -- the middle of
//     the table, upright (readable by me), above the counting text.
//   * "deck": not counting (or no dealer known) -- on the dealer's deck.
// The deck then shows nothing where the starter was.
export type StarterPlace = "deck" | "above-hand" | "middle";

export function countingStarterPlace(dealer: SeatPosition | null, counting: boolean): StarterPlace {
  if (!counting || !dealer) return "deck";
  return dealer === "bottom" ? "above-hand" : "middle";
}

// WHICH LAYOUT A TABLE SHOWS. The square layout covers a dealt hand (the
// discard, pegging and its hold, counting through Next Hand) and a won
// game's final board; everything else is the classic table: the waiting
// room, the cut for the deal and a game that ended any other way.
//   * 2 and 3 players, 4 players (Teams, and Solo on the 4-lane board), and
//     2-player self-scoring (Muggins) tables (no board: the self-scoring
//     banner in its place): square by default;
//     ?layout=classic on the page's URL gives the classic table
//     (?layout=square, a missing or any other value is the default). URL
//     only, nothing saved.
export type TableLayoutChoice = "square" | "classic";

export type TableScreen = "waiting-room" | "cut" | "discard" | "pegging" | "counting" | "won" | "ended" | "other";

const SQUARE_SCREENS: ReadonlySet<TableScreen> = new Set(["discard", "pegging", "counting", "won"]);

// The table as a whole uses the square layout (for the screens it covers).
export function isSquareTable(input: {
  layoutParam: string | null;
  playerCount: number;
  isMuggins: boolean;
  // A 4-player table in team_mode 'teams'.
  teams?: boolean;
}): boolean {
  // Self-scoring (Muggins) tables are 2-player only: the 2-player square
  // layout, with the self-scoring banner in the board's place.
  if (input.isMuggins) return input.playerCount === 2 && input.layoutParam !== "classic";
  // 4 players: Teams and Solo alike (Solo on the 4-lane board).
  const squareSize = input.playerCount === 2 || input.playerCount === 3 || input.playerCount === 4;
  return squareSize && input.layoutParam !== "classic";
}

export function chooseTableLayout(input: {
  layoutParam: string | null;
  playerCount: number;
  isMuggins: boolean;
  teams?: boolean;
  screen: TableScreen;
}): TableLayoutChoice {
  return isSquareTable(input) && SQUARE_SCREENS.has(input.screen) ? "square" : "classic";
}
