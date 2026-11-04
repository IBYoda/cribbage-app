"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";
import { AuthCard } from "@/components/brand/AuthCard";
import { CheckEmailPanel } from "@/components/brand/CheckEmailPanel";

// How long "Taking you in..." shows before going home.
const REDIRECT_DELAY_MS = 1000;

export default function SignUpPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [status, setStatus] = useState<"idle" | "loading" | "success" | "error">("idle");
  const [message, setMessage] = useState<string | null>(null);
  // Signed in straight away (email confirmation is off): show the way home.
  const [signedIn, setSignedIn] = useState(false);
  // No session came back (email confirmation is on): the Check-your-email
  // panel for this address, its Resend countdown starting from the sign-up.
  const [checkEmail, setCheckEmail] = useState<{ email: string; sentAt: number } | null>(null);
  const redirectTimer = useRef<number | null>(null);

  // No redirect after the page is gone.
  useEffect(() => {
    return () => {
      if (redirectTimer.current !== null) window.clearTimeout(redirectTimer.current);
    };
  }, []);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setStatus("loading");
    setMessage(null);

    // The confirmation link (when Supabase sends one) comes back to this
    // site's home page, which signs the player in from it -- this origin, so
    // a sign-up on localhost comes back to localhost (both are on the
    // Supabase redirect list).
    const { data, error } = await supabase.auth.signUp({
      email,
      password,
      options: { emailRedirectTo: `${window.location.origin}/` },
    });

    if (error) {
      setStatus("error");
      setMessage(error.message);
      return;
    }

    // A session means the account is already logged in (email confirmation
    // is off in Supabase): straight home after a beat. No session means a
    // confirmation email is on its way -- or, for an address that already
    // has an account, nothing at all (Supabase answers both the same), so
    // the panel never says the account is new.
    if (data.session) {
      setStatus("success");
      setSignedIn(true);
      setMessage("Account created. Taking you in...");
      redirectTimer.current = window.setTimeout(() => router.push("/"), REDIRECT_DELAY_MS);
      return;
    }

    setStatus("success");
    setCheckEmail({ email, sentAt: Date.now() });
  }

  if (checkEmail) {
    return (
      <AuthCard
        title="Sign Up"
        switchPrompt="Already have an account?"
        switchHref="/login"
        switchLabel="Log in"
      >
        <CheckEmailPanel email={checkEmail.email} sentAt={checkEmail.sentAt} />
      </AuthCard>
    );
  }

  return (
    <AuthCard
      title="Sign Up"
      switchPrompt="Already have an account?"
      switchHref="/login"
      switchLabel="Log in"
    >
      <form onSubmit={handleSubmit} className="flex w-full flex-col gap-4">
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

        <div className="flex flex-col gap-1">
          <label htmlFor="password" className="text-sm font-medium">
            Password
          </label>
          <input
            id="password"
            type="password"
            autoComplete="new-password"
            required
            minLength={6}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="felt-input"
          />
        </div>

        <button
          type="submit"
          disabled={status === "loading"}
          className="peg-btn peg-btn--brass disabled:opacity-60"
        >
          {status === "loading" ? "Signing up..." : "Sign Up"}
        </button>

        {message && (
          <p
            className={
              status === "error"
                ? "text-sm text-[var(--error-on-felt)]"
                : "text-sm text-[var(--success-on-felt)]"
            }
          >
            {message}
          </p>
        )}

        {signedIn && (
          <Link href="/" className="footer-link self-center">
            Continue
          </Link>
        )}
      </form>
    </AuthCard>
  );
}
