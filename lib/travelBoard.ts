import { lossTier } from "./resultScores";

// THE TRAVEL BOARD (app/travel-board): a cribbage board for people playing
// face to face with a real deck. Scorekeeping only, in this browser only: no
// database, nothing sent anywhere. Everything the screen can do is a pure
// step here, so the rules are tested without React (scripts/test-phase3.ts).
//
// Four plates always exist; the player count (2, 3 or 4) says how many show.
// A hidden plate keeps its name and score, in case the count goes back up.
// Every OK is one step of history: Undo and Redo walk through them, and a new
// OK clears Redo. A plate at 121 has won: the peg stops there and no points
// can be added until Undo takes it back or New Game starts again.

export const TRAVEL_GAME_HOLE = 121;
export const TRAVEL_NAME_MAX = 14;
// The most the Hand Calculator can bring back (a 29 hand).
export const TRAVEL_CALC_MAX = 29;
// History kept on the device, oldest dropped first.
const HISTORY_MAX = 500;

export type TravelPlayerCount = 2 | 3 | 4;

export const TRAVEL_DEFAULT_NAMES = ["Player/Team 1", "Player/Team 2", "Player 3", "Player 4"] as const;

// One OK: the plate, its score before and after, and the back peg it had.
export type TravelStep = { plate: number; from: number; to: number; prevLast: number | null };

export type TravelBoardState = {
  v: 1;
  players: TravelPlayerCount;
  // What was typed: "" shows the plate's default name.
  names: [string, string, string, string];
  scores: [number, number, number, number];
  // Each plate's last award: the board's back peg sits that far behind.
  last: [number | null, number | null, number | null, number | null];
  selected: number | null;
  entry: number;
  undo: TravelStep[];
  redo: TravelStep[];
};

export function travelBoardKey(userId: string): string {
  return `nobs:travel-board:v1:${userId}`;
}

export function newTravelBoard(players: TravelPlayerCount = 2, names?: TravelBoardState["names"]): TravelBoardState {
  return {
    v: 1,
    players,
    names: names ? [...names] : ["", "", "", ""],
    scores: [0, 0, 0, 0],
    last: [null, null, null, null],
    selected: null,
    entry: 0,
    undo: [],
    redo: [],
  };
}

// New Game: scores, entry, history and winner go; the player count and the
// names stay (they describe who is playing, not the game).
export function newGame(s: TravelBoardState): TravelBoardState {
  return { ...newTravelBoard(s.players, s.names), selected: s.selected };
}

export function plateName(s: TravelBoardState, plate: number): string {
  return s.names[plate]?.trim() || TRAVEL_DEFAULT_NAMES[plate];
}

// The plates on screen, by number.
export function visiblePlates(s: TravelBoardState): number[] {
  return Array.from({ length: s.players }, (_, i) => i);
}

// The plate at 121, if one is (only the plates on screen count).
export function winner(s: TravelBoardState): number | null {
  const i = visiblePlates(s).find((p) => s.scores[p] >= TRAVEL_GAME_HOLE);
  return i === undefined ? null : i;
}

// The banner: "<name> wins", then each other plate under 91 as skunked (61-90)
// or double skunked (under 61) -- the app's own lines (lossTier). lossTier's
// "stinkhole" (exactly 120) is God's splash only, not a skunk.
export function winnerLines(s: TravelBoardState): { title: string; skunks: string[] } | null {
  const w = winner(s);
  if (w === null) return null;
  const skunks: string[] = [];
  for (const p of visiblePlates(s)) {
    if (p === w) continue;
    const tier = lossTier(s.scores[p]);
    if (tier === "skunk") skunks.push(`${plateName(s, p)} was skunked`);
    if (tier === "double-skunk") skunks.push(`${plateName(s, p)} was double skunked`);
  }
  return { title: `${plateName(s, w)} wins`, skunks };
}

export function travelMessage(s: TravelBoardState): string {
  if (winner(s) !== null) return "Game over. Undo steps back; New Game starts again.";
  if (s.selected === null) return "Select the scoring plate before each score";
  return `Scoring for ${plateName(s, s.selected)}. Enter points, then OK.`;
}

// Whether the keys (+1, +2, +5, the calculator, OK, C) do anything.
export function keysLive(s: TravelBoardState): boolean {
  return s.selected !== null && winner(s) === null;
}

export function selectPlate(s: TravelBoardState, plate: number): TravelBoardState {
  if (!Number.isInteger(plate) || plate < 0 || plate >= s.players) return s;
  return { ...s, selected: plate };
}

// +1, +2, +5 and the calculator's total ADD to the entry. Never past 121.
export function addToEntry(s: TravelBoardState, points: number): TravelBoardState {
  if (!keysLive(s) || !Number.isInteger(points) || points < 0) return s;
  return { ...s, entry: Math.min(s.entry + points, TRAVEL_GAME_HOLE) };
}

export function clearEntry(s: TravelBoardState): TravelBoardState {
  if (!keysLive(s)) return s;
  return { ...s, entry: 0 };
}

