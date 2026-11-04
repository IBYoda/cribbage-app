// SIGN-UP AND LOG-IN WITH "CONFIRM EMAIL" ON: the pure rules behind the
// Check-your-email panel, the not-confirmed login message, the Resend button
// and the expired-link notice (app/signup, app/login, app/page.tsx). Tested
// by scripts/test-phase3.ts.

// Supabase limits confirmation resends; the button waits this long after
// each tap.
export const RESEND_COOLDOWN_S = 60;

// Whole seconds until Resend can be tapped again (0: now). lastSentAt and now
// in milliseconds; null: never sent.
export function resendSecondsLeft(lastSentAt: number | null, now: number): number {
  if (lastSentAt === null) return 0;
  const left = RESEND_COOLDOWN_S - Math.floor((now - lastSentAt) / 1000);
  return Math.min(RESEND_COOLDOWN_S, Math.max(0, left));
}

// A sign-in refused because the address hasn't been confirmed yet: by its
// code (email_not_confirmed), or by its message ("Email not confirmed") for
// a server that sends no code.
export function isEmailNotConfirmed(error: { code?: string | null; message?: string | null } | null | undefined): boolean {
  if (!error) return false;
  if (error.code === "email_not_confirmed") return true;
  return /email\s+not\s+confirmed/i.test(error.message ?? "");
}

// An auth error carried in a link's hash -- an expired or already used
// confirmation link lands as #error=access_denied&error_code=otp_expired&
// error_description=... -- or null for anything else (a successful link's
// tokens, an empty hash).
export function readAuthHashError(hash: string): { error: string; code: string | null; description: string | null } | null {
  const params = new URLSearchParams(hash.startsWith("#") ? hash.slice(1) : hash);
  const error = params.get("error");
  const code = params.get("error_code");
  if (!error && !code) return null;
  return { error: error ?? code ?? "error", code, description: params.get("error_description") };
}
