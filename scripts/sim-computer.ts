// THE COMPUTER STRENGTH SIMULATOR: full 2-player games to 121 between two
// computer levels, entirely in memory -- the brain (lib/computer/brain.ts)
// against itself under the server's rules. No database, no network. Seeded,
// so every run is the same run. Not part of test:quick:
//
//   npm run sim:computer
//
// which wraps `node --import ./scripts/ts-resolve.mjs scripts/sim-computer.ts`.
//
// THE RULES mirror the server (docs/sql): six cards each, two to the crib;
// the starter is cut once both have discarded, a jack giving the dealer 2
// ("his heels", discard_to_crib); the pone leads the pegging, played under
// lib/computer/rules.ts (play_card_as: go, the 31 reset, the last card);
// then the pone's hand, the dealer's hand and the crib are counted, in that
// order (confirm_count_as, score_hand); the deal passes to the other player
// (next_hand_as). Every award is capped at 121 and the game ends the instant
// a player reaches 121 -- in pegging, on his heels or mid-count (award_points).
//
// PEEK as in the real driver (components/table/useComputerDriver.ts): a
// level whose LEVELS[level].peek is true gets the opponent's unplayed cards
// as opponentRemaining while pegging, and the game state (the scores, the
// dealer and both kept hands) for playing to win near 121; no other level
// ever does.
//
// THE DISCARD: a seat whose level peeks at the discard (Hard) discards
// second and is given the other seat's kept four, as the real driver waits
// for the human's discard.
//
// OPT-IN MATCHUPS (4000 games each, several minutes apiece):
//   --hard-no-discard-peek  Hard against Hard without the discard peek
//   --old-medium            Medium against "old Medium" (0.35 mistakes, no peek)
//   --old-hard              Hard against "old Hard" (60 crib samples, no game
//                           state, no discard peek)

import { decideDiscard, decidePlay, FULL_DECK, seededRng, type Rng } from "../lib/computer/brain";
import { LEVELS, type ComputerLevel, type LevelSettings } from "../lib/computer/config";
import { scoreHand } from "../lib/scoring";
import { applyPlay, type PegState, type Seat } from "../lib/computer/rules";

const GAMES = 2000;

// A player: a level, optionally with its crib sample count forced, whether
// it is given the game state (only used by a level that searches), whether
// it is given the other seat's kept hand at the discard (discardPeek; by
// default for a level with peekDiscard), and optionally other settings for
// its level ("old Medium"): swapped in for that player's own decisions only.
type Player = {
  name: string;
  level: ComputerLevel;
  cribSamples?: number;
  withGame: boolean;
  discardPeek?: boolean;
  settings?: LevelSettings;
};
const player = (level: ComputerLevel): Player => ({ name: level, level, withGame: true });
const peeksAtDiscard = (p: Player) => p.discardPeek ?? (p.settings ?? LEVELS[p.level]).peekDiscard;

// Runs fn with the player's own settings in place (a simulator-only device
// for a level as it used to be); the real settings are always restored.
function asPlayer<T>(p: Player, fn: () => T): T {
  if (!p.settings) return fn();
  const real = LEVELS[p.level];
  LEVELS[p.level] = p.settings;
  try {
    return fn();
  } finally {
    LEVELS[p.level] = real;
  }
}

type Tally = { pegging: number; hand: number; crib: number; heels: number; hands: number };
type GameResult = { winner: Seat; scores: [number, number]; tally: [Tally, Tally] };

function shuffle(rng: Rng) {
  const deck = [...FULL_DECK];
  for (let i = deck.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [deck[i], deck[j]] = [deck[j], deck[i]];
  }
  return deck;
}

