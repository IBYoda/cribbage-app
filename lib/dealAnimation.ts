// THE DEALING ANIMATION (PRD item 31): the pure plan for showing a new hand
// being dealt -- which card flies where, and when. No React; the overlay
// that runs it is components/table/DealAnimation.tsx. Tested by
// scripts/test-phase3.ts.
//
// Like a real deal: one card at a time, face-down, from the dealer's deck,
// clockwise round the table starting with the player on the dealer's left,
// until every seat has its hand -- then any card the rules deal to the crib
// (3 players: one). Nothing here knows how many players there are: the seat
// order, the dealer, the hand size and the crib's extras come in.
//
// Two phases. THE DEAL: every card flies, face-down, making one half-turn in
// the plane as it goes; the other seats' cards land straight in their places,
// mine (the stack seat: me, at the bottom) in a small stack in the middle of
// my hand. THE FAN: once the last card is down, my stack fans out into my
// hand's places, each card turning face-up as it goes.

// ALL THE TIMINGS, in one place.
// The deal phase takes this long, however many cards: the last card lands
// at DEAL_TOTAL_MS, and the gap between cards leaving the deck follows from
// it (2 players: 12 cards, ~232ms apart -- about two in the air at once).
export const DEAL_TOTAL_MS = 3000;
export const DEAL_CARD_MS = 450;
// Each dealt card's turn in the plane, in degrees.
export const DEAL_SPIN_DEG = 180;
// The fan: my stack spreads into my hand, turning face-up, in FAN_TOTAL_MS;
// each card moves for FAN_CARD_MS, the rest is the stagger between them.
export const FAN_TOTAL_MS = 1000;
export const FAN_CARD_MS = 600;
// A discard thrown to the crib: each card's flight, and the stagger between
// cards.
export const TOSS_CARD_MS = 550;
export const TOSS_STAGGER_MS = 90;

export type DealTarget = number | "crib";

export type DealStep = {
  // A seat (its index in the seat order) or the crib.
  target: DealTarget;
  // Which card of that seat's hand (or of the crib's extras) this is: 0, 1, ...
  cardIndex: number;
  // When it leaves the deck, from the start of the deal, and how long it flies.
  delayMs: number;
  durationMs: number;
  // It lands in the stack seat's stack, not in its place (see the fan).
  stack: boolean;
};

// The fan: one of the stack seat's cards, from the stack to its place,
// turning face-up. delayMs from the start of the deal.
export type FanStep = {
  cardIndex: number;
  delayMs: number;
  durationMs: number;
};

export type DealPlan = {
  deal: DealStep[];
  fan: FanStep[];
  // When the last card lands, and when everything (the fan too) is over.
  dealMs: number;
  totalMs: number;
};

// The deal, in order. seatCount: seats in clockwise order (games.players);
// dealerIndex: the dealer's place in it; cardsPerSeat: the hand dealt
// (handSizes().dealt); cribExtras: cards dealt straight to the crib
// (cribCountDuringDiscard(n, 0)); stackSeat: the seat whose cards stack and
// fan (mine; none: no fan).
export function dealPlan(input: {
  seatCount: number;
  dealerIndex: number;
  cardsPerSeat: number;
  cribExtras?: number;
  stackSeat?: number | null;
  totalMs?: number;
  cardMs?: number;
  fanMs?: number;
  fanCardMs?: number;
}): DealPlan {
  const { seatCount, cardsPerSeat } = input;
  const cribExtras = Math.max(0, input.cribExtras ?? 0);
  const totalMs = input.totalMs ?? DEAL_TOTAL_MS;
  const cardMs = Math.min(input.cardMs ?? DEAL_CARD_MS, totalMs);
  if (seatCount < 1 || cardsPerSeat < 0) return { deal: [], fan: [], dealMs: 0, totalMs: 0 };
  const dealer = ((input.dealerIndex % seatCount) + seatCount) % seatCount;
  const stackSeat = input.stackSeat ?? null;

  const order: { target: DealTarget; cardIndex: number }[] = [];
  for (let round = 0; round < cardsPerSeat; round++) {
    for (let k = 1; k <= seatCount; k++) {
      order.push({ target: (dealer + k) % seatCount, cardIndex: round });
    }
  }
  for (let i = 0; i < cribExtras; i++) order.push({ target: "crib", cardIndex: i });

  // The last card lands at totalMs: the gap follows from it.
  const gaps = order.length - 1;
  const gap = gaps > 0 ? (totalMs - cardMs) / gaps : 0;
  const deal = order.map((step, i) => ({
    ...step,
    delayMs: Math.round(i * gap * 1000) / 1000,
    durationMs: cardMs,
    stack: step.target === stackSeat,
  }));
  const dealMs = dealLength(deal);

  // The fan, after the last card is down: the stack seat's cards in order,
  // staggered so the last one finishes at fanMs.
  const stacked = deal.filter((s) => s.stack).length;
  const fanMs = input.fanMs ?? FAN_TOTAL_MS;
  const fanCardMs = Math.min(input.fanCardMs ?? FAN_CARD_MS, fanMs);
  const stagger = stacked > 1 ? (fanMs - fanCardMs) / (stacked - 1) : 0;
  const fan = Array.from({ length: stacked }, (_, i) => ({
    cardIndex: i,
    delayMs: Math.round((dealMs + i * stagger) * 1000) / 1000,
    durationMs: fanCardMs,
  }));
  return { deal, fan, dealMs, totalMs: fan.length ? dealMs + fanMs : dealMs };
}

