"use client";

import { useState } from "react";
import { supabase } from "@/lib/supabase";
import { AuthCard } from "@/components/brand/AuthCard";

// FORGOT PASSWORD ("Forgot password?" on the login page): asks Supabase to
// email a reset link that lands on /reset-password, on whichever site this
// page is open (localhost or the live site -- both are on Supabase's
// redirect allowlist). The same message shows whether or not an account
// exists for the email, so the page never reveals who has one.
const SENT_MESSAGE =
  "If an account exists for that email, we've sent a reset link. Check your inbox, and your spam folder too.";

export default function ForgotPasswordPage() {
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<"idle" | "sending" | "sent" | "error">("idle");
  const [message, setMessage] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setStatus("sending");
    setMessage(null);

    const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), {
      redirectTo: `${window.location.origin}/reset-password`,
    });

    if (error) {
      setStatus("error");
      setMessage(
        error.status === 429 || error.code === "over_email_send_rate_limit" || error.code === "over_request_rate_limit"
          ? "Too many requests. Please wait a bit and try again."
          : "Couldn't send the reset email just now. Please try again in a moment."
      );
      return;
    }

    setStatus("sent");
    setMessage(SENT_MESSAGE);
  }

  return (
    <AuthCard
      title="Forgot Password"
      switchPrompt="Remembered it?"
      switchHref="/login"
      switchLabel="Log in"
    >
      <form onSubmit={handleSubmit} className="flex w-full flex-col gap-4">
        <p className="text-sm">Enter your account&apos;s email and we&apos;ll send you a link to choose a new password.</p>

        <div className="flex flex-col gap-1">
          <label htmlFor="email" className="text-sm font-medium">
            Email
          </label>
          <input
            id="email"
            type="email"
            autoComplete="email"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="felt-input"
          />
        </div>

        <button
          type="submit"
          disabled={status === "sending"}
          className="peg-btn peg-btn--brass disabled:opacity-60"
        >
          {status === "sending" ? "Sending..." : "Send Reset Link"}
        </button>

        {message && (
          <p
            role="status"
            className={
              status === "error"
                ? "text-sm text-[var(--error-on-felt)]"
                : "text-sm text-[var(--success-on-felt)]"
            }
          >
            {message}
          </p>
        )}
      </form>
    </AuthCard>
  );
}
