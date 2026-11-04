"use client";

import { ResendConfirmation } from "@/components/brand/ResendConfirmation";

// LOG IN, refused because the address isn't confirmed yet: what to do, and
// Resend for the address typed in the form.
export function NotConfirmedNotice({
  email,
  send,
}: {
  email: string;
  // For the dev mock; default: the real resend.
  send?: (email: string) => Promise<string | null>;
}) {
  return (
    <div className="flex w-full flex-col gap-2" role="alert">
      <p className="text-sm">
        <strong>Please confirm your email first.</strong> Open the link we sent to{" "}
        <span className="[overflow-wrap:anywhere]">{email || "your address"}</span>; it signs you in. No email?
        Check spam, or send it again.
      </p>
      <ResendConfirmation email={email} send={send} />
    </div>
  );
}
