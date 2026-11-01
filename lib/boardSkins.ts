// BOARD SKINS (PRD item 31, step 1b): the cribbage board's look, as data, so
// more boards can be added later (and maybe sold -- PRD item 31, parked)
// without touching components/table/CribbageBoard.tsx. Only one for now, and
// no picker: every table shows the classic wooden board.
//
// All our own art: the board is drawn in code from these colours (SVG
// gradients and a grain pattern), never from an image.

export type LaneSkin = {
  // The painted line along the lane, between its two rows.
  paint: string;
  // The peg: its colour, the lit side and the shaded side (a radial
  // gradient, so it reads as a round peg).
  peg: string;
  pegLight: string;
  pegDark: string;
};

export type BoardSkin = {
  id: string;
  name: string;
  wood: {
    // The board's face, top to bottom.
    top: string;
    bottom: string;
    // The grain lines over it.
    grain: string;
    grainOpacity: number;
  };
  rim: {
    // The board's outer edge, and the lit inner edge of the rim (a bevel).
    edge: string;
    highlight: string;
  };
  hole: {
    // A drilled hole: dark inside, a lighter lip.
    fill: string;
    edge: string;
  };
  // Lane 0 (the first seat), 1, 2.
  lanes: readonly [LaneSkin, LaneSkin, LaneSkin];
};

// The cheap wooden 3-lane board everyone buys: light wood, red, blue and
// green lanes.
export const CLASSIC_WOOD: BoardSkin = {
  id: "classic-wood",
  name: "Classic Wood",
  wood: {
    top: "#d9a86a",
    bottom: "#b57a40",
    grain: "#7a4a1f",
    grainOpacity: 0.28,
  },
  rim: {
    edge: "#5e3a17",
    highlight: "#f1cf9a",
  },
  hole: {
    fill: "#2a1708",
    edge: "#e9c48f",
  },
  lanes: [
    { paint: "#b3261e", peg: "#d32f2f", pegLight: "#ff8a80", pegDark: "#7f1010" },
    { paint: "#1f4fa3", peg: "#1e63d6", pegLight: "#8ab4ff", pegDark: "#0d2f73" },
    { paint: "#23733a", peg: "#2e9b4b", pegLight: "#8be0a0", pegDark: "#11532a" },
  ],
};

export const BOARD_SKINS: Record<string, BoardSkin> = {
  [CLASSIC_WOOD.id]: CLASSIC_WOOD,
};

export const DEFAULT_BOARD_SKIN = CLASSIC_WOOD;
