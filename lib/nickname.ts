// THE NICKNAME RULES, shared by the Profile page and the Pick-a-nickname step
// (components/brand/NicknameStep.tsx), and the pure checks behind the
// nickname gate (home, Start a Table, single player, a new seat at a table).
// No Supabase here, so scripts/test-phase3.ts can test it.

export const NICKNAME_MAX_LENGTH = 30;

// Postgres unique_violation: nicknames are unique in the database
// (case-insensitive, trimmed), so a taken one is refused there.
const UNIQUE_VIOLATION = "23505";

// No profile row, no nickname, or only spaces: the player has to pick one
// before they can start or sit at a table. Anything else is a real name.
export function needsNickname(profile: { nickname?: string | null } | null | undefined): boolean {
  return !profile?.nickname?.trim();
}

// What's wrong with a typed nickname before it's sent, or null. Saved trimmed.
export function nicknameProblem(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed) return "Please enter a nickname.";
  if (trimmed.length > NICKNAME_MAX_LENGTH) return `Nicknames are at most ${NICKNAME_MAX_LENGTH} characters.`;
  return null;
}

// The message for a refused save: a taken nickname in words, anything else
// as Supabase said it.
export function nicknameSaveErrorMessage(error: { code?: string | null; message: string }): string {
  return error.code === UNIQUE_VIOLATION ? "That nickname is taken." : error.message;
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
