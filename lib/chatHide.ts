// HIDE IN CHAT (moderation M2): a PERSONAL, browser-only list of people whose
// chat messages this player doesn't want to see. It affects nobody else,
// nothing is sent to the server, and it applies at every table (spectating
// too). Stored per signed-in player under nobs:chat-hidden:v1:<userId>, so
// two accounts on one browser keep their own lists. Undone with Unhide in
// Settings ("Hidden in chat", components/brand/ChatHiddenList.tsx).
//
// BLOCK is not this list: a block lives on the server's Block List (lib/
// blocks.ts) and hides chat by being there, so Unblock on the Profile page
// brings their chat back. What chat drops is the MUTED set: hidden ids plus
// blocked ids (lib/tableChat.ts mutedSenders).
//
// Pure helpers plus guarded storage: a blocked or full localStorage, or a
// corrupt value, just means an empty list -- never an error on screen.
// Tested by scripts/test-phase3.ts.

export type HiddenPerson = { userId: string; name: string; hiddenAt: number };

// Plenty for one person; the oldest go first beyond it.
export const CHAT_HIDDEN_LIMIT = 500;

// Same-tab listeners hear this (the storage event only reaches OTHER tabs).
export const CHAT_HIDDEN_EVENT = "nobs:chat-hidden";

export const chatHiddenKey = (userId: string) => `nobs:chat-hidden:v1:${userId}`;

// A stored value as a clean list: newest first, one entry per person,
// anything malformed dropped.
export function parseHidden(raw: string | null | undefined): HiddenPerson[] {
  if (!raw) return [];
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!Array.isArray(data)) return [];
  const seen = new Set<string>();
  const out: HiddenPerson[] = [];
  for (const item of data) {
    const r = item as { userId?: unknown; name?: unknown; hiddenAt?: unknown } | null;
    if (!r || typeof r.userId !== "string" || r.userId === "" || seen.has(r.userId)) continue;
    seen.add(r.userId);
    out.push({
      userId: r.userId,
      name: typeof r.name === "string" ? r.name : "",
      hiddenAt: typeof r.hiddenAt === "number" && Number.isFinite(r.hiddenAt) ? r.hiddenAt : 0,
    });
  }
  return out.sort((a, b) => b.hiddenAt - a.hiddenAt).slice(0, CHAT_HIDDEN_LIMIT);
}

// The list with this person added (on top) -- hiding twice keeps one entry.
export function withHidden(list: readonly HiddenPerson[], person: HiddenPerson): HiddenPerson[] {
  return [person, ...list.filter((p) => p.userId !== person.userId)].slice(0, CHAT_HIDDEN_LIMIT);
}

// The list without this person.
export function withoutHidden(list: readonly HiddenPerson[], userId: string): HiddenPerson[] {
  return list.filter((p) => p.userId !== userId);
}

// The stored text as it is (a stable snapshot for useSyncExternalStore: the
// same string until the list really changes); "" when unreadable or unset.
export function rawHidden(userId: string): string {
  try {
    return localStorage.getItem(chatHiddenKey(userId)) ?? "";
  } catch {
    return "";
  }
}

export function readHidden(userId: string): HiddenPerson[] {
  try {
    return parseHidden(localStorage.getItem(chatHiddenKey(userId)));
  } catch {
    return [];
  }
}

function writeHidden(userId: string, list: readonly HiddenPerson[]) {
  try {
    localStorage.setItem(chatHiddenKey(userId), JSON.stringify(list));
  } catch {
    // Not remembered: the hide still applies until this page goes.
  }
  try {
    window.dispatchEvent(new CustomEvent(CHAT_HIDDEN_EVENT, { detail: { userId } }));
  } catch {
    // No window (tests): nothing to tell.
  }
}

// Hide a person's chat on this browser (the chat card's "Hide <name>").
export function hideSender(myUserId: string, person: { userId: string; name: string }, now = Date.now()) {
  if (!person.userId || person.userId === myUserId) return;
  writeHidden(myUserId, withHidden(readHidden(myUserId), { userId: person.userId, name: person.name, hiddenAt: now }));
}

// Settings' Unhide.
export function unhideSender(myUserId: string, userId: string) {
  writeHidden(myUserId, withoutHidden(readHidden(myUserId), userId));
}

// Calls back with the fresh list whenever it changes -- in this tab (the
// custom event) or another (the storage event). Returns the unsubscribe.
export function subscribeHidden(myUserId: string, onChange: (list: HiddenPerson[]) => void): () => void {
  const key = chatHiddenKey(myUserId);
  const fromStorage = (e: StorageEvent) => {
    if (e.key === key || e.key === null) onChange(readHidden(myUserId));
  };
  const fromHere = (e: Event) => {
    const detail = (e as CustomEvent<{ userId?: string }>).detail;
    if (!detail || detail.userId === myUserId) onChange(readHidden(myUserId));
  };
  window.addEventListener("storage", fromStorage);
  window.addEventListener(CHAT_HIDDEN_EVENT, fromHere);
  return () => {
    window.removeEventListener("storage", fromStorage);
    window.removeEventListener(CHAT_HIDDEN_EVENT, fromHere);
  };
}