// OK: the entry onto the selected plate (stopping at 121), one history step,
// Redo cleared, the entry back to 0. An entry of 0 does nothing.
export function pressOk(s: TravelBoardState): TravelBoardState {
  if (!keysLive(s) || s.entry <= 0 || s.selected === null) return s;
  const plate = s.selected;
  const from = s.scores[plate];
  const to = Math.min(from + s.entry, TRAVEL_GAME_HOLE);
  const step: TravelStep = { plate, from, to, prevLast: s.last[plate] };
  return {
    ...withScore(s, plate, to, to - from),
    entry: 0,
    undo: [...s.undo, step].slice(-HISTORY_MAX),
    redo: [],
  };
}

export function undo(s: TravelBoardState): TravelBoardState {
  const step = s.undo[s.undo.length - 1];
  if (!step) return s;
  return { ...withScore(s, step.plate, step.from, step.prevLast), undo: s.undo.slice(0, -1), redo: [...s.redo, step] };
}

export function redo(s: TravelBoardState): TravelBoardState {
  const step = s.redo[s.redo.length - 1];
  if (!step) return s;
  return { ...withScore(s, step.plate, step.to, step.to - step.from), undo: [...s.undo, step], redo: s.redo.slice(0, -1) };
}

function withScore(s: TravelBoardState, plate: number, score: number, last: number | null): TravelBoardState {
  const scores = [...s.scores] as TravelBoardState["scores"];
  const lasts = [...s.last] as TravelBoardState["last"];
  scores[plate] = score;
  lasts[plate] = last;
  return { ...s, scores, last: lasts };
}

// Players: only the number of plates on screen. Nothing is reset; a selected
// plate that is hidden is let go.
export function setPlayers(s: TravelBoardState, players: number): TravelBoardState {
  if (players !== 2 && players !== 3 && players !== 4) return s;
  return { ...s, players, selected: s.selected !== null && s.selected >= players ? null : s.selected };
}

// A plate's name: trimmed, at most 14 characters; empty shows the default.
export function renamePlate(s: TravelBoardState, plate: number, name: string): TravelBoardState {
  if (!Number.isInteger(plate) || plate < 0 || plate > 3) return s;
  const names = [...s.names] as TravelBoardState["names"];
  names[plate] = cleanName(name);
  return { ...s, names };
}

export function cleanName(name: string): string {
  return String(name ?? "").trim().slice(0, TRAVEL_NAME_MAX).trim();
}

// THE HAND CALCULATOR'S RETURN (?calc=N on /travel-board): a whole number from
// 0 to 29, else nothing.
export function parseCalcTotal(raw: string | null | undefined): number | null {
  if (!raw || !/^\d{1,2}$/.test(raw)) return null;
  const n = Number(raw);
  return n <= TRAVEL_CALC_MAX ? n : null;
}

// SAVED ON THIS DEVICE: a convenience only. Anything unreadable, of another
// version or the wrong shape, starts a fresh board.
export function serializeTravelBoard(s: TravelBoardState): string {
  return JSON.stringify(s);
}

export function parseTravelBoard(raw: string | null | undefined): TravelBoardState {
  if (!raw) return newTravelBoard();
  try {
    const d = JSON.parse(raw) as Record<string, unknown>;
    if (!d || typeof d !== "object" || d.v !== 1) return newTravelBoard();
    const players = d.players;
    if (players !== 2 && players !== 3 && players !== 4) return newTravelBoard();
    const names = d.names;
    if (!Array.isArray(names) || names.length !== 4 || !names.every((n) => typeof n === "string")) return newTravelBoard();
    const scores = d.scores;
    if (!Array.isArray(scores) || scores.length !== 4 || !scores.every(isScore)) return newTravelBoard();
    const last = d.last;
    if (!Array.isArray(last) || last.length !== 4 || !last.every((l) => l === null || isScore(l))) return newTravelBoard();
    const selected = d.selected;
    if (!(selected === null || (Number.isInteger(selected) && (selected as number) >= 0 && (selected as number) < players))) {
      return newTravelBoard();
    }
    if (!isScore(d.entry)) return newTravelBoard();
    if (!isHistory(d.undo) || !isHistory(d.redo)) return newTravelBoard();
    return {
      v: 1,
      players,
      names: names.map(cleanName) as TravelBoardState["names"],
      scores: [...scores] as TravelBoardState["scores"],
      last: [...last] as TravelBoardState["last"],
      selected: selected as number | null,
      entry: d.entry as number,
      undo: (d.undo as TravelStep[]).map(cleanStep),
      redo: (d.redo as TravelStep[]).map(cleanStep),
    };
  } catch {
    return newTravelBoard();
  }
}

function isScore(n: unknown): n is number {
  return Number.isInteger(n) && (n as number) >= 0 && (n as number) <= TRAVEL_GAME_HOLE;
}

function isHistory(h: unknown): h is TravelStep[] {
  return (
    Array.isArray(h) &&
    h.length <= HISTORY_MAX &&
    h.every(
      (st) =>
        !!st &&
        typeof st === "object" &&
        Number.isInteger(st.plate) &&
        st.plate >= 0 &&
        st.plate <= 3 &&
        isScore(st.from) &&
        isScore(st.to) &&
        (st.prevLast === null || isScore(st.prevLast))
    )
  );
}

function cleanStep(st: TravelStep): TravelStep {
  return { plate: st.plate, from: st.from, to: st.to, prevLast: st.prevLast };
}
