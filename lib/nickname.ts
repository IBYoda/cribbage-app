// THE NICKNAME RULES' client side, shared by the Profile page and the
// Pick-a-nickname step (components/brand/NicknameStep.tsx), and the pure
// checks behind the nickname gate (home, Start a Table, single player, a new seat at a table).
// No Supabase here, so scripts/test-phase3.ts can test it.

export const NICKNAME_MAX_LENGTH = 30;

// Postgres unique_violation: nicknames are unique in the database
// (case-insensitive, trimmed), so an exempt path can still meet the index.
const UNIQUE_VIOLATION = "23505";

// No profile row, no nickname, or only spaces: the player has to pick one
// before they can start or sit at a table. Anything else is a real name.
export function needsNickname(profile: { nickname?: string | null } | null | undefined): boolean {
  return !profile?.nickname?.trim();
}

// THE NICKNAME RULES (docs/sql/nickname-rules-part1.sql). The server checks
// every new or changed nickname and never trims: it refuses a leading,
// trailing or double space. So the app sends a normalized value -- trimmed,
// runs of spaces collapsed to one -- and pre-checks the simple rules with
// the server's own words. Reserved words and look-alikes are the server's
// alone (its message is shown).
export const NICKNAME_MESSAGES = {
  empty: "Please enter a nickname.",
  characters: "Nicknames can use letters, numbers, spaces and . - _ ' ! only.",
  tooLong: `Nicknames are at most ${NICKNAME_MAX_LENGTH} characters.`,
  noLetterOrDigit: "Nicknames need at least one letter or number.",
  taken: "That nickname is taken.",
  unavailable: "That nickname isn't available.",
} as const;

// Trimmed, and every run of spaces made one space.
export function normalizeNickname(raw: string): string {
  return raw.trim().replace(/ {2,}/g, " ");
}

// The same name as the one saved: equal once both are normalized. Saving it
// again re-sends the saved value exactly, so the server sees no change and
// never checks it -- a player with an old name that breaks today's rules
// (D$) can still press Save. An empty saved name is never "the same".
function isSavedName(raw: string, saved: string | null | undefined): saved is string {
  return typeof saved === "string" && saved.trim() !== "" && normalizeNickname(raw) === normalizeNickname(saved);
}

// What to send for a typed nickname, or the problem in the server's words.
// saved: the player's current nickname (the Profile page), so an unchanged
// name skips the pre-check. In the server's order: empty, characters,
// length, a letter or digit.
export function nicknameToSave(
  raw: string,
  saved?: string | null
): { ok: true; nickname: string } | { ok: false; message: string } {
  const nickname = normalizeNickname(raw);
  if (!nickname) return { ok: false, message: NICKNAME_MESSAGES.empty };
  if (isSavedName(raw, saved)) return { ok: true, nickname: saved };
  if (!/^[A-Za-z0-9 .\-_'!]+$/.test(nickname)) return { ok: false, message: NICKNAME_MESSAGES.characters };
  if (nickname.length > NICKNAME_MAX_LENGTH) return { ok: false, message: NICKNAME_MESSAGES.tooLong };
  if (!/[A-Za-z0-9]/.test(nickname)) return { ok: false, message: NICKNAME_MESSAGES.noLetterOrDigit };
  return { ok: true, nickname };
}

// What's wrong with a typed nickname before it's sent, or null.
export function nicknameProblem(raw: string, saved?: string | null): string | null {
  const result = nicknameToSave(raw, saved);
  return result.ok ? null : result.message;
}

// The message for a refused save. The server's own words for its rules
// (details nickname_invalid, nickname_unavailable, nickname_taken) and the
// 7-day lock (nickname_locked, "You can change your nickname again in N
// days."), or a plain version of each if it sent none; the unique index
// (23505) as "That nickname is taken."; anything else one generic line --
// never the raw error text.
export const NICKNAME_LOCKED_FALLBACK = "You changed your nickname recently. You can change it again 7 days after that change.";
export const NICKNAME_SAVE_FAILED = "Couldn't save your nickname. Check your connection and try again.";

const SERVER_WORDED: Record<string, string> = {
  nickname_invalid: NICKNAME_SAVE_FAILED,
  nickname_unavailable: NICKNAME_MESSAGES.unavailable,
  nickname_taken: NICKNAME_MESSAGES.taken,
  nickname_locked: NICKNAME_LOCKED_FALLBACK,
};

export function nicknameSaveErrorMessage(error: { code?: string | null; message?: string | null; details?: string | null }): string {
  const details = error.details ?? "";
  if (Object.prototype.hasOwnProperty.call(SERVER_WORDED, details)) {
    return error.message?.trim() ? error.message.trim() : SERVER_WORDED[details];
  }
  if (error.code === UNIQUE_VIOLATION) return NICKNAME_MESSAGES.taken;
  return NICKNAME_SAVE_FAILED;
}

// Where the nickname step goes back to. Only a same-site relative path is
// accepted: one leading "/", not "//" or "/\" (which browsers read as another
// host), no backslashes, spaces or control characters anywhere (the URL
// parser drops tabs and newlines, so "/\t/evil.com" would become
// "//evil.com"), and it must still resolve to this site. Anything else, a
// missing one included, is the home page.
export function safeReturnPath(raw: string | null | undefined): string {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > 512) return "/";
  if (!raw.startsWith("/") || raw.startsWith("//")) return "/";
  if (/[\\\s\u0000-\u001f\u007f]/.test(raw)) return "/";
  try {
    const base = "https://nobs.invalid";
    const url = new URL(raw, base);
    if (url.origin !== base) return "/";
    return url.pathname + url.search + url.hash;
  } catch {
    return "/";
  }
}

// The nickname step's address, coming back to returnPath afterwards.
export function nicknameStepHref(returnPath: string): string {
  const next = safeReturnPath(returnPath);
  return next === "/" ? "/nickname" : `/nickname?next=${encodeURIComponent(next)}`;
}