// A FLYING CARD'S TURN IN THE PLANE: the angle it leaves at, for a card
// that lands turned `toTurn` degrees (0 at my seat and across; 90 / -90 at
// the left / right seat, its cards sideways) from a place turned `fromTurn`
// (the deck or a hand). It starts lined up with where it leaves from (a card
// back looks the same either way up) and makes a half turn as it flies --
// plus a quarter turn when it goes between an upright and a sideways place.
// Between upright places: -180, the half turn the 2-player table always made.
export function flightTurn(fromTurn: number, toTurn: number, spinDeg: number = DEAL_SPIN_DEG): number {
  const quarter = (((toTurn - fromTurn) % 180) + 180) % 180;
  return toTurn - spinDeg - quarter;
}

// When a set of steps is over.
export function dealLength(steps: { delayMs: number; durationMs: number }[]): number {
  return steps.reduce((end, s) => Math.max(end, s.delayMs + s.durationMs), 0);
}

// THE DISCARD TOSS: each discarding seat's cards fly from its hand to the
// crib, one after another with a small stagger, seat after seat in the order
// given (several seats' discards seen at once). Any number of seats and cards.
export type TossStep<Seat> = {
  seat: Seat;
  cardIndex: number;
  delayMs: number;
  durationMs: number;
};

export function discardPlan<Seat>(
  seats: { seat: Seat; cards: number }[],
  timing: { cardMs?: number; staggerMs?: number } = {}
): TossStep<Seat>[] {
  const cardMs = timing.cardMs ?? TOSS_CARD_MS;
  const staggerMs = timing.staggerMs ?? TOSS_STAGGER_MS;
  const steps: TossStep<Seat>[] = [];
  for (const { seat, cards } of seats) {
    for (let i = 0; i < cards; i++) {
      steps.push({ seat, cardIndex: i, delayMs: steps.length * staggerMs, durationMs: cardMs });
    }
  }
  return steps;
}

// A LIVE DISCARD: which discards to throw to the crib on screen. Called on
// every render with the hand on show and who has discarded, and what it
// recorded last time (seen):
//   * seen undefined (the table's first full read only just in) or a
//     different hand: whatever discards are there already happened before
//     this screen saw the hand (a load, a reload, a late join, the hand
//     already past the discard) -- recorded, never thrown;
//   * players in discardedBy not seen before: those discards are live --
//     thrown, unless a deal is still being shown here (the crib just appears
//     when the deal ends) or the animations are off. Recorded either way, so
//     a re-render or a realtime echo can never throw them again.
export type DiscardSeen = { handKey: string; ids: string[] } | null;

export function liveDiscardStep(input: {
  tableRead: boolean;
  seen: DiscardSeen | undefined;
  handKey: string | null;
  discardedBy: string[];
  dealInFlight: boolean;
  animationOn: boolean;
}): { seen: DiscardSeen | undefined; live: string[] } {
  const { tableRead, seen, handKey, discardedBy } = input;
  if (!tableRead) return { seen, live: [] };
  if (!handKey) return { seen: seen === null ? seen : null, live: [] };
  if (!seen || seen.handKey !== handKey) return { seen: { handKey, ids: [...discardedBy] }, live: [] };
  const fresh = discardedBy.filter((id) => !seen.ids.includes(id));
  if (fresh.length === 0) return { seen, live: [] };
  return {
    seen: { handKey, ids: [...seen.ids, ...fresh] },
    live: input.dealInFlight || !input.animationOn ? [] : fresh,
  };
}

