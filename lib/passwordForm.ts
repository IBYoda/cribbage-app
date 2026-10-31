import type { AuthError } from "@supabase/supabase-js";

// THE NEW-PASSWORD FORMS (the reset page and the Profile page's Change
// password): the same rules as Sign Up, and friendly words for Supabase's
// refusals.

// The same minimum as the sign-up form (and Supabase's default).
export const PASSWORD_MIN_LENGTH = 6;

// What's wrong with the two fields, or null when they're fine.
export function passwordPairProblem(password: string, confirm: string): string | null {
  if (password.length < PASSWORD_MIN_LENGTH) return `Use at least ${PASSWORD_MIN_LENGTH} characters.`;
  if (password !== confirm) return "The two passwords don't match.";
  return null;
}

// supabase.auth.updateUser({ password }) refused: what to tell the player.
export function passwordUpdateErrorMessage(error: AuthError): string {
  if (
    error.code === "reauthentication_needed" ||
    error.code === "reauthentication_not_valid" ||
    /reauthenticat/i.test(error.message)
  ) {
    return "For security, please log out and log back in, or use Forgot password on the login page, then try again.";
  }
  if (error.code === "same_password") return "That's already your password. Choose a different one.";
  if (error.code === "weak_password") return "That password is too weak. Try a longer one.";
  if (error.status === 429 || error.code === "over_request_rate_limit") {
    return "Too many requests. Please wait a bit and try again.";
  }
  return "Couldn't update your password just now. Please try again.";
}
