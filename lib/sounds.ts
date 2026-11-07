// THE GAME'S SOUNDS: everything about them that isn't the browser's audio --
// which clips exist, which one an event plays, who hears a game's end, the
// keys that stop a repeat, which sound wins a burst, and the device setting.
// Pure, no React; tested by scripts/test-phase3.ts. The player itself is
// components/SoundProvider.tsx, and the table's triggers
// components/table/useTableSounds.ts.
//
// LIVE ONLY, like the splashes: a sound fires from a realtime handler, a tap
// or the deal animation's start, never from a read or a render, so a refresh,
// a reconnect or the safety poll can't play one.
//
// NOTHING A TABLE HIDES. There is deliberately no event here for points. A
// Muggins table keeps no visible score, so its end is a plain win or loss
// (endSoundEvent), never a tier, which would say how far behind you were.
// Hide counts hides only the hand and crib numbers: its final scores stay on
// the strip, so a tier is allowed there. A 19 hand does say a count, so it
// follows the zero splash and is silent on both (zeroSoundAllowed). Cards,
// the cut, the discard and the shuffle are public at every table.

import type { CustomBoard } from "@/lib/customBoards";
import { teamOfPosition } from "@/lib/phase3";
import { lossTier } from "@/lib/resultScores";

export type SoundEvent =
  | "card"
  | "shuffle"
  | "deal"
  | "zeroHand"
  | "win"
  | "loss"
  | "skunk"
  | "double-skunk"
  | "stinkhole";

const clip = (name: string) => `/sounds/${name}.mp3`;

// THE CLIPS. An event with several picks one at random (pickClip).
export const CORE_SOUNDS: Record<SoundEvent, readonly string[]> = {
  card: [clip("card")],
  shuffle: [clip("shuffle")],
  deal: [clip("deal")],
  // A hand or crib that counted 0. The skunk list has this clip too, on purpose.
  zeroHand: [clip("skunk-3-shot")],
  win: [clip("win-1-winner"), clip("win-2-booyah"), clip("win-3-thats-how-its-done"), clip("win-4-there-we-go")],
  loss: [clip("loss-1-better-luck-next-time"), clip("loss-2-that-sucks")],
  skunk: [clip("skunk-1-skunked"), clip("skunk-2-you-smell-that"), clip("skunk-3-shot")],
  "double-skunk": [clip("doubleskunk-1-double-skunked"), clip("doubleskunk-2-omg-you-stink")],
  stinkhole: [clip("stinkhole-1-stinkhole"), clip("stinkhole-2-welcome-to-the-stinkhole")],
};

export const SOUND_EVENTS = Object.keys(CORE_SOUNDS) as SoundEvent[];

// The budget, in bytes (scripts/test-phase3.ts holds the files to it).
export const SOUND_CLIP_MAX_BYTES = 60_000;
export const SOUND_SET_MAX_BYTES = 350_000;

// The shuffle's length: the deal animation waits this long for it, so the
// deal sound and the flying cards start together (DealAnimation's leadIn).
export const SHUFFLE_LEAD_MS = 650;

// Two discarded cards, a beat apart: the toss's own stagger (TOSS_STAGGER_MS).
export const DISCARD_GAP_MS = 90;

// How long the player collects cues before it plays the burst's winner.
export const BURST_WINDOW_MS = 40;

// WHAT AN EVENT PLAYS: the board's own clip while its board is on screen (the
// square table, and not a Muggins table, which shows no board), or the core
// sound. An event's list is one clip for a board, any number for core.
export function soundFor(
  event: SoundEvent,
  board: Pick<CustomBoard, "sounds"> | null | undefined,
  options: { isMuggins: boolean; square: boolean }
): readonly string[] {
  const own = options.square && !options.isMuggins ? board?.sounds?.[event] : undefined;
  return own ? [own] : CORE_SOUNDS[event];
}

// Every clip a table can need, to load when it opens.
export function clipsFor(board: Pick<CustomBoard, "sounds"> | null | undefined): string[] {
  return [...new Set([...SOUND_EVENTS.flatMap((e) => CORE_SOUNDS[e]), ...Object.values(board?.sounds ?? {})])];
}

// A random clip, never the one played last in this category, so a list of two
// or more can't repeat back to back. random: for the tests.
export function pickClip(clips: readonly string[], last: string | null, random: () => number = Math.random): string {
  const choices = clips.length > 1 ? clips.filter((c) => c !== last) : clips;
  return choices[Math.floor(random() * choices.length)] ?? clips[0];
}