// A LIVE DEAL: is this the moment to animate a hand? Called on every
// render of the table with what it shows now, and the dealt hand
// ("<game id>:<hand_no>", null when no hand is dealt) it saw last time:
//   * seenKey undefined: the table's first full read hasn't come in -- or
//     has only just (tableRead): whatever hand is on screen then was dealt
//     before this screen was here (a load, a reload, a late join, a
//     spectator), so it is recorded as seen and never animates;
//   * the same hand as last time: nothing (a re-render, a realtime echo);
//   * a hand not seen before, still in the discard with my cards not yet
//     discarded, and the animation on: that hand's deal is live.
// Returns the hand to record as seen, and the hand to animate (or null).
export function liveDealStep(input: {
  tableRead: boolean;
  seenKey: string | null | undefined;
  handKey: string | null;
  phase: string;
  iHaveDiscarded: boolean;
  animationOn: boolean;
}): { seenKey: string | null | undefined; liveKey: string | null } {
  const { tableRead, seenKey, handKey } = input;
  if (!tableRead || handKey === seenKey) return { seenKey, liveKey: null };
  const live =
    seenKey !== undefined && !!handKey && input.phase === "discard" && !input.iHaveDiscarded && input.animationOn;
  return { seenKey: handKey, liveKey: live ? handKey : null };
}

// The live-discard record with `userId` counted as already thrown for this
// hand -- the computer opponent once its discard has been shown (see THE
// COMPUTER'S DISCARD, below), so its real discard arriving later is never
// thrown again. The same object when there is nothing to add (it is compared
// during render).
export function markDiscardSeen(
  seen: DiscardSeen | undefined,
  handKey: string | null,
  userId: string | null
): DiscardSeen | undefined {
  if (!seen || !handKey || !userId || seen.handKey !== handKey || seen.ids.includes(userId)) return seen;
  return { handKey, ids: [...seen.ids, userId] };
}

// THE STARTER'S SLIDE at the start of counting (square table): the starter
// moves from the dealer's deck to its counting place (countingStarterPlace,
// lib/tableLayout.ts) in this long.
export const STARTER_SLIDE_MS = 450;

// A LIVE START OF COUNTING: should the starter slide? The same guard as the
// deal. Called on every render with the hand on show and whether the
// counting picture is on screen; `seenKey` records "<hand>:count" or
// "<hand>:other" from last time:
//   * seenKey undefined (the table's first full read only just in): whatever
//     is on screen was there before this screen saw it (a load, a reload, a
//     late join, a page loaded in counting) -- recorded, never slides;
//   * the same hand going from "other" to "count", with the animation on: live;
//   * anything else (the same state again, a new hand): recorded only.
// Returns what to record, and the hand whose starter slides now (or null).
export function liveStarterStep(input: {
  tableRead: boolean;
  seenKey: string | null | undefined;
  handKey: string | null;
  counting: boolean;
  animationOn: boolean;
}): { seenKey: string | null | undefined; liveKey: string | null } {
  const { tableRead, seenKey, handKey } = input;
  if (!tableRead) return { seenKey, liveKey: null };
  const key = handKey ? `${handKey}:${input.counting ? "count" : "other"}` : null;
  if (key === seenKey) return { seenKey, liveKey: null };
  const live = input.counting && input.animationOn && !!handKey && seenKey === `${handKey}:other`;
  return { seenKey: key, liveKey: live ? handKey : null };
}

// THE COMPUTER'S DISCARD, SHOWN ON TIME (2-player square table with a
// computer opponent; display only -- the game, the server and the computer's
// real moves are untouched). The computer really discards only after its
// turn comes up, which can be after mine; so once my dealt hand has been on
// this screen for COMPUTER_DISCARD_SHOW_MS (from when it first appeared on
// this page load: the start of the deal, or when the hand showed if nothing
// animated) without its real discard -- and no deal is still being shown --
// the screen shows it as discarded: its two cards thrown to the crib (the
// normal toss, or straight there with the animations off), its hand two
// short, the crib with its cards. When the real discard comes, the picture
// is already right: it is never thrown again (markDiscardSeen) and the crib
// never counts it twice (shownCribIds). My own discard before the time is up
// cancels it for that hand. A page reloaded after it showed shows it again at
// once (remembered in localStorage per game and hand).
export const COMPUTER_DISCARD_SHOW_MS = 7000;

export type DiscardShow = {
  handKey: string;
  // When my hand showed (the clock's start), or null: not yet.
  startedAt: number | null;
  fired: boolean;
  cancelled: boolean;
} | null;

