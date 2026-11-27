// TABLE CHAT (PRD item 39): the pure rules, no React and no Supabase here.
// The hook is components/table/useTableChat.ts.
//
// THROUGH THE SERVER (moderation M5c1, docs/sql/moderation-m5c1-part1.sql):
// each person at the table -- a seated player, or a CURRENT spectator
// (spectator chat) -- sends with the RPC send_table_message, which checks
// who may send, cleans the text, limits the rate, sets the sender itself and
// broadcasts { event: 'chat', id, sender_id, text, at } on the table's
// private topic table:<table_id> -- the channel the table, game and scores
// events already use (components/table/useTableEvents.ts, parseChatEvent in
// lib/tableEvents.ts). Everyone at the table hears it there. Name, avatar
// and spectator mark come from the table's roster (the players, then the
// current spectators) -- never from the message. The old per-sender
// chat:<table>:<sender> channels are gone (Walt's HARD CUT, 2026-11-26).
// Nothing is kept for history; messages live in memory until closed.

// The longest message, in characters (code points, so an emoji is one).
export const CHAT_MAX_LENGTH = 140;
// How many messages a screen keeps in memory (closed ones are gone at once).
export const CHAT_MEMORY = 50;
// The most of the others' cards that stack at once (fewer when the room,
// chatStackRoom, holds fewer); the rest are "+N more". My own echoed card is
// extra and never counts.
export const CHAT_MAX_CARDS = 5;

// Text as it may be shown: a string, trimmed, every line break (and the
// spaces around it) turned into one space, control characters and
// direction overrides removed, cut to CHAT_MAX_LENGTH characters. Anything
// else -- not a string, or nothing left -- is null, and is dropped.
export function cleanChatText(input: unknown): string | null {
  if (typeof input !== "string") return null;
  const text = input
    .replace(/[^\S\r\n\u2028\u2029]*[\r\n\u2028\u2029]+\s*/g, " ")
    // C0 and C1 controls (tab included), then the bidi overrides and
    // isolates, which could make a message read backwards.
    .replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, "")
    .trim();
  const cut = Array.from(text).slice(0, CHAT_MAX_LENGTH).join("").trim();
  return cut === "" ? null : cut;
}

// THE THROTTLE: at most 1 message in any 2 seconds and 3 in any 10 -- the
// server's own limit (send_table_message, NBC04), kept here as a first
// guard on MY sends only ("Slow down" without a round trip). Others'
// messages are not throttled on my screen any more: the server already
// refused anything over the limit.
export const CHAT_LIMITS: ReadonlyArray<{ count: number; windowMs: number }> = [
  { count: 1, windowMs: 2000 },
  { count: 3, windowMs: 10000 },
];

// Whether one more message at `now` fits, given the times of the ones
// already let through.
export function chatThrottleAllows(sent: readonly number[], now: number): boolean {
  return CHAT_LIMITS.every(({ count, windowMs }) => sent.filter((t) => now - t < windowMs).length < count);
}

// One sender's throttle. take(now) says whether a message fits, and records
// it when it does.
export function createChatThrottle() {
  let sent: number[] = [];
  const longest = Math.max(...CHAT_LIMITS.map((l) => l.windowMs));
  return {
    take(now: number): boolean {
      sent = sent.filter((t) => now - t < longest);
      if (!chatThrottleAllows(sent, now)) return false;
      sent.push(now);
      return true;
    },
  };
}

// WHAT A SEND ENDED AS (send_table_message's answer): "ok" with the
// message's server id (null if the answer had none -- it was still sent);
// "throttled" for NBC04, which shows "Slow down"; everything else --
// NBC01, NBC02, NBC03, NBC05, a network error, anything unknown -- is
// "failed", which shows "Couldn't send".
export type ChatSendResult = "ok" | "throttled" | "failed";

const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function chatSendOutcome(
  error: { code?: string | null } | null | undefined,
  data: unknown
): { result: ChatSendResult; id: string | null } {
  if (error) return { result: error.code === "NBC04" ? "throttled" : "failed", id: null };
  const id = data && typeof data === "object" ? (data as { id?: unknown }).id : undefined;
  return { result: "ok", id: typeof id === "string" && ID.test(id) ? id : null };
}

// MY OWN MESSAGE COMING BACK: the server's broadcast reaches me too. It is
// mine -- never a card in the others' stack (my own card is `own`) -- when
// its id is one of the ids my sends got back (the echo matched by id), or
// when its sender is me at all (the echo beating the RPC's answer, or a
// message from my other tab, which never showed here before either).
export function chatEventIsMine(event: { id: string; senderId: string }, myUserId: string | null, ownIds: readonly string[]): boolean {
  return ownIds.includes(event.id) || (myUserId !== null && event.senderId === myUserId);
}

export type ChatMessage = {
  id: string;
  senderId: string;
  // From the roster as it arrived, never from the message.
  name: string;
  avatarUrl: string | null;
  text: string;
  at: number;
  // A spectator's message: a small eye beside the name (from the roster).
  spectator?: boolean;
};

// A new message on top; at most CHAT_MEMORY kept.
export function addChatMessage(list: readonly ChatMessage[], message: ChatMessage): ChatMessage[] {
  return [message, ...list].slice(0, CHAT_MEMORY);
}