// WHO HEARS A GAME'S END. Teams: both members of the winning team win, both of
// the other lose, by position in the game's own players list. Anyone not in
// that list (a spectator) hears neither.
export function gameOutcome(input: {
  players: string[];
  winnerId: string | null;
  myId: string | null;
  teams: boolean;
}): "win" | "loss" | null {
  const { players, winnerId, myId, teams } = input;
  if (!myId || !winnerId || !players.includes(myId)) return null;
  if (myId === winnerId) return "win";
  if (teams && players.length === 4 && teamOfPosition(players, myId) === teamOfPosition(players, winnerId)) {
    return "win";
  }
  return "loss";
}

// The score a loser's tier is read from: their own, or at Teams the higher of
// the team's two rows, as the plate shows it (buildPlates, lib/phase3.ts).
// Null unless the rows hold the game's final scores: a winner off the last
// hole means they aren't (a New Game's reset), and the sound is a plain loss.
export function loserScore(input: {
  rows: { user_id: string; score: number | null }[];
  players: string[];
  winnerId: string | null;
  myId: string;
  teams: boolean;
  gameHole: number;
}): number | null {
  const { rows, players, winnerId, myId, teams, gameHole } = input;
  const winner = rows.find((r) => r.user_id === winnerId);
  if (winner?.score !== gameHole) return null;
  const mine =
    teams && players.length === 4
      ? rows.filter((r) => teamOfPosition(players, r.user_id) === teamOfPosition(players, myId))
      : rows.filter((r) => r.user_id === myId);
  const scores = mine.map((r) => r.score).filter((s): s is number => typeof s === "number");
  return scores.length ? Math.max(...scores) : null;
}

// WHICH SOUND A GAME'S END PLAYS. A loser's tier comes from the same numbers
// as God's splash (lossTier, lib/resultScores.ts). A Muggins table never gets
// a tier: see the top of this file.
export function endSoundEvent(
  outcome: "win" | "loss",
  score: number | null,
  options: { isMuggins: boolean }
): SoundEvent {
  if (outcome === "win") return "win";
  if (options.isMuggins || score === null) return "loss";
  return lossTier(score) ?? "loss";
}

// A 19 HAND: heard unless the count is hidden here, by the same rule as the
// zero splash (hideCountNumbers on the table page). Hide counts is this
// player's own setting, so only their device goes quiet.
export function zeroSoundAllowed(options: { isMuggins: boolean; hideCounts: boolean }): boolean {
  return !options.isMuggins && !options.hideCounts;
}

// Whether an award is a counted hand or crib of 0. Pegging can't be one:
// play_card skips the award at 0, and its reasons never start "hand:" or
// "crib:". confirm_count always awards, as "hand: nothing" or "crib: nothing".
export function isZeroCount(points: number | null | undefined, reason: string | null | undefined): boolean {
  return points === 0 && !!reason && (reason.startsWith("hand:") || reason.startsWith("crib:"));
}

// THE KEYS. A key is claimed once, so a repeated event never plays twice. A
// play's seq restarts every hand (next_hand deletes the plays), so its key has
// the hand in it, or hand 2 onward would be silent.
export const playKey = (gameId: string, handNo: number | null | undefined, seq: number) =>
  `play:${gameId}:${handNo}:${seq}`;
export const discardKey = (gameId: string, handNo: number | null | undefined, userId: string) =>
  `discard:${gameId}:${handNo}:${userId}`;
// The dealer counts a hand and the crib, so the two are kept apart.
export const zeroKey = (gameId: string, handNo: number | null | undefined, userId: string, reason: string) =>
  `zero:${gameId}:${handNo}:${userId}:${reason.startsWith("crib:") ? "crib" : "hand"}`;
export const cutKey = (gameId: string, round: number, userId: string) => `cut:${gameId}:${round}:${userId}`;
export const cutOpenKey = (gameId: string) => `cut-open:${gameId}`;
export const dealKey = (handKey: string) => `deal:${handKey}`;
export const endKey = (gameId: string) => `end:${gameId}`;

// Every card cut so far, as keys, from games.deal_cut (an array of rounds).
export function cutKeys(gameId: string, rounds: { user_id: string }[][] | null | undefined): string[] {
  return (rounds ?? []).flatMap((round, i) => round.map((entry) => cutKey(gameId, i, entry.user_id)));
}

export function discardKeys(
  gameId: string,
  handNo: number | null | undefined,
  discardedBy: string[] | null | undefined
): string[] {
  return (discardedBy ?? []).map((id) => discardKey(gameId, handNo, id));
}