// One step of it, from what is on screen now (`now`: the time). Returns the
// state to keep (the same object when nothing changed) and, while waiting,
// how long until it shows.
export function discardShowStep(input: {
  // A computer opponent at a 2-player square table.
  eligible: boolean;
  handKey: string | null;
  phase: string | null;
  // My dealt hand is on this screen (being dealt counts): the clock starts.
  handShown: boolean;
  // A deal is still being shown: it waits for the end.
  dealInFlight: boolean;
  computerDiscarded: boolean;
  // I have discarded, or my discard is on its way.
  iDiscarding: boolean;
  // It already showed for this hand on an earlier load.
  remembered: boolean;
  state: DiscardShow;
  now: number;
}): { state: DiscardShow; fireInMs: number | null } {
  const { handKey, state } = input;
  if (!input.eligible || !handKey || input.phase !== "discard") {
    return { state: state === null ? state : null, fireInMs: null };
  }
  let next: NonNullable<DiscardShow> =
    state && state.handKey === handKey ? state : { handKey, startedAt: null, fired: false, cancelled: false };
  const update = (patch: Partial<NonNullable<DiscardShow>>) => {
    next = { ...next, ...patch };
  };
  if (input.remembered && !next.fired) update({ fired: true });
  let fireInMs: number | null = null;
  if (!next.fired && !input.computerDiscarded) {
    if (input.iDiscarding) {
      if (!next.cancelled) update({ cancelled: true });
    } else if (!next.cancelled && (input.handShown || next.startedAt !== null)) {
      // From the first moment the hand is here; kept once started.
      if (next.startedAt === null) update({ startedAt: input.now });
      // Never while a deal is still shown: due then, it fires as it ends.
      if (!input.dealInFlight) {
        fireInMs = Math.max(0, (next.startedAt as number) + COMPUTER_DISCARD_SHOW_MS - input.now);
      }
    }
  }
  return { state: next, fireInMs };
}

// The timer ran out: it shows (unless the hand moved on meanwhile).
export function fireDiscardShow(state: DiscardShow, handKey: string): DiscardShow {
  if (!state || state.handKey !== handKey || state.fired || state.cancelled) return state;
  return { ...state, fired: true };
}

// Whether the computer is shown as discarded though it hasn't really yet.
export function discardShown(input: {
  eligible: boolean;
  handKey: string | null;
  phase: string | null;
  computerDiscarded: boolean;
  state: DiscardShow;
}): boolean {
  return (
    input.eligible &&
    !!input.handKey &&
    input.phase === "discard" &&
    !input.computerDiscarded &&
    !!input.state &&
    input.state.handKey === input.handKey &&
    input.state.fired
  );
}

// WHOSE DISCARDS THE CRIB PILE SHOWS: the real ones, mine while it is being
// sent, and the computer's once shown -- each player once, never twice --
// less any still flying to it.
export function shownCribIds(input: {
  discardedBy: string[];
  mineSending: string | null;
  shownComputer: string | null;
  tossing: Iterable<string>;
}): Set<string> {
  const ids = new Set(input.discardedBy);
  if (input.mineSending) ids.add(input.mineSending);
  if (input.shownComputer) ids.add(input.shownComputer);
  for (const id of input.tossing) ids.delete(id);
  return ids;
}

// Remembering it across a reload: one key per game and hand. Writing one
// clears every other (so nothing carries to a later hand); reads and writes
// are guarded (storage can be missing or blocked) -- without storage a
// reload simply shows the real state.
const DISCARD_SHOW_PREFIX = "nobs:cpu-discard-shown:";

export function discardShowKey(handKey: string): string {
  return `${DISCARD_SHOW_PREFIX}${handKey}`;
}

export function readDiscardShown(handKey: string): boolean {
  try {
    return localStorage.getItem(discardShowKey(handKey)) === "1";
  } catch {
    return false;
  }
}

export function writeDiscardShown(handKey: string | null) {
  try {
    const keep = handKey ? discardShowKey(handKey) : null;
    for (let i = localStorage.length - 1; i >= 0; i--) {
      const key = localStorage.key(i);
      if (key && key.startsWith(DISCARD_SHOW_PREFIX) && key !== keep) localStorage.removeItem(key);
    }
    if (keep) localStorage.setItem(keep, "1");
  } catch {
    // Not remembered: a reload shows the real state.
  }
}

// THE PROFILE SETTING "Card animations" (the deal and the discard toss; it
// was "Dealing animation" -- same key, so a saved Off carries over): this
// device only (localStorage), on unless turned off. No account column.
// Every read and write is guarded --
// storage can be missing or blocked (a private window, a preview) -- and
// falls back to on.
export const DEAL_SETTING_KEY = "nobs:deal-animation";

export function readDealAnimationOn(): boolean {
  try {
    return localStorage.getItem(DEAL_SETTING_KEY) !== "off";
  } catch {
    return true;
  }
}

export function writeDealAnimationOn(on: boolean) {
  try {
    if (on) localStorage.removeItem(DEAL_SETTING_KEY);
    else localStorage.setItem(DEAL_SETTING_KEY, "off");
  } catch {
    // Not saved; the setting stays on for next time.
  }
}