// MUTED SENDERS (moderation M2/M2c): the people whose messages never show on
// this screen -- the ones I muted at this table (lib/chatMute.ts, this
// browser) and the ones on my Block List (lib/blocks.ts, the server). A muted sender's
// messages are dropped as they arrive, and any already showing go at once.
export function mutedSenders(mutedHere: Iterable<string>, blocked: Iterable<string>): Set<string> {
  return new Set([...mutedHere, ...blocked]);
}

// The list without any muted sender's messages (the same list when none).
export function withoutSenders(list: readonly ChatMessage[], muted: ReadonlySet<string>): ChatMessage[] {
  if (muted.size === 0 || !list.some((m) => muted.has(m.senderId))) return list as ChatMessage[];
  return list.filter((m) => !muted.has(m.senderId));
}

// What the stack shows: the newest `max` cards, and how many more wait.
export function visibleChatCards(list: readonly ChatMessage[], max = CHAT_MAX_CARDS) {
  const room = Math.max(1, max);
  return { shown: list.slice(0, room), more: Math.max(0, list.length - room) };
}

// THE CARDS' LAYER: drawn over the whole table (a portal to <body>, fixed
// over the table's middle), so no card, pile, deck, avatar or board can
// cover a message. Above the win splash (z-40), below the deal overlay
// (z-60; the cards hide during a deal anyway), the counts menu (z-62) and
// the composer (z-70).
export const CHAT_LAYER_Z = 55;

type Box = { top: number; bottom: number };

// WHERE THE CARDS GO AND HOW MUCH ROOM THEY HAVE, from the middle's box,
// the table notices showing in it (the amber "the game was ended" banner)
// and its controls -- all in screen pixels.
//   * The cards start below every notice: they never cover a notice's text
//     or its Dismiss. A notice's own controls are never "in the way".
//   * `limit`: how far down the cards may ever reach -- the middle's bottom
//     (never over the piles or the hand), and in a game the first control
//     below the cards' top (Next Hand, Confirm Count, the cut's deck...).
//   * `budget`: how far they normally reach. "full" (no hand dealt: the
//     waiting room, a table waiting for a game): the whole limit. "game":
//     half the middle, but the newest card may run on to the limit.
//   * expanded (Show was tapped): controls are no longer in the way.
// The stack folds only when not even the newest card fits the limit.
export function chatStackRoom({
  middle,
  notices,
  controls,
  mode,
  expanded,
  gap = 4,
  share = 0.5,
}: {
  middle: Box;
  notices: readonly Box[];
  controls: readonly Box[];
  mode: "game" | "full";
  expanded: boolean;
  gap?: number;
  share?: number;
}): { top: number; budget: number; limit: number } {
  const top = notices.reduce((t, n) => Math.max(t, n.bottom + gap), middle.top);
  const room = Math.max(0, middle.bottom - top - gap);
  if (mode === "full") return { top, budget: room, limit: room };
  const half = Math.min(room, (middle.bottom - middle.top) * share);
  if (expanded) return { top, budget: half, limit: room };
  let controlTop = Infinity;
  for (const c of controls) {
    if (c.bottom <= top) continue; // above the cards: not in the way
    controlTop = Math.min(controlTop, Math.max(0, c.top - top - gap));
  }
  const limit = Math.min(room, controlTop);
  return { top, budget: Math.min(half, limit), limit };
}

// MY OWN MESSAGE, ECHOED: after send_table_message answered OK, the
// sender sees it too, as a card like everyone else's -- but only briefly
// (OWN_CARD_MS, fading out over the last OWN_CARD_FADE_MS) and apart from
// the others' messages: at most one at a time (a new one replaces it), never
// counted in "N new messages" or "+N more", never pushing anyone's card out,
// never read out by the screen reader (I just typed it). A send that failed
// or was throttled shows no card.
export const OWN_CARD_MS = 2000;
export const OWN_CARD_FADE_MS = 300;

export function ownChatCard({
  result,
  text,
  me,
  myUserId,
  now,
  id,
}: {
  result: "ok" | "throttled" | "failed";
  text: string | null;
  // Me, from the roster: a seated player, or (spectator chat) a current
  // spectator, who is in the roster through get_table_spectators -- so a
  // spectator's own card has their own name, and their eye.
  me: { nickname: string | null; avatar_url: string | null; spectator?: boolean } | undefined;
  myUserId: string;
  now: number;
  id: string;
}): ChatMessage | null {
  if (result !== "ok" || text === null) return null;
  return {
    id,
    senderId: myUserId,
    name: me?.nickname || "Unnamed player",
    avatarUrl: me?.avatar_url ?? null,
    text,
    at: now,
    spectator: me?.spectator === true,
  };
}

// Whether my own card still shows at `now` (it goes at exactly OWN_CARD_MS).
export function ownCardShowing(own: ChatMessage | null, now: number): boolean {
  return own !== null && now - own.at < OWN_CARD_MS;
}

// THE STACK'S COUNTS, from the others' messages only (my own card is never
// one of them): how many cards show, whether it folds, and "+N more".
export function chatStackCounts(messages: readonly ChatMessage[], fit: number) {
  const shown = Math.min(fit, visibleChatCards(messages).shown.length);
  return { shown, folded: messages.length > 0 && shown === 0, more: messages.length - shown };
}