// What a row already holds when it is READ: cuts and discards that happened
// without this screen hearing them. They're marked heard, never played. Only a
// games row can say who cut or discarded, and an UPDATE repeats the whole row,
// so without this the next event would play them late.
export function heardKeys(row: {
  id: string;
  hand_no: number | null | undefined;
  deal_cut: { user_id: string }[][] | null | undefined;
  discarded_by: string[] | null | undefined;
}): string[] {
  return [...cutKeys(row.id, row.deal_cut), ...discardKeys(row.id, row.hand_no, row.discarded_by)];
}

// The same for the roster: the zero counts its rows already hold.
export function heardZeroKeys(
  gameId: string,
  handNo: number | null | undefined,
  rows: { user_id: string; last_points: number | null; last_reason: string | null }[]
): string[] {
  return rows
    .filter((r) => isZeroCount(r.last_points, r.last_reason))
    .map((r) => zeroKey(gameId, handNo, r.user_id, r.last_reason as string));
}

// A BURST: cues landing within BURST_WINDOW_MS. One plays, the highest here;
// the first of equals. A cue's steps always play together, which is how the
// shuffle stays with its deal: gapMs null plays each step as the last ends
// (shuffle, then deal), a number starts them that far apart (a discard's cards).
export const SOUND_PRIORITY: Record<SoundEvent, number> = {
  win: 3,
  loss: 3,
  skunk: 3,
  "double-skunk": 3,
  stinkhole: 3,
  deal: 2,
  shuffle: 1,
  zeroHand: 1,
  card: 0,
};

export type SoundCue = { steps: { event: SoundEvent; url: string }[]; gapMs: number | null };

const cuePriority = (cue: SoundCue) => Math.max(...cue.steps.map((s) => SOUND_PRIORITY[s.event]));

export function pickBurst(cues: SoundCue[]): SoundCue | null {
  return cues.reduce<SoundCue | null>(
    (best, cue) => (best === null || cuePriority(cue) > cuePriority(best) ? cue : best),
    null
  );
}

// WHETHER A SOUND PLAYS, decided fresh at the moment it would start, from the
// setting as it is now, so nothing has to be cleared or restored when the
// sound goes off and on again. contextState: the AudioContext's, null with
// none yet.
export function cueAllowed(input: {
  hidden: boolean;
  on: boolean;
  contextState: string | null;
  loaded: boolean;
}): boolean {
  return !input.hidden && input.on && input.contextState === "running" && input.loaded;
}

// What the context needs before it can play. A closed one can't be resumed
// (the browser can close it), so it is replaced, or sound would stay off until
// a reload; decoded clips work in the new one.
export function audioRepair(contextState: string | null): "make" | "resume" | null {
  if (contextState === null || contextState === "closed") return "make";
  return contextState === "running" ? null : "resume";
}

// THE PROFILE SETTING "Sound": this device only (localStorage), no account
// column. On unless turned off. Every read and write is guarded, because
// storage can be missing or blocked (a private window, a preview).
export const SOUND_KEY = "nobs:sound";
export const SOUND_VOLUME_KEY = "nobs:sound-volume";
export const SOUND_LAST_PREFIX = "nobs:sound-last:";
export const DEFAULT_SOUND_VOLUME = 0.8;

export function readSoundOn(): boolean {
  try {
    return localStorage.getItem(SOUND_KEY) !== "0";
  } catch {
    return true;
  }
}

export function writeSoundOn(on: boolean) {
  try {
    localStorage.setItem(SOUND_KEY, on ? "1" : "0");
  } catch {
    // Not saved; the setting stays as it was for next time.
  }
}

export function readSoundVolume(): number {
  try {
    const stored = localStorage.getItem(SOUND_VOLUME_KEY);
    if (stored === null || stored.trim() === "") return DEFAULT_SOUND_VOLUME;
    const volume = Number(stored);
    return Number.isFinite(volume) ? Math.min(Math.max(volume, 0), 1) : DEFAULT_SOUND_VOLUME;
  } catch {
    return DEFAULT_SOUND_VOLUME;
  }
}

export function writeSoundVolume(volume: number) {
  try {
    if (Number.isFinite(volume)) localStorage.setItem(SOUND_VOLUME_KEY, String(Math.min(Math.max(volume, 0), 1)));
  } catch {
    // Not saved; the setting stays as it was for next time.
  }
}

// The clip last played in a category, so a reload can't repeat it either.
export function readLastClip(event: SoundEvent): string | null {
  try {
    return localStorage.getItem(`${SOUND_LAST_PREFIX}${event}`);
  } catch {
    return null;
  }
}

export function writeLastClip(event: SoundEvent, url: string) {
  try {
    localStorage.setItem(`${SOUND_LAST_PREFIX}${event}`, url);
  } catch {
    // Not remembered: the next pick may repeat it after a reload.
  }
}
