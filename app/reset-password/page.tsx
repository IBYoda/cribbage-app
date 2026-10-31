"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { PASSWORD_MIN_LENGTH, passwordPairProblem, passwordUpdateErrorMessage } from "@/lib/passwordForm";

// How long to wait for the reset link's sign-in before calling it invalid.
const RECOVERY_WAIT_MS = 5000;
// How long "Password updated" shows before going home.
const REDIRECT_DELAY_MS = 1500;

// RESET PASSWORD: where the emailed reset link lands (/forgot-password asks
// for it). The link arrives as /reset-password#access_token=...&type=recovery;
// the Supabase client (implicit flow, detectSessionInUrl) reads that while it
// starts up, signs the person in, clears the #..., and fires
// PASSWORD_RECOVERY. A bad or expired link arrives as #error=...&error_code=...
//
// The form only opens for a RECOVERY sign-in, never for someone who is simply
// logged in: either the PASSWORD_RECOVERY event, or -- if the client finished
// before this page subscribed -- a session whose access token is the one in
// this page's own link. Anything else (no link, a bad link, nothing within a
// few seconds) shows "invalid or expired".
export default function ResetPasswordPage() {
  const router = useRouter();
  const [phase, setPhase] = useState<"checking" | "ready" | "invalid" | "done">("checking");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const redirectTimer = useRef<number | null>(null);

  useEffect(() => {
    // Read the link straight away: the client clears it once it has used it.
    const params = new URLSearchParams(window.location.hash.slice(1));
    const linkToken = params.get("type") === "recovery" ? params.get("access_token") : null;
    const linkError = params.has("error") || params.has("error_code");

    let settled = false;
    const settle = (next: "ready" | "invalid") => {
      if (settled) return;
      settled = true;
      setPhase(next);
    };

    const { data: listener } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === "PASSWORD_RECOVERY" && session) settle("ready");
      else if (linkToken && session?.access_token === linkToken) settle("ready");
    });

    // Already signed in from this page's link before we subscribed.
    supabase.auth.getSession().then(({ data }) => {
      if (linkToken && data.session?.access_token === linkToken) settle("ready");
    });

    // A bad link says so at once; otherwise give the sign-in a few seconds.
    const timer = window.setTimeout(() => settle("invalid"), linkError ? 0 : RECOVERY_WAIT_MS);

    return () => {
      settled = true;
      listener.subscription.unsubscribe();
      window.clearTimeout(timer);
    };
  }, []);

  // No redirect after the page is gone.
  useEffect(() => {
    return () => {
      if (redirectTimer.current !== null) window.clearTimeout(redirectTimer.current);
    };
  }, []);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const problem = passwordPairProblem(password, confirm);
    if (problem) {
      setMessage(problem);
      return;
    }

    setSaving(true);
    setMessage(null);
    const { error } = await supabase.auth.updateUser({ password });
    setSaving(false);

    if (error) {
      setMessage(passwordUpdateErrorMessage(error));
      return;
    }

    setPhase("done");
    redirectTimer.current = window.setTimeout(() => router.replace("/"), REDIRECT_DELAY_MS);
  }

  return (
    <CardRoomFrame title="Choose a New Password">
      {phase === "checking" ? (
        <p role="status">Checking your reset link...</p>
      ) : phase === "invalid" ? (
        <>
          <p role="alert" className="text-[var(--error-on-felt)]">
            This reset link is invalid or has expired.
          </p>
          <Link href="/forgot-password" className="peg-btn peg-btn--brass">
            Send a New Link
          </Link>
        </>
      ) : phase === "done" ? (
        <p role="status" className="text-[var(--success-on-felt)]">
          Password updated. Taking you in...
        </p>
      ) : (
        <form onSubmit={handleSubmit} className="flex w-full flex-col gap-4">
          <div className="flex flex-col gap-1">
            <label htmlFor="new-password" className="text-sm font-medium">
              New password
            </label>
            <input
              id="new-password"
              type="password"
              autoComplete="new-password"
              required
              minLength={PASSWORD_MIN_LENGTH}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="felt-input"
            />
          </div>

          <div className="flex flex-col gap-1">
            <label htmlFor="confirm-password" className="text-sm font-medium">
              Confirm new password
            </label>
            <input
              id="confirm-password"
              type="password"
              autoComplete="new-password"
              required
              minLength={PASSWORD_MIN_LENGTH}
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              className="felt-input"
            />
          </div>

          <button type="submit" disabled={saving} className="peg-btn peg-btn--brass disabled:opacity-60">
            {saving ? "Saving..." : "Save New Password"}
          </button>

          {message && (
            <p role="alert" className="text-sm text-[var(--error-on-felt)]">
              {message}
            </p>
          )}
        </form>
      )}
    </CardRoomFrame>
  );
}
