"use client";

import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import { resendSecondsLeft } from "@/lib/authFlow";

// RESEND THE CONFIRMATION EMAIL (Sign Up's Check-your-email panel, and Log In
// when the address isn't confirmed yet): supabase.auth.resend for a sign-up,
// with the link coming back to this site's home page. After each send the
// button waits RESEND_COOLDOWN_S with a visible countdown (Supabase refuses
// quicker repeats); "Sent" or the error shows under it.
//
// sentAt: when an email last went out (ms), so the countdown starts at once
// -- Sign Up passes the moment it signed up; null: nothing sent yet.
// send: the call, for the dev mock (default: the real resend).
export function ResendConfirmation({
  email,
  sentAt: initialSentAt = null,
  send = resendSignupEmail,
}: {
  email: string;
  sentAt?: number | null;
  send?: (email: string) => Promise<string | null>;
}) {
  const [sentAt, setSentAt] = useState<number | null>(initialSentAt);
  // The clock the countdown reads: set when sending and then once a second,
  // never read during render.
  const [now, setNow] = useState<number>(initialSentAt ?? 0);
  const [status, setStatus] = useState<"idle" | "sending" | "sent" | "error">("idle");
  const [message, setMessage] = useState<string | null>(null);

  // Tick once a second while the cooldown runs, then stop.
  useEffect(() => {
    if (sentAt === null) return;
    const timer = window.setInterval(() => {
      const t = Date.now();
      setNow(t);
      if (resendSecondsLeft(sentAt, t) === 0) window.clearInterval(timer);
    }, 1000);
    return () => window.clearInterval(timer);
  }, [sentAt]);

  const left = resendSecondsLeft(sentAt, now);

  async function handleResend() {
    const t = Date.now();
    setSentAt(t);
    setNow(t);
    setStatus("sending");
    setMessage(null);
    const error = await send(email);
    if (error) {
      setStatus("error");
      setMessage(error);
    } else {
      setStatus("sent");
      setMessage("Sent. Check your inbox (and spam).");
    }
  }

  return (
    <div className="flex w-full flex-col items-center gap-1">
      <button
        type="button"
        onClick={handleResend}
        disabled={!email || status === "sending" || left > 0}
        className="peg-btn peg-btn--ghost w-full disabled:opacity-60"
      >
        {status === "sending"
          ? "Sending..."
          : left > 0
            ? `Resend email (${left}s)`
            : "Resend email"}
      </button>
      {message && (
        <p
          role="status"
          className={`text-sm ${status === "error" ? "text-[var(--error-on-felt)]" : "text-[var(--success-on-felt)]"}`}
        >
          {message}
        </p>
      )}
    </div>
  );
}

// The real resend: the sign-up confirmation email again, its link back to
// this site's home page. Returns the error message, or null.
async function resendSignupEmail(email: string): Promise<string | null> {
  const { error } = await supabase.auth.resend({
    type: "signup",
    email,
    options: { emailRedirectTo: `${window.location.origin}/` },
  });
  return error ? error.message : null;
}
