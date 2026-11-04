"use client";

import { ResendConfirmation } from "@/components/brand/ResendConfirmation";

// CHECK YOUR EMAIL: Sign Up when no session comes back ("Confirm email" on in
// Supabase). Worded so it stays true for an address that already has an
// account -- Supabase answers that sign-up the same way, without saying so,
// and sends nothing -- so it never claims the account is new.
export function CheckEmailPanel({
  email,
  sentAt,
  send,
}: {
  email: string;
  sentAt: number | null;
  // For the dev mock; default: the real resend.
  send?: (email: string) => Promise<string | null>;
}) {
  return (
    <div className="flex w-full flex-col gap-3" role="status">
      <h2 className="text-lg font-semibold">Check your email</h2>
      <p className="text-sm">
        We&apos;ve sent a confirmation link to{" "}
        <strong className="[overflow-wrap:anywhere]">{email}</strong>. Opening it signs you in.
      </p>
      <p className="text-sm">
        If you don&apos;t see it, check spam, or log in if you already have an account.
      </p>
      <ResendConfirmation email={email} sentAt={sentAt} send={send} />
      {/* Log in: the card's own "Already have an account? Log in" below. */}
    </div>
  );
}
