// MUTE IN CHAT (moderation M2c): a PERSONAL, browser-only list of people at
// ONE table whose chat messages this player doesn't want to see. It changes
// only what I see -- the host's mute is as personal as anyone's -- nothing is
// sent to the server, and it applies to spectators too.
//
// It lasts the life of the table: stored per signed-in player AND per table
// under nobs:chat-muted:v1:<userId>:<tableId>, so it survives a reload, or
// leaving and rejoining the SAME table, and never carries to another table.
// Each entry remembers when its table was last seen (seenAt, refreshed when
// the table opens and on every change); entries not seen for
// CHAT_MUTE_KEEP_MS (24 hours -- tables time out at 12) are pruned, so
// storage doesn't grow. The pruning also deletes the old cross-table hide
// list (nobs:chat-hidden:v1:<userId>, moderation M2), which is never read.
//
// BLOCK is not this list: a block lives on the server's Block List (lib/
// blocks.ts) and hides chat everywhere by being there. What chat drops is the
// MUTED set: this table's muted ids plus blocked ids (lib/tableChat.ts
// mutedSenders).
//
// Pure helpers plus guarded storage: a blocked or full localStorage, or a
// corrupt value, just means nobody muted -- never an error on screen.
// Tested by scripts/test-phase3.ts.

export type MutedEntry = { seenAt: number; ids: string[] };

export const CHAT_MUTE_PREFIX = "nobs:chat-muted:v1:";
// The old cross-table hide list's keys (M2): deleted when found.
export const OLD_CHAT_HIDDEN_PREFIX = "nobs:chat-hidden:v1:";
// How long an entry is kept after its table was last seen.
export const CHAT_MUTE_KEEP_MS = 24 * 60 * 60 * 1000;
// Plenty for one table.
export const CHAT_MUTE_LIMIT = 100;

// Same-tab listeners hear this (the storage event only reaches OTHER tabs).
export const CHAT_MUTED_EVENT = "nobs:chat-muted";

export const chatMutedKey = (userId: string, tableId: string) => `${CHAT_MUTE_PREFIX}${userId}:${tableId}`;

// A stored value as a clean entry: one id per person, anything malformed
// dropped; unreadable is nobody muted, seen at 0 (so it is pruned).
export function parseMuted(raw: string | null | undefined): MutedEntry {
  const empty: MutedEntry = { seenAt: 0, ids: [] };
  if (!raw) return empty;
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    return empty;
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) return empty;
  const r = data as { seenAt?: unknown; ids?: unknown };
  const seenAt = typeof r.seenAt === "number" && Number.isFinite(r.seenAt) ? r.seenAt : 0;
  const ids: string[] = [];
  if (Array.isArray(r.ids)) {
    for (const id of r.ids) if (typeof id === "string" && id !== "" && !ids.includes(id)) ids.push(id);
  }
  return { seenAt, ids: ids.slice(0, CHAT_MUTE_LIMIT) };
}

// The entry with this person muted (muting twice keeps one).
export function withMuted(entry: MutedEntry, userId: string, now: number): MutedEntry {
  return { seenAt: now, ids: [userId, ...entry.ids.filter((id) => id !== userId)].slice(0, CHAT_MUTE_LIMIT) };
}

// The entry without this person.
export function withoutMuted(entry: MutedEntry, userId: string, now: number): MutedEntry {
  return { seenAt: now, ids: entry.ids.filter((id) => id !== userId) };
}

// THE PRUNING, pure: which stored keys go -- a mute entry whose table wasn't
// seen within CHAT_MUTE_KEEP_MS (or that is unreadable or empty), and every
// key of the old hide list. Other keys are never touched.
export function staleMuteKeys(entries: readonly { key: string; raw: string | null }[], now: number): string[] {
  const out: string[] = [];
  for (const { key, raw } of entries) {
    if (key.startsWith(OLD_CHAT_HIDDEN_PREFIX)) {
      out.push(key);
      continue;
    }
    if (!key.startsWith(CHAT_MUTE_PREFIX)) continue;
    const entry = parseMuted(raw);
    if (entry.ids.length === 0 || now - entry.seenAt > CHAT_MUTE_KEEP_MS) out.push(key);
  }
  return out;
}

function read(userId: string, tableId: string): MutedEntry {
  try {
    return parseMuted(localStorage.getItem(chatMutedKey(userId, tableId)));
  } catch {
    return { seenAt: 0, ids: [] };
  }
}

// The muted ids as one string (a stable snapshot for useSyncExternalStore:
// the same string until the list really changes -- seenAt is left out);
// "" when nobody is muted or storage is unreadable.
export function mutedIdsText(userId: string, tableId: string): string {
  return read(userId, tableId).ids.join(",");
}

export function readMutedIds(userId: string, tableId: string): string[] {
  return read(userId, tableId).ids;
}

function write(userId: string, tableId: string, entry: MutedEntry) {
  try {
    const key = chatMutedKey(userId, tableId);
    if (entry.ids.length === 0) localStorage.removeItem(key);
    else localStorage.setItem(key, JSON.stringify(entry));
  } catch {
    // Not remembered: the mute still applies until this page goes.
  }
  try {
    window.dispatchEvent(new CustomEvent(CHAT_MUTED_EVENT, { detail: { userId, tableId } }));
  } catch {
    // No window (tests): nothing to tell.
  }
}

// "Mute <name>" at this table.
export function muteSender(myUserId: string, tableId: string, userId: string, now = Date.now()) {
  if (!myUserId || !tableId || !userId || userId === myUserId) return;
  write(myUserId, tableId, withMuted(read(myUserId, tableId), userId, now));
}

// "Unmute <name>" (the menu, or the composer's "Muted:" line).
export function unmuteSender(myUserId: string, tableId: string, userId: string, now = Date.now()) {
  if (!myUserId || !tableId) return;
  write(myUserId, tableId, withoutMuted(read(myUserId, tableId), userId, now));
}

// Opening a table: this table's entry is seen now (only if it has one -- no
// entry is created), then every stale entry and the old hide list go.
export function touchMuted(myUserId: string, tableId: string, now = Date.now()) {
  try {
    const key = chatMutedKey(myUserId, tableId);
    const entry = parseMuted(localStorage.getItem(key));
    if (entry.ids.length > 0) localStorage.setItem(key, JSON.stringify({ ...entry, seenAt: now }));
    const all: { key: string; raw: string | null }[] = [];
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (k) all.push({ key: k, raw: localStorage.getItem(k) });
    }
    for (const k of staleMuteKeys(all, now)) localStorage.removeItem(k);
  } catch {
    // Storage unreadable: nothing to keep or prune.
  }
}

// Calls back whenever this table's list changes -- in this tab (the custom
// event) or another (the storage event). Returns the unsubscribe.
export function subscribeMuted(myUserId: string, tableId: string, onChange: () => void): () => void {
  const key = chatMutedKey(myUserId, tableId);
  const fromStorage = (e: StorageEvent) => {
    if (e.key === key || e.key === null) onChange();
  };
  const fromHere = (e: Event) => {
    const detail = (e as CustomEvent<{ userId?: string; tableId?: string }>).detail;
    if (!detail || (detail.userId === myUserId && detail.tableId === tableId)) onChange();
  };
  window.addEventListener("storage", fromStorage);
  window.addEventListener(CHAT_MUTED_EVENT, fromHere);
  return () => {
    window.removeEventListener("storage", fromStorage);
    window.removeEventListener(CHAT_MUTED_EVENT, fromHere);
  };
}