function playGame(players: [Player, Player], firstDealer: Seat, seed: number): GameResult {
  const dealRng = seededRng(seed * 7 + 3);
  const rngs: [Rng, Rng] = [seededRng(seed * 7 + 1), seededRng(seed * 7 + 2)];
  const scores: [number, number] = [0, 0];
  const tally: [Tally, Tally] = [
    { pegging: 0, hand: 0, crib: 0, heels: 0, hands: 0 },
    { pegging: 0, hand: 0, crib: 0, heels: 0, hands: 0 },
  ];
  let dealer: Seat = firstDealer;

  // award_points: capped at 121; true when this award wins the game.
  const award = (seat: Seat, points: number, kind: keyof Omit<Tally, "hands">) => {
    const gained = Math.min(points, 121 - scores[seat]);
    scores[seat] += gained;
    tally[seat][kind] += gained;
    return scores[seat] >= 121;
  };

  for (;;) {
    const pone: Seat = dealer === 0 ? 1 : 0;
    tally[0].hands++;
    tally[1].hands++;
    const deck = shuffle(dealRng);
    const dealt: [string[], string[]] = [deck.slice(0, 6), deck.slice(6, 12)];
    const kept: [string[], string[]] = [[], []];
    const crib: string[] = [];
    // The discard: a seat that peeks goes second and is given the other
    // seat's kept four; if both peek, seat 0 goes first without peeking.
    const order: Seat[] = peeksAtDiscard(players[0]) && !peeksAtDiscard(players[1]) ? [1, 0] : [0, 1];
    for (const seat of order) {
      const other: Seat = seat === 0 ? 1 : 0;
      const givenKept = seat === order[1] && peeksAtDiscard(players[seat]) ? [...kept[other]] : undefined;
      const out = asPlayer(players[seat], () =>
        decideDiscard({
          hand: dealt[seat],
          isDealer: seat === dealer,
          level: players[seat].level,
          rng: rngs[seat],
          cribSamples: players[seat].cribSamples,
          opponentKept: givenKept,
        })
      );
      kept[seat] = dealt[seat].filter((c) => !out.includes(c));
      crib.push(...out);
    }
    const starter = deck[12];
    if (starter[0] === "J" && award(dealer, 2, "heels")) return { winner: dealer, scores, tally };

    // Pegging: the pone leads.
    let state: PegState | null = { hands: [[...kept[0]], [...kept[1]]], segment: [], count: 0, turn: pone };
    const allPlayed: string[] = [];
    while (state) {
      const p: Seat = state.turn;
      const o: Seat = p === 0 ? 1 : 0;
      const settings = players[p].settings ?? LEVELS[players[p].level];
      const peeks = settings.peek;
      const now: PegState = state;
      const card = asPlayer(players[p], () => decidePlay({
        myRemaining: now.hands[p],
        starter,
        segmentCards: now.segment,
        count: now.count,
        allPlayed: [...allPlayed],
        opponentCardCount: now.hands[o].length,
        level: players[p].level,
        rng: rngs[p],
        opponentRemaining: peeks ? [...now.hands[o]] : undefined,
        game:
          peeks && players[p].withGame
            ? { myScore: scores[p], opponentScore: scores[o], iAmDealer: p === dealer, myKept: [...kept[p]], opponentKept: [...kept[o]] }
            : undefined,
      }));
      const result = applyPlay(state, card);
      allPlayed.push(card);
      if (result.points > 0 && award(p, result.points, "pegging")) return { winner: p, scores, tally };
      state = result.next;
    }

    // The count: the pone's hand, the dealer's hand, the crib.
    if (award(pone, scoreHand(kept[pone], starter, false).points, "hand")) return { winner: pone, scores, tally };
    if (award(dealer, scoreHand(kept[dealer], starter, false).points, "hand")) return { winner: dealer, scores, tally };
    if (award(dealer, scoreHand(crib, starter, true).points, "crib")) return { winner: dealer, scores, tally };

    dealer = pone;
  }
}

function matchup(pa: Player, pb: Player, games = GAMES) {
  const a = pa.name;
  const b = pb.name;
  const GAMES_HERE = games;
  const wins = [0, 0];
  let loserTotal = 0;
  const sum: [Tally, Tally] = [
    { pegging: 0, hand: 0, crib: 0, heels: 0, hands: 0 },
    { pegging: 0, hand: 0, crib: 0, heels: 0, hands: 0 },
  ];
  const started = performance.now();
  for (let g = 0; g < GAMES_HERE; g++) {
    const r = playGame([pa, pb], (g % 2) as Seat, g);
    wins[r.winner]++;
    loserTotal += r.scores[r.winner === 0 ? 1 : 0];
    for (const s of [0, 1] as const) {
      for (const k of ["pegging", "hand", "crib", "heels", "hands"] as const) sum[s][k] += r.tally[s][k];
    }
  }
  const per = (s: Seat, k: keyof Tally) => (sum[s][k] / sum[s].hands).toFixed(2);
  const pct = (n: number) => ((100 * n) / GAMES_HERE).toFixed(1) + "%";
  // The 95% margin of error on a win rate over this many games.
  const p = wins[0] / GAMES_HERE;
  const margin = 196 * Math.sqrt((p * (1 - p)) / GAMES_HERE);
  console.log(`${a} vs ${b} (${GAMES_HERE} games, first deal alternating; ${((performance.now() - started) / 1000).toFixed(1)} s)`);
  console.log(
    `  wins: ${a} ${pct(wins[0])}, ${b} ${pct(wins[1])} (95% margin ±${margin.toFixed(1)} points); loser's average final score ${(loserTotal / GAMES_HERE).toFixed(1)}`
  );
  for (const s of [0, 1] as const) {
    const name = s === 0 ? a : b;
    console.log(
      `  ${name.padEnd(6)} per hand: pegging ${per(s, "pegging")}, hand ${per(s, "hand")}, crib ${per(s, "crib")}, his heels ${per(s, "heels")}`
    );
  }
}

const start = performance.now();
matchup(player("medium"), player("easy"));
matchup(player("hard"), player("medium"));
matchup(player("hard"), player("easy"));
if (process.argv.includes("--old-hard")) {
  matchup(player("hard"), { name: "old hard", level: "hard", cribSamples: 60, withGame: false, discardPeek: false }, 4000);
}
if (process.argv.includes("--hard-no-discard-peek")) {
  matchup(player("hard"), { name: "hard, no discard peek", level: "hard", withGame: true, discardPeek: false }, 4000);
}
if (process.argv.includes("--old-medium")) {
  matchup(player("medium"), {
    name: "old medium",
    level: "medium",
    withGame: false,
    settings: { mistakeRate: 0.35, peek: false, peekDiscard: false, search: false, style: "normal", cribSamples: 60 },
  }, 4000);
}
console.log(`Total run time: ${((performance.now() - start) / 1000).toFixed(1)} s`);
