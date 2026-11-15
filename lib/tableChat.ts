// TABLE CHAT (PRD item 39): the pure rules, no React and no Supabase here.
// The channels are components/table/useTableChat.ts; the server's rules are
// docs/sql/table-chat.sql (chat_topic_allows).
//
// Each player sends on a private Realtime Broadcast channel of their own,
// "chat:<table_id>:<sender_user_id>", and listens to every other seated
// player's. A message is just { text }: who sent it is the channel it came
// on (the server lets only that player send there), and their name and
// avatar come from the table's roster -- never from the message.
// Nothing is stored anywhere; messages live in memory until closed.

// The longest message, in characters (code points, so an emoji is one).
export const CHAT_MAX_LENGTH = 140;
// The broadcast event every chat message uses.
export const CHAT_EVENT = "msg";
// How many messages a screen keeps in memory (closed ones are gone at once).
export const CHAT_MEMORY = 50;
// The most of the others' cards that stack at once (fewer when the room,
// chatStackRoom, holds fewer); the rest are "+N more". My own echoed card is
// extra and never counts.
export const CHAT_MAX_CARDS = 5;

// The topic for one sender at one table. Lowercase, as the server's rule
// requires (it refuses an uppercase id rather than guess).
export function chatTopic(tableId: string, senderId: string): string {
  return `chat:${tableId.toLowerCase()}:${senderId.toLowerCase()}`;
}

const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const TOPIC = new RegExp(`^chat:(${UUID}):(${UUID})$`);

// The sender id in a topic, if it is a chat topic for this table; else null.
// (realtime-js may prefix "realtime:" to a channel's topic; that is allowed.)
export function chatSenderId(topic: string, tableId: string): string | null {
  const bare = topic.startsWith("realtime:") ? topic.slice("realtime:".length) : topic;
  const match = TOPIC.exec(bare);
  if (!match || match[1] !== tableId.toLowerCase()) return null;
  return match[2];
}

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

// THE THROTTLE: at most 1 message in any 2 seconds and 3 in any 10. The
// same limit for my own sends and, on my screen, for each other player's
// messages (anything over it is dropped).
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

// The receiving side: the same limit, kept for each sender apart.
export function createPerSenderThrottle() {
  const bySender = new Map<string, ReturnType<typeof createChatThrottle>>();
  return {
    take(senderId: string, now: number): boolean {
      let throttle = bySender.get(senderId);
      if (!throttle) {
        throttle = createChatThrottle();
        bySender.set(senderId, throttle);
      }
      return throttle.take(now);
    },
  };
}

export type ChatMessage = {
  id: string;
  senderId: string;
  // From the roster as it arrived, never from the message.
  name: string;
  avatarUrl: string | null;
  text: string;
  at: number;
};

// A new message on top; at most CHAT_MEMORY kept.
export function addChatMessage(list: readonly ChatMessage[], message: ChatMessage): ChatMessage[] {
  return [message, ...list].slice(0, CHAT_MEMORY);
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

// MY OWN MESSAGE, ECHOED: after a send the server ACKed as delivered, the
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
  me: { nickname: string | null; avatar_url: string | null } | undefined;
  myUserId: string;
  now: number;
  id: string;
}): ChatMessage | null {
  if (result !== "ok" || text === null) return null;
  return { id, senderId: myUserId, name: me?.nickname || "Unnamed player", avatarUrl: me?.avatar_url ?? null, text, at: now };
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
